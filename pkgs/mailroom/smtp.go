package main

import (
	"bufio"
	"bytes"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/smtp"
	"net/textproto"
	"strings"
	"time"
)

// Submission is a deliberately small SMTP server on loopback. Roundcube
// hands it a message; it picks the connected account matching the envelope
// sender and relays through that account's own SMTP with XOAUTH2. Sending
// stays on each provider, so deliverability and Sent copies are unchanged.
type Submission struct {
	Addr     string
	User     string
	Password string
	Store    *Store
	Google   *Google
	Upstream string // "smtp.gmail.com:465"; overridable for tests
	MaxSize  int64
	// relay is swappable in tests.
	relay func(a Account, from string, rcpts []string, msg []byte) error
}

func (s *Submission) ListenAndServe() error {
	ln, err := net.Listen("tcp", s.Addr)
	if err != nil {
		return err
	}
	if s.relay == nil {
		s.relay = s.gmailRelay
	}
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		go s.serve(c)
	}
}

type session struct {
	authed bool
	from   string
	acct   *Account
	rcpts  []string
}

func (s *Submission) serve(c net.Conn) {
	defer c.Close()
	tp := textproto.NewConn(c)
	reply := func(format string, args ...any) { _ = tp.PrintfLine(format, args...) }
	reply("220 mailroom ESMTP")
	var ss session
	for {
		_ = c.SetDeadline(time.Now().Add(5 * time.Minute))
		line, err := tp.ReadLine()
		if err != nil {
			return
		}
		verb, arg, _ := strings.Cut(line, " ")
		switch strings.ToUpper(verb) {
		case "EHLO":
			reply("250-mailroom")
			reply("250-AUTH PLAIN LOGIN")
			reply("250-8BITMIME")
			reply("250 SIZE %d", s.MaxSize)
		case "HELO":
			reply("250 mailroom")
		case "AUTH":
			ss.authed = s.auth(tp, arg)
			if ss.authed {
				reply("235 2.7.0 ok")
			} else {
				reply("535 5.7.8 authentication failed")
			}
		case "MAIL":
			if !ss.authed {
				reply("530 5.7.0 authentication required")
				continue
			}
			addr, ok := pathArg(arg, "FROM:")
			if !ok {
				reply("501 5.5.4 syntax: MAIL FROM:<address>")
				continue
			}
			a, found := s.Store.Get(addr)
			if !found {
				reply("550 5.7.1 %s is not a connected account", addr)
				continue
			}
			if a.NeedsReauth {
				reply("451 4.7.0 %s needs reconnecting at /accounts/", addr)
				continue
			}
			ss = session{authed: true, from: strings.ToLower(addr), acct: &a}
			reply("250 2.1.0 ok")
		case "RCPT":
			if ss.acct == nil {
				reply("503 5.5.1 MAIL first")
				continue
			}
			addr, ok := pathArg(arg, "TO:")
			if !ok || addr == "" {
				reply("501 5.5.4 syntax: RCPT TO:<address>")
				continue
			}
			if len(ss.rcpts) >= 200 {
				reply("452 4.5.3 too many recipients")
				continue
			}
			ss.rcpts = append(ss.rcpts, addr)
			reply("250 2.1.5 ok")
		case "DATA":
			if ss.acct == nil || len(ss.rcpts) == 0 {
				reply("503 5.5.1 MAIL and RCPT first")
				continue
			}
			reply("354 end with <CRLF>.<CRLF>")
			msg, err := io.ReadAll(io.LimitReader(tp.DotReader(), s.MaxSize+1))
			if err != nil {
				return
			}
			if int64(len(msg)) > s.MaxSize {
				reply("552 5.3.4 message too big")
				ss = session{authed: true}
				continue
			}
			if err := s.relay(*ss.acct, ss.from, ss.rcpts, msg); err != nil {
				log.Printf("relay %s: %v", ss.from, err)
				reply("451 4.3.0 upstream: %s", oneLine(err.Error()))
			} else {
				log.Printf("relay %s: sent to %d recipient(s)", ss.from, len(ss.rcpts))
				reply("250 2.0.0 sent via %s", ss.from)
			}
			ss = session{authed: true}
		case "RSET":
			ss = session{authed: ss.authed}
			reply("250 2.0.0 ok")
		case "NOOP":
			reply("250 2.0.0 ok")
		case "QUIT":
			reply("221 2.0.0 bye")
			return
		default:
			reply("502 5.5.2 not implemented")
		}
	}
}

func oneLine(s string) string {
	s = strings.ReplaceAll(s, "\r", " ")
	return strings.ReplaceAll(s, "\n", " ")
}

// pathArg parses "FROM:<a@b> SIZE=123" → "a@b".
func pathArg(arg, prefix string) (string, bool) {
	if len(arg) < len(prefix) || !strings.EqualFold(arg[:len(prefix)], prefix) {
		return "", false
	}
	rest := strings.TrimSpace(arg[len(prefix):])
	if !strings.HasPrefix(rest, "<") {
		return "", false
	}
	end := strings.IndexByte(rest, '>')
	if end < 0 {
		return "", false
	}
	return strings.ToLower(strings.TrimSpace(rest[1:end])), true
}

func (s *Submission) check(user, pass string) bool {
	u := subtle.ConstantTimeCompare([]byte(user), []byte(s.User))
	p := subtle.ConstantTimeCompare([]byte(pass), []byte(s.Password))
	return s.Password != "" && u&p == 1
}

func (s *Submission) auth(tp *textproto.Conn, arg string) bool {
	mech, initial, _ := strings.Cut(arg, " ")
	readB64 := func(prompt string) (string, bool) {
		_ = tp.PrintfLine("334 %s", prompt)
		l, err := tp.ReadLine()
		if err != nil || l == "*" {
			return "", false
		}
		b, err := base64.StdEncoding.DecodeString(l)
		return string(b), err == nil
	}
	switch strings.ToUpper(mech) {
	case "PLAIN":
		var raw []byte
		var err error
		if initial != "" {
			raw, err = base64.StdEncoding.DecodeString(initial)
			if err != nil {
				return false
			}
		} else {
			str, ok := readB64("")
			if !ok {
				return false
			}
			raw = []byte(str)
		}
		parts := bytes.Split(raw, []byte{0})
		if len(parts) != 3 {
			return false
		}
		return s.check(string(parts[1]), string(parts[2]))
	case "LOGIN":
		var user string
		if initial != "" {
			b, err := base64.StdEncoding.DecodeString(initial)
			if err != nil {
				return false
			}
			user = string(b)
		} else {
			u, ok := readB64("VXNlcm5hbWU6")
			if !ok {
				return false
			}
			user = u
		}
		pass, ok := readB64("UGFzc3dvcmQ6")
		return ok && s.check(user, pass)
	}
	return false
}

type xoauth2 struct{ user, token string }

func (x xoauth2) Start(*smtp.ServerInfo) (string, []byte, error) {
	return "XOAUTH2", []byte("user=" + x.user + "\x01auth=Bearer " + x.token + "\x01\x01"), nil
}

func (x xoauth2) Next(fromServer []byte, more bool) ([]byte, error) {
	if more {
		// Google sends a base64 JSON error challenge; answer empty to get
		// the final 535 with the real reason.
		return []byte{}, nil
	}
	return nil, nil
}

func (s *Submission) gmailRelay(a Account, from string, rcpts []string, msg []byte) error {
	tok, err := s.Google.AccessToken(a)
	if err != nil {
		if errors.Is(err, ErrReauth) {
			_ = s.Store.Update(a.Email, func(a *Account) { a.NeedsReauth = true })
		}
		return err
	}
	host, _, _ := net.SplitHostPort(s.Upstream)
	d := &net.Dialer{Timeout: 30 * time.Second}
	conn, err := tls.DialWithDialer(d, "tcp", s.Upstream, &tls.Config{ServerName: host})
	if err != nil {
		return err
	}
	_ = conn.SetDeadline(time.Now().Add(5 * time.Minute))
	c, err := smtp.NewClient(conn, host)
	if err != nil {
		conn.Close()
		return err
	}
	defer c.Close()
	if err := c.Hello("mail.gisi.network"); err != nil {
		return err
	}
	if err := c.Auth(xoauth2{a.Email, tok}); err != nil {
		return fmt.Errorf("auth: %w", err)
	}
	if err := c.Mail(from); err != nil {
		return err
	}
	for _, r := range rcpts {
		if err := c.Rcpt(r); err != nil {
			return fmt.Errorf("rcpt %s: %w", r, err)
		}
	}
	w, err := c.Data()
	if err != nil {
		return err
	}
	bw := bufio.NewWriter(w)
	if _, err := bw.Write(msg); err != nil {
		return err
	}
	if err := bw.Flush(); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return c.Quit()
}

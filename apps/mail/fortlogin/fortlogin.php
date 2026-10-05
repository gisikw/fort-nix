<?php

/**
 * fortlogin: Roundcube sits behind the fort identity proxy, which has
 * already authenticated the user (pocket-id, admin group) and forwards
 * X-Forwarded-User. Trust that header and log straight into the local
 * Dovecot with the shared mailbox password. Nothing but nginx can reach
 * this vhost (loopback ACL by uid in the host firewall).
 *
 * On each login, add an identity for every connected account so replies
 * and new mail can go out as any of them (mailroom relays by From).
 */
class fortlogin extends rcube_plugin
{
    public $task = '.*';

    function init()
    {
        $this->add_hook('startup', [$this, 'startup']);
        $this->add_hook('authenticate', [$this, 'authenticate']);
        $this->add_hook('login_after', [$this, 'login_after']);
    }

    private function forwarded_user()
    {
        $u = isset($_SERVER['HTTP_X_FORWARDED_USER']) ? trim($_SERVER['HTTP_X_FORWARDED_USER']) : '';
        return $u !== '' ? $u : null;
    }

    function startup($args)
    {
        if (empty($_SESSION['user_id']) && $this->forwarded_user()) {
            $args['action'] = 'login';
        }
        return $args;
    }

    function authenticate($args)
    {
        if ($this->forwarded_user()) {
            $rcmail = rcmail::get_instance();
            $args['user'] = $rcmail->config->get('fortlogin_imap_user', 'kevin');
            $args['pass'] = trim((string) @file_get_contents($rcmail->config->get('fortlogin_pass_file')));
            $args['host'] = $rcmail->config->get('imap_host');
            $args['cookiecheck'] = false;
            $args['valid'] = true;
        }
        return $args;
    }

    function login_after($args)
    {
        $rcmail = rcmail::get_instance();
        $ctx = stream_context_create(['http' => ['timeout' => 3]]);
        $json = @file_get_contents($rcmail->config->get('fortlogin_identities_url'), false, $ctx);
        $list = $json ? json_decode($json, true) : null;
        if (is_array($list)) {
            $have = [];
            foreach ($rcmail->user->list_emails() as $i) {
                $have[strtolower($i['email'])] = true;
            }
            $name = $rcmail->config->get('fortlogin_display_name', '');
            foreach ($list as $i) {
                $email = isset($i['email']) ? strtolower($i['email']) : '';
                if ($email !== '' && !isset($have[$email])) {
                    $rcmail->user->insert_identity(['email' => $email, 'name' => $name, 'standard' => 0]);
                }
            }
        }
        // Land on the unified inbox.
        $args['_task'] = 'mail';
        $args['_mbox'] = 'INBOX';
        return $args;
    }
}

#!/usr/bin/env python3
"""Headless-browser feedback loop for agents: webshot / webdom.

webshot <url> [--width N] [--height N] [--out FILE] [--full-page]
              [--wait MS] [--do ACTION]...
    Screenshot a page (PNG). Agents can read the PNG back directly.

webdom <url>  [--width N] [--wait MS] [--do ACTION]... [--a11y] [--quiet-html]
    Print rendered HTML (or ARIA accessibility tree with --a11y), followed by
    console messages, page errors, and failed network requests.

--do actions (repeatable, run in order after initial load):
    click:<selector>        click an element (playwright selector, e.g. text=Login)
    fill:<selector>=<text>  fill an input
    press:<key>             send a key to the page (e.g. Enter)
    goto:<url>              navigate somewhere else
    wait:<ms>               sleep
    waitfor:<selector>      wait until selector is visible
"""

import argparse
import sys

from playwright.sync_api import sync_playwright


def parse_args(mode, argv):
    p = argparse.ArgumentParser(prog=mode)
    p.add_argument("url")
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=800)
    p.add_argument("--wait", type=int, default=1000,
                   help="ms to settle after load/actions (default 1000)")
    p.add_argument("--timeout", type=int, default=30000,
                   help="navigation timeout in ms (default 30000)")
    p.add_argument("--do", dest="actions", action="append", default=[],
                   metavar="ACTION", help="scripted step, see --help epilog")
    if mode == "webshot":
        p.add_argument("--out", default="screenshot.png")
        p.add_argument("--full-page", action="store_true")
    else:
        p.add_argument("--a11y", action="store_true",
                       help="print ARIA accessibility tree instead of HTML")
        p.add_argument("--quiet-html", action="store_true",
                       help="skip HTML/a11y output, only console/errors")
    return p.parse_args(argv)


def run_action(page, action):
    op, _, arg = action.partition(":")
    if op == "click":
        page.click(arg)
    elif op == "fill":
        selector, _, text = arg.partition("=")
        page.fill(selector, text)
    elif op == "press":
        page.keyboard.press(arg)
    elif op == "goto":
        page.goto(arg, wait_until="load")
    elif op == "wait":
        page.wait_for_timeout(int(arg))
    elif op == "waitfor":
        page.wait_for_selector(arg)
    else:
        raise ValueError(f"unknown action: {action!r}")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("webshot", "webdom"):
        sys.exit("usage: webtool.py {webshot|webdom} <url> [options]")
    mode = sys.argv[1]
    args = parse_args(mode, sys.argv[2:])

    console, page_errors, failures = [], [], []

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        page = browser.new_page(
            viewport={"width": args.width, "height": args.height})
        page.set_default_timeout(args.timeout)
        page.on("console",
                lambda m: console.append(f"[{m.type}] {m.text}"))
        page.on("pageerror",
                lambda e: page_errors.append(str(e)))
        page.on("requestfailed",
                lambda r: failures.append(f"{r.url} ({r.failure})"))

        page.goto(args.url, wait_until="load", timeout=args.timeout)
        for action in args.actions:
            run_action(page, action)
        page.wait_for_timeout(args.wait)

        if mode == "webshot":
            page.screenshot(path=args.out, full_page=args.full_page)
            print(args.out)
        else:
            if not args.quiet_html:
                if args.a11y:
                    print(page.locator("body").aria_snapshot())
                else:
                    print(page.content())
            print("=== console ===")
            print("\n".join(console) if console else "(no console output)")
            if page_errors:
                print("=== page errors ===")
                print("\n".join(page_errors))
            if failures:
                print("=== failed requests ===")
                print("\n".join(failures))

        browser.close()


if __name__ == "__main__":
    main()

# Agent web feedback loop: webshot (screenshots) and webdom (rendered
# HTML/a11y tree + console errors) via headless Chromium + Playwright.
#
# Usage:
#   webshot https://qb.gisi.network --width 390 --out qb.png
#   webdom  https://qb.gisi.network                 # HTML + console errors
#   webdom  <url> --a11y                            # accessibility tree
#   webshot <url> --do 'click:text=Login' --do 'wait:500'
#
# TLS against *.gisi.network works out of the box (public Let's Encrypt
# certs). Browsers come from pkgs.playwright-driver.browsers; the wrapper
# pins PLAYWRIGHT_BROWSERS_PATH so no download/install step is needed.
{ pkgs }:

let
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.playwright ]);
  browsers = pkgs.playwright-driver.browsers.override {
    withFirefox = false;
    withWebkit = false;
  };
  mkTool = name: pkgs.writeShellScriptBin name ''
    export PLAYWRIGHT_BROWSERS_PATH="${browsers}"
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
    exec ${pythonEnv}/bin/python3 ${./webtool.py} ${name} "$@"
  '';
in
pkgs.symlinkJoin {
  name = "webtools";
  paths = [ (mkTool "webshot") (mkTool "webdom") ];
}

#!/usr/bin/env bash
# fm-test-chrome.sh - single owner of which headless browser the test suite
# uses, shared by tests/fm-calm-pi-extension.test.sh and
# bin/fm-pc02-test-offload.sh's PC01/PC02 environment parity probe.
#
# The selection order is a contract, not a preference:
#   - FM_CHROME_BIN wins when set and executable.
#   - Playwright's cached chrome-headless-shell is next (the glob below).
#   - only then PATH chrome-headless-shell and full Chrome builds
#     (chromium, google-chrome, google-chrome-stable, chromium-browser).
# The headless shell must precede a full Chrome build because a Chrome for
# Testing build on a display-less WSL host never writes the --dump-dom output
# the rendered-export check reads, and Playwright installs the shell off PATH
# in its own cache. The parity probe compares both hosts' selection, so
# reordering this list changes what parity covers.

find_chrome() {
  local candidate headless_shell
  if [ -n "${FM_CHROME_BIN:-}" ] && [ -x "$FM_CHROME_BIN" ]; then
    printf '%s\n' "$FM_CHROME_BIN"
    return 0
  fi
  for headless_shell in \
    "$HOME"/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell
  do
    if [ -x "$headless_shell" ]; then
      printf '%s\n' "$headless_shell"
      return 0
    fi
  done
  for candidate in \
    chrome-headless-shell \
    chromium \
    google-chrome \
    google-chrome-stable \
    chromium-browser \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

#!/usr/bin/env bash
# tests/fm-captain-window.test.sh - behavior tests for bin/fm-captain-window.sh.
# Exercises the helper only through its executable interface: default bands
# at fixed clock times, offer=yes/no per band, config overrides, workdays=none,
# and loud rejection of malformed config.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin/fm-captain-window.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Default bands, weekday.
out="$(FM_HOME="$tmp" "$bin" --now 12:30 --weekday Wed)"
case "$out" in *"band=lunch offer=yes "*"source=default"*) ;; *) fail "lunch: $out" ;; esac

out="$(FM_HOME="$tmp" "$bin" --now 09:30 --weekday Wed)"
case "$out" in *"band=working offer=no "*) ;; *) fail "working: $out" ;; esac

out="$(FM_HOME="$tmp" "$bin" --now 23:30 --weekday Wed)"
case "$out" in *"band=quiet offer=no "*) ;; *) fail "quiet: $out" ;; esac

out="$(FM_HOME="$tmp" "$bin" --now 20:00 --weekday Wed)"
case "$out" in *"band=evening offer=yes "*) ;; *) fail "evening: $out" ;; esac

# 2. Non-workday falls to offhours even during would-be working hours.
out="$(FM_HOME="$tmp" "$bin" --now 09:30 --weekday Sat)"
case "$out" in *"band=offhours offer=yes "*) ;; *) fail "offhours weekend: $out" ;; esac

out="$(FM_HOME="$tmp" "$bin" --now 20:00 --weekday Sat)"
case "$out" in *"band=offhours offer=yes "*) ;; *) fail "offhours weekend evening: $out" ;; esac

# 2b. --now still reports a full ISO8601 timestamp, not a bare HH:MM.
out="$(FM_HOME="$tmp" "$bin" --now 12:30 --weekday Wed)"
now_field="${out#*now=}"; now_field="${now_field%% *}"
case "$now_field" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T12:30[-+][0-9][0-9][0-9][0-9]) ;;
  *) fail "expected ISO8601 now field, got: $now_field" ;;
esac

# 3. workdays=none disables the working band entirely.
mkdir -p "$tmp/config"
printf 'workdays=none\n' > "$tmp/config/working-hours"
out="$(FM_HOME="$tmp" "$bin" --now 09:30 --weekday Wed)"
case "$out" in *"band=offhours offer=yes "*"source=config"*) ;; *) fail "workdays=none: $out" ;; esac
rm -f "$tmp/config/working-hours"

# 4. Config override changes the resolved band and reports source=config.
printf 'lunch=11:00-14:00\n' > "$tmp/config/working-hours"
out="$(FM_HOME="$tmp" "$bin" --now 13:30 --weekday Wed)"
case "$out" in *"band=lunch offer=yes "*"source=config"*) ;; *) fail "config lunch override: $out" ;; esac
rm -f "$tmp/config/working-hours"

# 4b. A comments-only config reports source=default (no key was read).
printf '# just a comment\n\n' > "$tmp/config/working-hours"
out="$(FM_HOME="$tmp" "$bin" --now 09:30 --weekday Wed)"
case "$out" in *"source=default"*) ;; *) fail "comments-only config: $out" ;; esac
rm -f "$tmp/config/working-hours"

# 5. Malformed config is rejected loudly, not silently defaulted.
printf 'start=9am\n' > "$tmp/config/working-hours"
if FM_HOME="$tmp" "$bin" --now 09:30 --weekday Wed >/dev/null 2>"$tmp/err"; then
  fail "expected non-zero exit on malformed start"
fi
grep -q "malformed" "$tmp/err" || fail "expected malformed diagnostic, got: $(cat "$tmp/err")"
rm -f "$tmp/config/working-hours"

# 6. An unknown tz is rejected loudly rather than silently falling back to UTC.
printf 'tz=Amerca/Toronto\n' > "$tmp/config/working-hours"
if FM_HOME="$tmp" "$bin" --now 09:30 --weekday Wed >/dev/null 2>"$tmp/err"; then
  fail "expected non-zero exit on unknown tz"
fi
grep -q "tz" "$tmp/err" || fail "expected tz diagnostic, got: $(cat "$tmp/err")"
rm -f "$tmp/config/working-hours"

# 7. A transposed start/end is rejected rather than silently disabling working hours.
printf 'start=17:00\nend=09:00\n' > "$tmp/config/working-hours"
if FM_HOME="$tmp" "$bin" --now 10:00 --weekday Wed >/dev/null 2>"$tmp/err"; then
  fail "expected non-zero exit on transposed start/end"
fi
grep -q "start must precede end" "$tmp/err" || fail "expected start/end diagnostic, got: $(cat "$tmp/err")"
rm -f "$tmp/config/working-hours"

# 8. --weekday without --now is a usage error, and the injected weekday drives the ISO date.
if FM_HOME="$tmp" "$bin" --weekday Sat >/dev/null 2>"$tmp/err"; then
  fail "expected non-zero exit for --weekday without --now"
fi
grep -q -- "--weekday requires --now" "$tmp/err" || fail "expected usage diagnostic, got: $(cat "$tmp/err")"

out="$(FM_HOME="$tmp" "$bin" --now 12:30 --weekday Wed)"
now_field="${out#*now=}"; now_field="${now_field%% *}"
iso_day="$(TZ=America/Toronto date -d "${now_field%T*}" +%a)"
[ "$iso_day" = "Wed" ] || fail "ISO date weekday should match --weekday, got $iso_day in: $out"

echo "PASS: fm-captain-window.test.sh"

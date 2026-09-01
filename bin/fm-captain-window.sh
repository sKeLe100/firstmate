#!/usr/bin/env bash
# bin/fm-captain-window.sh - single owner of the captain attention band.
#
# Why: proactive decision batching (state/noon-decision-batch.check.sh,
# state/debrief-trigger.check.sh) must agree on whether now is inside the
# captain's working day, a quiet band, or an offer window (lunch, evening,
# offhours). Every consumer reads this band rather than re-deriving windows
# from `date` itself, matching how fm-context-usage.sh is the one owner of
# the session-context band.
#
# Usage: fm-captain-window.sh [--now HH:MM] [--weekday Mon..Sun]
#   --now and --weekday are for the colocated test only; without them the
#   helper reads the real local clock under the configured (or system) tz.
#
# Output is one data-only line:
#   band=quiet|working|lunch|evening|offhours offer=yes|no now=<ISO8601> tz=<tz> source=config|default
#
# band meanings:
#   quiet    - the captain's overnight window; offer=no.
#   working  - inside workdays/start-end; offer=no.
#   lunch    - inside the lunch offer window; offer=yes.
#   evening  - inside the evening offer window; offer=yes.
#   offhours - every other hour outside quiet (including all day on a
#              non-working day, or every hour when workdays=none); offer=yes.
#
# Config: optional config/working-hours under FM_HOME (or the current
# directory), one key=value per line, `#` comments allowed:
#   tz=America/Toronto
#   workdays=Mon-Fri        # a day range, a comma list (Mon,Tue,Thu), or "none"
#   start=09:00
#   end=17:00
#   lunch=12:00-13:00
#   evening=17:30-22:00
#   quiet=23:00-06:00
# An absent file or absent key uses the built-in defaults above (source=default
# unless any key was read from the file, in which case source=config).
# Malformed content is rejected loudly with a non-zero exit, never silently
# replaced by a default (house rule, same contract as config/context-thresholds).
# Not inherited by secondmate homes - see docs/configuration.md.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

fail() {
  echo "fm-captain-window: $1" >&2
  exit 1
}

opt_now=""
opt_weekday=""
while [ $# -gt 0 ]; do
  case "$1" in
    --now) opt_now="${2:-}"; shift 2 ;;
    --weekday) opt_weekday="${2:-}"; shift 2 ;;
    *) fail "unrecognized argument: $1" ;;
  esac
done

if [ -n "$opt_weekday" ] && [ -z "$opt_now" ]; then
  fail "--weekday requires --now"
fi

home_path="${FM_HOME:-$PWD}"

tz=America/Toronto
workdays=Mon-Fri
start=09:00
end=17:00
lunch=12:00-13:00
evening=17:30-22:00
quiet=23:00-06:00
source=default

cfg="$home_path/config/working-hours"
if [ -e "$cfg" ]; then
  [ -f "$cfg" ] || fail "$cfg is not a regular file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      tz=*) tz="${line#tz=}"; source=config ;;
      workdays=*) workdays="${line#workdays=}"; source=config ;;
      start=*) start="${line#start=}"; source=config ;;
      end=*) end="${line#end=}"; source=config ;;
      lunch=*) lunch="${line#lunch=}"; source=config ;;
      evening=*) evening="${line#evening=}"; source=config ;;
      quiet=*) quiet="${line#quiet=}"; source=config ;;
      *) fail "unrecognized line in $cfg: $line" ;;
    esac
  done < "$cfg"
fi

hhmm_re='^([01][0-9]|2[0-3]):[0-5][0-9]$'
if [ -n "$opt_now" ]; then
  printf '%s' "$opt_now" | grep -Eq "$hhmm_re" || fail "malformed --now value: $opt_now"
fi
for pair in "start:$start" "end:$end"; do
  name="${pair%%:*}"; val="${pair#*:}"
  printf '%s' "$val" | grep -Eq "$hhmm_re" || fail "malformed $name in $cfg: $val"
done
[ "${start//:/}" -lt "${end//:/}" ] || fail "start must precede end in $cfg: $start-$end"
range_re='^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$'
for pair in "lunch:$lunch" "evening:$evening" "quiet:$quiet"; do
  name="${pair%%:*}"; val="${pair#*:}"
  printf '%s' "$val" | grep -Eq "$range_re" || fail "malformed $name range in $cfg: $val"
done

days=(Sun Mon Tue Wed Thu Fri Sat)
day_index() {
  local d="$1" i
  for i in "${!days[@]}"; do
    [ "${days[$i]}" = "$d" ] && { echo "$i"; return 0; }
  done
  return 1
}

if [ -n "$opt_weekday" ]; then
  day_index "$opt_weekday" >/dev/null || fail "unrecognized --weekday value: $opt_weekday"
fi

workdays_set=""
if [ "$workdays" != "none" ]; then
  case "$workdays" in
    *-*)
      lo="${workdays%%-*}"; hi="${workdays##*-}"
      lo_i=$(day_index "$lo") || fail "malformed workdays in $cfg: $workdays"
      hi_i=$(day_index "$hi") || fail "malformed workdays in $cfg: $workdays"
      [ "$lo_i" -le "$hi_i" ] || fail "malformed workdays range in $cfg: $workdays"
      i="$lo_i"
      while [ "$i" -le "$hi_i" ]; do
        workdays_set="$workdays_set ${days[$i]}"
        i=$((i + 1))
      done
      ;;
    *)
      IFS=',' read -ra parts <<< "$workdays"
      for p in "${parts[@]}"; do
        day_index "$p" >/dev/null || fail "malformed workdays entry in $cfg: $p"
        workdays_set="$workdays_set $p"
      done
      ;;
  esac
fi

printf '%s' "$tz" | grep -Eq '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$' || fail "malformed tz in $cfg: $tz"
tz_resolves() {
  case "$tz" in
    UTC|GMT|Etc/UTC|Etc/GMT|Universal|Zulu) return 0 ;;
  esac
  [ -f "/usr/share/zoneinfo/$tz" ] && return 0
  [ "$(TZ="$tz" date +%z%Z)" != "$(TZ=FmNoSuchZone date +%z%Z)" ]
}
tz_resolves || fail "unknown tz in $cfg: $tz"
export TZ="$tz"
if [ -n "$opt_now" ]; then
  now_hhmm="$opt_now"
  if [ -n "$opt_weekday" ]; then
    weekday="$opt_weekday"
    back=0
    while [ "$(date -d "-$back days" +%a)" != "$weekday" ]; do
      back=$((back + 1))
      [ "$back" -le 6 ] || fail "could not resolve a date for --weekday $weekday"
    done
    now_date="$(date -d "-$back days" +%Y-%m-%d)"
  else
    weekday="$(date +%a)"
    now_date="$(date +%Y-%m-%d)"
  fi
  now_iso="$(date -d "$now_date $opt_now" +%Y-%m-%dT%H:%M%z)"
else
  now_hhmm="$(date +%H:%M)"
  weekday="$(date +%a)"
  now_iso="$(date +%Y-%m-%dT%H:%M%z)"
fi

hhmm_to_min() {
  local h="${1%%:*}" m="${1##*:}"
  echo $((10#$h * 60 + 10#$m))
}

in_range() {
  local now_m="$1" range="$2" lo hi lo_m hi_m
  lo="${range%-*}"; hi="${range#*-}"
  lo_m=$(hhmm_to_min "$lo"); hi_m=$(hhmm_to_min "$hi")
  if [ "$lo_m" -le "$hi_m" ]; then
    [ "$now_m" -ge "$lo_m" ] && [ "$now_m" -lt "$hi_m" ]
  else
    [ "$now_m" -ge "$lo_m" ] || [ "$now_m" -lt "$hi_m" ]
  fi
}

now_m=$(hhmm_to_min "$now_hhmm")
is_workday=1
for w in $workdays_set; do
  [ "$w" = "$weekday" ] && is_workday=0
done

band=""
if in_range "$now_m" "$quiet"; then
  band=quiet
elif [ "$is_workday" -eq 0 ] && in_range "$now_m" "$lunch"; then
  band=lunch
elif [ "$is_workday" -eq 0 ] && [ "$now_m" -ge "$(hhmm_to_min "$start")" ] && [ "$now_m" -lt "$(hhmm_to_min "$end")" ]; then
  band=working
elif [ "$is_workday" -eq 0 ] && in_range "$now_m" "$evening"; then
  band=evening
else
  band=offhours
fi

offer=no
case "$band" in
  lunch|evening|offhours) offer=yes ;;
esac

printf 'band=%s offer=%s now=%s tz=%s source=%s\n' "$band" "$offer" "$now_iso" "$tz" "$source"

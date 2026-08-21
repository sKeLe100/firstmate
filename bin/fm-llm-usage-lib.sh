#!/usr/bin/env bash
# Shared writer for the firstmate-side half of the LLM usage telemetry
# archive. Full record schema and the cross-source contract PC02's
# serving-side collector implements against: docs/llm-usage-telemetry.md.
#
# fm_llm_usage_emit <fm-home> <event-type> <field=value>...
#   Appends one JSON object per line to <fm-home>/data/llm-usage/firstmate.jsonl
#   (created on first use). A field whose value is empty is omitted from the
#   record rather than written as "". Every value is escaped as a JSON string;
#   this library never attempts numeric or boolean JSON types.
#   Best-effort and silent on the happy path: a write failure is appended to
#   <fm-home>/state/llm-usage-write-errors.log (itself best-effort) and this
#   function still returns 0, because a telemetry failure must never block or
#   alter the dispatch, relaunch, or teardown it is called from.

fm_llm_usage_json_escape() {  # <string>
  local s=$1 c i
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  for i in $(seq 1 31); do
    case "$i" in
      8|9|10|12|13) continue ;;
    esac
    printf -v c '%b' "\\$(printf '%03o' "$i")"
    case "$s" in
      *"$c"*) s=${s//"$c"/$(printf '\\u%04x' "$i")} ;;
    esac
  done
  printf '%s' "$s"
}

fm_llm_usage_emit() {  # <fm-home> <event-type> <field=value>...
  local home=$1 event_type=$2
  shift 2 || return 0
  (
    dir="$home/data/llm-usage"
    mkdir -p "$dir" || exit 1
    file="$dir/firstmate.jsonl"
    lockfile="$dir/.firstmate.jsonl.lock"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    body="{\"schema_version\":1,\"ts\":\"$(fm_llm_usage_json_escape "$ts")\",\"source\":\"firstmate\",\"event_type\":\"$(fm_llm_usage_json_escape "$event_type")\""
    for kv in "$@"; do
      k=${kv%%=*}
      v=${kv#*=}
      [ -n "$v" ] || continue
      body="$body,\"$(fm_llm_usage_json_escape "$k")\":\"$(fm_llm_usage_json_escape "$v")\""
    done
    body="$body}"
    held=0
    if declare -f fm_lock_try_acquire >/dev/null 2>&1; then
      attempt=0
      while [ "$attempt" -lt 20 ]; do
        if fm_lock_try_acquire "$lockfile"; then
          held=1
          break
        fi
        attempt=$((attempt + 1))
        sleep 0.1
      done
    fi
    printf '%s\n' "$body" >> "$file"
    status=$?
    [ "$held" -eq 1 ] && fm_lock_release "$lockfile"
    exit "$status"
  ) 2>>"$home/state/llm-usage-write-errors.log"
  return 0
}

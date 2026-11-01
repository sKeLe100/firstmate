#!/usr/bin/env bash
# bin/fm-context-usage.sh - report a Claude session's real context usage from
# the harness's own durable transcript records.
#
# Why: the agent cannot run the terminal-side /context command itself, and the
# padded-countdown token reminder can stick at 0 for a whole session, so any
# captain-facing context number must come from a durable source instead.
# Every Claude Code transcript line for an assistant turn carries a usage
# object whose input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens sum is the context size actually sent for that turn,
# which is the same total the /context command displays.
#
# Usage: fm-context-usage.sh [transcript.jsonl]
#   With no argument, reads the Claude project directory for this home:
#     <store>/projects/<home path with every non-alphanumeric character
#     replaced by ->, home = FM_HOME or the current directory.
#   A self-read binds to the calling session's own transcript, the file named by
#   its CLAUDE_CODE_SESSION_ID, and falls back to the newest *.jsonl with
#   pick=newest only when it has no usable id or no resolved store holds that
#   session's transcript. A targeted read (FM_CLAUDE_STORE set) takes the newest
#   *.jsonl in the named store.
#   <store> is the one the TARGET session writes, resolved in this order:
#   - FM_CLAUDE_STORE names the store of ANOTHER session: the account= a spawn
#     recorded for it - the absolute root a config/claude-account pin names,
#     `ordinary` for the vendor default login ($HOME/.claude), or `auto` for a
#     task that recorded no pin and so inherited the store resolved below
#     (docs/configuration.md "Worker account pin"). Any other value, including
#     a relative path, is refused.
#   - otherwise this process's own ${CLAUDE_CONFIG_DIR:-$HOME/.claude}, which is
#     the store of the session reading its own usage; when that store holds no
#     project directory for the home being read, the default $HOME/.claude is
#     tried too, so a crew launched with CLAUDE_CONFIG_DIR unset is still found
#     by a supervisor running under a different store.
#   A relative CLAUDE_CONFIG_DIR is refused rather than resolved against this
#   process's cwd, because it cannot then name the store the session actually
#   uses.
#
#   A self-read (no explicit transcript argument, no FM_CLAUDE_STORE) binds to
#   the calling session's own transcript rather than to whichever file was
#   written last: CLAUDE_CODE_SESSION_ID, which Claude Code exports to every hook
#   and tool shell and which equals the transcript's basename, names
#   <store>/projects/<munged>/<id>.jsonl when it matches
#   ^[A-Za-z0-9][A-Za-z0-9._-]*$ (so it can only ever name a file directly under
#   the project directory) and that file exists in a resolved store; the output
#   then carries pick=session. A second live session in the same home appends to
#   its own transcript, so it can no longer take over this reading. Without a
#   usable id, or when no resolved store holds that session's transcript, the
#   reading falls back to the most recently modified *.jsonl and reports
#   pick=newest: a harness that exports no id, and a session that has not written
#   yet, still get a reading, just not a session-bound one. The home's
#   state/.lock-session records whichever session holds the home's lock, not the
#   caller, and no Herdr query is made, so this needs no sidecar and no
#   subprocess.
#
#   Auto-discovery refuses to report a confident band from a stale transcript
#   when the read is this process's own session (no FM_CLAUDE_STORE): when the
#   transcript it picked - session-bound or the newest-mtime fallback - is older
#   than FM_CONTEXT_STALE_SECONDS (default 900; 0 turns this guard off) it still
#   reports the tokens it found but sets band=unavailable with
#   reason=stale-transcript, exiting 0. A read that names a target store is a
#   read of another session, which is idle by definition, so it reports the band
#   it finds however old that transcript is. An explicit transcript argument is
#   trusted as given and never gets this guard.
#
# Output is one data-only line; callers act on the reported band rather than
# re-deriving thresholds:
#   context_tokens=<N> window=<W> percent=<P> warn_tokens=<W1> \
#     restart_tokens=<W2> band=<ok|warn|restart|unavailable> transcript=<path> \
#     age_seconds=<S> [pick=session|newest] [reason=stale-transcript]
# pick appears only on a self-read, naming whether that reading is bound to the
# calling session's own transcript (session) or fell back to the newest one
# (newest); a targeted or explicit read carries no pick field.
# The window defaults to 1000000 and can be overridden with FM_CONTEXT_WINDOW
# when a harness or model change alters the real window.
#
# Bands implement the captain's session-context policy (directive 2026-08-26):
#   ok      - below the warning threshold; keep working.
#   warn    - at or past the warning threshold (default 150000); surface the
#             level in the next natural report.
#   restart - at or past the restart threshold (default 250000); the session
#             must not keep grinding: checkpoint durable state (/stow for a
#             firstmate home), restart with a carryover handoff
#             (bin/fm-control.sh <id> relaunch --note for a crewmate, or a
#             fresh session for a primary), and wake/advise the main session.
#             Never send /clear through the steer channel - it is mechanically
#             broken.
#   unavailable - the transcript a self-read picked - its own session's, or the
#             newest-mtime fallback - is stale, so the reading is not evidence
#             of a current band; report the reading as unavailable rather than
#             quoting it as the session's context.
# Thresholds come from config/context-thresholds under the same home used for
# transcript discovery: optional `warn=<N>` and `restart=<N>` lines, one per
# line, each a positive base-10 integer, warn <= restart. A malformed file is
# rejected loudly rather than silently replaced by defaults. The file is
# inherited by secondmate homes via FM_INHERITABLE_CONFIG
# (bin/fm-config-inherit-lib.sh), so the primary's thresholds propagate.
# For another session's usage (a crewmate or secondmate), run with FM_HOME set
# to that session's working directory (task worktree or secondmate home) and
# FM_CLAUDE_STORE set to the account= recorded for that task, or to `auto` when
# it recorded no pin: every cross-session read names its store, because a read
# that names none is this process's own and gets the staleness guard above.
#
# Subagent (sidechain) turns are excluded so a spawned helper's smaller
# context never masquerades as the primary session's usage.
#
# Fails with a clear message on exit 1 when no transcript or usage record
# exists - for example under a non-claude primary harness - rather than
# guessing.
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,108p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

home_path="${FM_HOME:-$PWD}"

# Threshold resolution: defaults, then a strict optional config/context-thresholds.
warn_tokens=150000
restart_tokens=250000
thresholds_file="$home_path/config/context-thresholds"
if [ -e "$thresholds_file" ]; then
  if [ ! -f "$thresholds_file" ]; then
    echo "fm-context-usage: $thresholds_file is not a regular file" >&2
    exit 1
  fi
  while IFS= read -r tline || [ -n "$tline" ]; do
    case "$tline" in
      '') continue ;;
      warn=*)
        val="${tline#warn=}"
        case "$val" in ''|*[!0-9]*) echo "fm-context-usage: malformed warn value in $thresholds_file: $tline" >&2; exit 1 ;; esac
        warn_tokens="$val" ;;
      restart=*)
        val="${tline#restart=}"
        case "$val" in ''|*[!0-9]*) echo "fm-context-usage: malformed restart value in $thresholds_file: $tline" >&2; exit 1 ;; esac
        restart_tokens="$val" ;;
      *)
        echo "fm-context-usage: unrecognized line in $thresholds_file: $tline" >&2
        exit 1 ;;
    esac
  done < "$thresholds_file"
  if [ "$warn_tokens" -le 0 ] || [ "$restart_tokens" -le 0 ] || [ "$warn_tokens" -gt "$restart_tokens" ]; then
    echo "fm-context-usage: thresholds must be positive with warn <= restart in $thresholds_file (warn=$warn_tokens restart=$restart_tokens)" >&2
    exit 1
  fi
fi

# Staleness limit for the auto-picked transcript, in seconds; 0 turns it off.
stale_seconds="${FM_CONTEXT_STALE_SECONDS:-900}"
case "$stale_seconds" in
  ''|*[!0-9]*) echo "fm-context-usage: FM_CONTEXT_STALE_SECONDS must be a non-negative integer: $stale_seconds" >&2; exit 1 ;;
esac

transcript="${1:-}"
self_read=0
pick=
if [ -z "$transcript" ]; then
  targeted=0
  stores=()
  case "${FM_CLAUDE_STORE:-}" in
    '') ;;
    auto) targeted=1 ;;
    ordinary)
      targeted=1
      if [ -n "${HOME:-}" ]; then
        stores=("$HOME/.claude")
      else
        echo "fm-context-usage: FM_CLAUDE_STORE=ordinary needs HOME to locate the default Claude config directory" >&2
        exit 1
      fi ;;
    /*) targeted=1; stores=("$FM_CLAUDE_STORE") ;;
    *) echo "fm-context-usage: FM_CLAUDE_STORE must be auto, ordinary or an absolute path: $FM_CLAUDE_STORE" >&2; exit 1 ;;
  esac
  if [ "${#stores[@]}" -eq 0 ]; then
    case ${CLAUDE_CONFIG_DIR:-} in
      '') if [ -n "${HOME:-}" ]; then
            stores=("$HOME/.claude")
          else
            echo "fm-context-usage: neither CLAUDE_CONFIG_DIR nor HOME is set, so the Claude config directory cannot be located" >&2
            exit 1
          fi ;;
      /*) stores=("$CLAUDE_CONFIG_DIR") ;;
      *) echo "fm-context-usage: CLAUDE_CONFIG_DIR '$CLAUDE_CONFIG_DIR' is a relative path, so the transcript store the session reads cannot be guaranteed to be the one named here; set it to an absolute path" >&2; exit 1 ;;
    esac
    if [ -n "${HOME:-}" ] && [ "${stores[0]}" != "$HOME/.claude" ]; then
      stores+=("$HOME/.claude")
    fi
  fi
  [ "$targeted" -eq 1 ] || self_read=1
  munged="$(printf '%s' "$home_path" | tr -c 'a-zA-Z0-9' '-')"
  transcript=
  if [ "$self_read" -eq 1 ]; then
    case "${CLAUDE_CODE_SESSION_ID:-}" in
      ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) ;;
      *) for store in "${stores[@]}"; do
           if [ -f "$store/projects/$munged/$CLAUDE_CODE_SESSION_ID.jsonl" ]; then
             transcript="$store/projects/$munged/$CLAUDE_CODE_SESSION_ID.jsonl"
             pick=session
             break
           fi
         done ;;
    esac
  fi
  if [ -z "$transcript" ]; then
    proj_dir=
    for store in "${stores[@]}"; do
      if [ -d "$store/projects/$munged" ]; then
        proj_dir="$store/projects/$munged"
        break
      fi
    done
    if [ -z "$proj_dir" ]; then
      candidates=
      for store in "${stores[@]}"; do
        candidates="${candidates:+$candidates, }$store/projects/$munged"
      done
      echo "fm-context-usage: no Claude transcript directory at $candidates (non-claude harness, or no session yet)" >&2
      exit 1
    fi
    transcript="$(find "$proj_dir" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    if [ -z "$transcript" ]; then
      echo "fm-context-usage: no *.jsonl transcript found under $proj_dir" >&2
      exit 1
    fi
    if [ "$self_read" -eq 1 ]; then
      pick=newest
    fi
  fi
fi

if [ ! -f "$transcript" ]; then
  echo "fm-context-usage: transcript not found: $transcript" >&2
  exit 1
fi

window="${FM_CONTEXT_WINDOW:-1000000}"

python3 - "$transcript" "$window" "$warn_tokens" "$restart_tokens" "$self_read" "$stale_seconds" "$pick" <<'PY'
import json, os, sys, time

path, window = sys.argv[1], int(sys.argv[2])
warn, restart = int(sys.argv[3]), int(sys.argv[4])
self_read = sys.argv[5] == "1"
stale_seconds = int(sys.argv[6])
pick = sys.argv[7]
last = None
with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line or '"usage"' not in line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("type") != "assistant" or entry.get("isSidechain"):
            continue
        usage = (entry.get("message") or {}).get("usage")
        if isinstance(usage, dict):
            last = usage

if last is None:
    sys.stderr.write("fm-context-usage: no assistant usage record in %s\n" % path)
    sys.exit(1)

total = sum(
    int(last.get(k) or 0)
    for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
)
age = max(0, int(time.time() - os.path.getmtime(path)))
if self_read and stale_seconds > 0 and age > stale_seconds:
    band = "unavailable"
else:
    band = "restart" if total >= restart else "warn" if total >= warn else "ok"
reason = " reason=stale-transcript" if band == "unavailable" else ""
pick_field = " pick=%s" % pick if pick else ""
print(
    "context_tokens=%d window=%d percent=%.1f warn_tokens=%d restart_tokens=%d"
    " band=%s transcript=%s age_seconds=%d%s%s"
    % (
        total,
        window,
        100.0 * total / window if window else 0.0,
        warn,
        restart,
        band,
        path,
        age,
        pick_field,
        reason,
    )
)
PY

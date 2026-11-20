#!/usr/bin/env bash
# bin/fm-opencode-context-usage.sh - report an OpenCode session's current
# context usage from OpenCode's own durable session store.
#
# Why: bin/fm-context-usage.sh reads Claude transcripts, so an OpenCode worker's
# context band had no source and the /fleet snapshot showed `n/a` for it. This
# reader is that source for OpenCode, and it reports the SAME bands, thresholds,
# and band words as the Claude path so callers need no per-harness rule.
#
# Source: OpenCode's SQLite store, opened strictly read-only with python3's
# sqlite3 module (the sqlite3 CLI is not assumed to exist):
#   <store>/opencode.db   default <XDG_DATA_HOME or ~/.local/share>/opencode
# Each `message` row's JSON `data` carries one turn's token usage. This reader
# takes the newest assistant message that has real usage and sums
# input + cache.read + cache.write for it, the same "context sent for the turn"
# total the Claude reader derives from input + cache_creation + cache_read.
# Output, reasoning, and cost are excluded.
#
# Session matching:
#   - --session-file <path> names a file holding the task's recorded OpenCode
#     session id (state/<id>.opencode-session, written by the spawn plugin). The
#     id is trusted when it is a safe single token and the session exists; this
#     is the precise binding for a worktree that has hosted earlier tasks.
#   - Otherwise the newest root session (parent_id IS NULL, so a spawned helper
#     session never wins) whose `session.directory` equals --worktree, or
#     FM_HOME/the current directory when --worktree is absent, is used.
#
# Context window per model:
#   OpenCode's own model catalog (<XDG_CACHE_HOME or ~/.cache>/opencode/
#   models.json) is consulted for provider/model `limit.context`, then the
#   local OpenCode config (opencode.jsonc/opencode.json) for the same override.
#   The provider/model come from the session's own assistant message or
#   session.model. When no window is known the reader still reports the token
#   count but sets band=unknown (reason=unknown-window) rather than guessing.
#
# Thresholds: config/context-thresholds under FM_HOME, the same optional
# `warn=<N>` and `restart=<N>` lines and defaults (150000/250000) as
# bin/fm-context-usage.sh; a malformed file is rejected loudly. These are not
# duplicated policy - the Claude reader's header and docs/configuration.md
# "Session context thresholds" own them.
#
# Output is one data-only line, mirroring bin/fm-context-usage.sh:
#   context_tokens=<N|unknown> window=<W|unknown> percent=<P|-> \
#     warn_tokens=<W1> restart_tokens=<W2> band=<ok|warn|restart|unknown> \
#     harness=opencode session=<id|-> age_seconds=<S|-> \
#     match=<session|worktree> [reason=<slug>]
# An unreadable store, a missing session, and a locked database are all
# band=unknown with a reason (no-store, no-session, locked, unreadable,
# no-usage, unknown-window), never ok.
#
# Usage: fm-opencode-context-usage.sh [--worktree <dir>] [--session-file <file>]
#
# Env:
#   FM_OPENCODE_STORE          store root holding opencode.db
#   FM_OPENCODE_DB             exact database path (overrides the store)
#   FM_OPENCODE_MODELS         model catalog JSON path
#   FM_OPENCODE_CONFIG         OpenCode config path (default jsonc/json discovery)
#   FM_OPENCODE_BUSY_TIMEOUT   sqlite busy timeout seconds (default 5)
#   FM_HOME                    worktree used when --worktree is absent
set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,59p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

worktree=
session_file=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --worktree)
      [ "$#" -ge 2 ] || { echo "fm-opencode-context-usage: --worktree needs a directory" >&2; exit 2; }
      worktree=$2; shift 2 ;;
    --session-file)
      [ "$#" -ge 2 ] || { echo "fm-opencode-context-usage: --session-file needs a path" >&2; exit 2; }
      session_file=$2; shift 2 ;;
    *) echo "fm-opencode-context-usage: unknown argument: $1" >&2; exit 2 ;;
  esac
done
worktree=${worktree:-${FM_HOME:-$PWD}}

# Threshold resolution: defaults, then a strict optional config/context-thresholds.
warn_tokens=150000
restart_tokens=250000
thresholds_file="$FM_HOME/config/context-thresholds"
if [ -n "${FM_HOME:-}" ] && [ -e "$thresholds_file" ]; then
  if [ ! -f "$thresholds_file" ]; then
    echo "fm-opencode-context-usage: $thresholds_file is not a regular file" >&2
    exit 1
  fi
  while IFS= read -r tline || [ -n "$tline" ]; do
    case "$tline" in
      '') continue ;;
      warn=*)
        val="${tline#warn=}"
        case "$val" in ''|*[!0-9]*) echo "fm-opencode-context-usage: malformed warn value in $thresholds_file: $tline" >&2; exit 1 ;; esac
        warn_tokens="$val" ;;
      restart=*)
        val="${tline#restart=}"
        case "$val" in ''|*[!0-9]*) echo "fm-opencode-context-usage: malformed restart value in $thresholds_file: $tline" >&2; exit 1 ;; esac
        restart_tokens="$val" ;;
      *)
        echo "fm-opencode-context-usage: unrecognized line in $thresholds_file: $tline" >&2
        exit 1 ;;
    esac
  done < "$thresholds_file"
  if [ "$warn_tokens" -le 0 ] || [ "$restart_tokens" -le 0 ] || [ "$warn_tokens" -gt "$restart_tokens" ]; then
    echo "fm-opencode-context-usage: thresholds must be positive with warn <= restart in $thresholds_file (warn=$warn_tokens restart=$restart_tokens)" >&2
    exit 1
  fi
fi

data_home=${XDG_DATA_HOME:-${HOME:-}/.local/share}
cache_home=${XDG_CACHE_HOME:-${HOME:-}/.cache}
config_home=${XDG_CONFIG_HOME:-${HOME:-}/.config}
store=${FM_OPENCODE_STORE:-$data_home/opencode}
db_path=${FM_OPENCODE_DB:-$store/opencode.db}
models_path=${FM_OPENCODE_MODELS:-$cache_home/opencode/models.json}
config_path=${FM_OPENCODE_CONFIG:-}
busy_timeout=${FM_OPENCODE_BUSY_TIMEOUT:-5}
case "$busy_timeout" in ''|*[!0-9]*) busy_timeout=5 ;; esac

python3 - "$worktree" "$session_file" "$db_path" "$models_path" "$config_path" \
  "$config_home/opencode" "$warn_tokens" "$restart_tokens" "$busy_timeout" <<'PY'
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path

(
    worktree,
    session_file,
    db_path,
    models_path,
    config_path,
    config_dir,
    warn,
    restart,
    busy_timeout,
) = sys.argv[1:]
warn, restart, busy = int(warn), int(restart), int(busy_timeout)

def emit(tokens, window, band, sid, age, match, reason):
    if tokens is None:
        tok = "unknown"
    else:
        tok = str(tokens)
    if window:
        percent = "%.1f" % (100.0 * tokens / window) if tokens is not None else "-"
        win = str(window)
    else:
        percent = "-"
        win = "unknown"
    line = (
        "context_tokens=%s window=%s percent=%s warn_tokens=%d restart_tokens=%d"
        " band=%s harness=opencode session=%s age_seconds=%s match=%s"
        % (tok, win, percent, warn, restart, band, sid or "-",
           "unknown" if age is None else str(age), match or "-")
    )
    if reason:
        line += " reason=%s" % reason
    print(line)
    sys.exit(0)

def band_for(tokens):
    if tokens is None:
        return "unknown"
    return "restart" if tokens >= restart else "warn" if tokens >= warn else "ok"

def usage_tokens(data):
    try:
        d = json.loads(data)
    except (TypeError, ValueError):
        return None
    if not isinstance(d, dict) or d.get("role") != "assistant":
        return None
    t = d.get("tokens") or {}
    cache = t.get("cache") or {}
    try:
        total = int(t.get("input") or 0) + int(cache.get("read") or 0) + int(cache.get("write") or 0)
    except (TypeError, ValueError):
        return None
    return total

def strip_jsonc(text):
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        ch = text[i]
        if in_str:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == '"':
                in_str = False
            i += 1
            continue
        if ch == '"':
            in_str = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)

def load_json(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None

def config_paths():
    if config_path:
        return [config_path]
    return [os.path.join(config_dir, "opencode.jsonc"),
            os.path.join(config_dir, "opencode.json")]

def limit_context(node):
    if not isinstance(node, dict):
        return None
    limit = node.get("limit")
    if isinstance(limit, dict):
        limit = limit.get("context")
    try:
        value = int(limit)
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None

def model_window(provider_id, model_id):
    if not provider_id or not model_id:
        return None
    catalog = load_json(models_path)
    if isinstance(catalog, dict):
        provider = catalog.get(provider_id)
        if isinstance(provider, dict):
            window = limit_context((provider.get("models") or {}).get(model_id))
            if window:
                return window
    for path in config_paths():
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                cfg = json.loads(strip_jsonc(fh.read()))
        except (OSError, ValueError):
            continue
        if not isinstance(cfg, dict):
            continue
        provider = (cfg.get("provider") or {}).get(provider_id)
        if not isinstance(provider, dict):
            continue
        window = limit_context((provider.get("models") or {}).get(model_id))
        if window:
            return window
    return None

def session_model(row):
    raw = row[3]
    if raw:
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                return parsed.get("providerID"), parsed.get("id") or parsed.get("modelID")
        except ValueError:
            pass
    return None, None

# Unreadable store: an absent database is disclosed, not guessed at.
if not os.path.isfile(db_path):
    emit(None, None, "unknown", None, None, None, "no-store")

uri = Path(os.path.abspath(db_path)).as_uri() + "?mode=ro"
try:
    con = sqlite3.connect(uri, uri=True, timeout=busy)
    con.execute("PRAGMA query_only=ON")
except sqlite3.Error as exc:
    reason = "locked" if "locked" in str(exc).lower() or "busy" in str(exc).lower() else "unreadable"
    emit(None, None, "unknown", None, None, None, reason)

sid = None
if session_file:
    try:
        raw = Path(session_file).read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        raw = ""
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", raw or ""):
        sid = raw

row = None
match = None
try:
    if sid:
        row = con.execute(
            "SELECT id, directory, parent_id, model, time_updated"
            " FROM session WHERE id = ?", (sid,)
        ).fetchone()
        if row is not None:
            match = "session"
    if row is None:
        sid = None
        row = con.execute(
            "SELECT id, directory, parent_id, model, time_updated"
            " FROM session WHERE directory = ? AND parent_id IS NULL"
            " ORDER BY time_updated DESC LIMIT 1", (worktree,)
        ).fetchone()
        if row is not None:
            match = "worktree"
except sqlite3.Error as exc:
    reason = "locked" if "locked" in str(exc).lower() or "busy" in str(exc).lower() else "unreadable"
    emit(None, None, "unknown", None, None, None, reason)

if row is None:
    emit(None, None, "unknown", None, None, None, "no-session")

sid = row[0]
now_ms = int(time.time() * 1000)
age = max(0, int((now_ms - int(row[4] or 0)) / 1000))
provider_id, model_id = session_model(row)

tokens = None
try:
    rows = con.execute(
        "SELECT data FROM message WHERE session_id = ?"
        " ORDER BY time_created DESC, id DESC LIMIT 50", (sid,)
    ).fetchall()
except sqlite3.Error as exc:
    reason = "locked" if "locked" in str(exc).lower() or "busy" in str(exc).lower() else "unreadable"
    emit(None, None, "unknown", sid, age, match, reason)

for (data,) in rows:
    total = usage_tokens(data)
    if total is None or total <= 0:
        continue
    tokens = total
    try:
        d = json.loads(data)
        provider_id = d.get("providerID") or provider_id
        model_id = d.get("modelID") or model_id
    except ValueError:
        pass
    break

if tokens is None:
    emit(None, None, "unknown", sid, age, match, "no-usage")

window = model_window(provider_id, model_id)
if not window:
    emit(tokens, None, "unknown", sid, age, match, "unknown-window")

emit(tokens, window, band_for(tokens), sid, age, match, None)
PY

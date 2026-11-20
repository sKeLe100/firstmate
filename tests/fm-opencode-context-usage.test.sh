#!/usr/bin/env bash
# tests/fm-opencode-context-usage.test.sh - behavior tests for
# bin/fm-opencode-context-usage.sh. Exercises the reader through its executable
# interface against synthetic SQLite stores: worktree and recorded-session
# matching, the newest real assistant usage, the model catalog and config window
# lookup, the shared context bands and thresholds, and the disclosed-unknown
# paths (no store, no session, locked database, no usage, unknown window).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin/fm-opencode-context-usage.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

make_db() {  # <db> <spec-json>
  python3 - "$1" "$2" <<'PY'
import json, sqlite3, sys
db, spec = sys.argv[1], json.load(open(sys.argv[2]))
con = sqlite3.connect(db)
con.executescript(
    "CREATE TABLE session (id text PRIMARY KEY, directory text, parent_id text,"
    " model text, time_updated integer);"
    "CREATE TABLE message (id text PRIMARY KEY, session_id text,"
    " time_created integer, data text);"
)
for s in spec.get("sessions", []):
    con.execute(
        "INSERT INTO session VALUES (?,?,?,?,?)",
        (s["id"], s["directory"], s.get("parent_id"), s.get("model"), s["time_updated"]),
    )
for m in spec.get("messages", []):
    con.execute(
        "INSERT INTO message VALUES (?,?,?,?)",
        (m["id"], m["session_id"], m["time_created"], json.dumps(m["data"])),
    )
con.commit()
con.close()
PY
}

assistant() {  # <input> <cache-read> <cache-write> [provider] [model]
  printf '{"role":"assistant","providerID":"%s","modelID":"%s","tokens":{"input":%d,"output":999,"reasoning":40,"cache":{"read":%d,"write":%d}}}' \
    "${4:-opencode-go}" "${5:-deepseek-v4.1-flash}" "$1" "$2" "$3"
}

write_catalog() {  # <path>
  printf '%s\n' '{"opencode-go":{"models":{"deepseek-v4.1-flash":{"limit":{"context":200000}}}}}' > "$1"
}

# A catalog containing the test models, and a config with one override for a
# model the catalog does not know.
catalog="$tmp/models.json"
write_catalog "$catalog"
mkdir -p "$tmp/opencode"
cat > "$tmp/opencode/opencode.jsonc" <<'EOF'
{
  // the local llama-swap override
  "provider": {
    "pc02-llamaswap": {
      "models": {
        "qwen3.6-35b-a3b-dispatch": { "limit": { "context": 262144, "output": 32768 } }
      }
    }
  }
}
EOF

base_env() {  # <store-dir> [extra args...]
  local store=$1
  shift
  env FM_OPENCODE_STORE="$store" FM_OPENCODE_MODELS="$catalog" \
    FM_OPENCODE_CONFIG="$tmp/opencode/opencode.jsonc" \
    FM_HOME="$tmp/no_config_home" "$bin" "$@"
}

# 1. Worktree match: the newest root session wins over an older root session
#    and a newer child session; the newest assistant message with real usage
#    wins over a later in-progress message with all-zero tokens; input +
#    cache.read + cache.write is the context total; the catalog sets the window.
store1="$tmp/store1"; mkdir -p "$store1"
wt1="$tmp/worktree-one"
cat > "$tmp/spec1.json" <<EOF
{"sessions":[
  {"id":"ses_old","directory":"$wt1","parent_id":null,"model":null,"time_updated":1000},
  {"id":"ses_new","directory":"$wt1","parent_id":null,"model":null,"time_updated":3000},
  {"id":"ses_child","directory":"$wt1","parent_id":"ses_new","model":null,"time_updated":4000}
 ],
 "messages":[
  {"id":"m_old","session_id":"ses_old","time_created":1,
   "data":$(assistant 900000 0 0)},
  {"id":"m_new","session_id":"ses_new","time_created":2,
   "data":$(assistant 10 160000 0)},
  {"id":"m_new_live","session_id":"ses_new","time_created":3,
   "data":{"role":"assistant","providerID":"opencode-go","modelID":"deepseek-v4.1-flash","tokens":{"input":0,"output":0,"cache":{"read":0,"write":0}}}},
  {"id":"m_child","session_id":"ses_child","time_created":4,
   "data":$(assistant 700000 0 0)}
 ]}
EOF
make_db "$store1/opencode.db" "$tmp/spec1.json"
out=$(base_env "$store1" --worktree "$wt1")
case "$out" in
  *"context_tokens=160010 "*) ;;
  *) fail "expected input+cache.read context total, got: $out" ;;
esac
case "$out" in
  *"window=200000 percent=80.0 warn_tokens=150000 restart_tokens=250000 band=warn "*) ;;
  *) fail "expected catalog window and warn band, got: $out" ;;
esac
case "$out" in
  *"session=ses_new "*"match=worktree"*) ;;
  *) fail "expected newest root session via worktree match, got: $out" ;;
esac
case "$out" in
  *"reason="*) fail "a resolved session must carry no reason, got: $out" ;;
esac

# 2. A recorded session file binds to that session even when another session in
#    the same worktree is newer, and reports the restart band.
cat > "$tmp/spec2.json" <<EOF
{"sessions":[
  {"id":"ses_task","directory":"$wt1","parent_id":null,"model":null,"time_updated":2000},
  {"id":"ses_other","directory":"$wt1","parent_id":null,"model":null,"time_updated":9000}
 ],
 "messages":[
  {"id":"m_task","session_id":"ses_task","time_created":1,"data":$(assistant 60000 200000 0)},
  {"id":"m_other","session_id":"ses_other","time_created":2,"data":$(assistant 1 1 0)}
 ]}
EOF
rm -f "$store1/opencode.db"
make_db "$store1/opencode.db" "$tmp/spec2.json"
printf 'ses_task\n' > "$tmp/task.opencode-session"
out=$(base_env "$store1" --worktree "$wt1" --session-file "$tmp/task.opencode-session")
case "$out" in
  *"context_tokens=260000 "*) ;;
  *) fail "expected the recorded session's context total, got: $out" ;;
esac
case "$out" in
  *"band=restart "*"session=ses_task "*"match=session"*) ;;
  *) fail "expected restart band on the recorded session, got: $out" ;;
esac

# 3. An absent or unsafe session id falls back to the worktree match.
printf 'not/a/session\n' > "$tmp/unsafe.opencode-session"
out=$(base_env "$store1" --worktree "$wt1" --session-file "$tmp/unsafe.opencode-session")
case "$out" in
  *"session=ses_other "*"match=worktree"*) ;;
  *) fail "an unsafe session id must fall back to the worktree match, got: $out" ;;
esac
out=$(base_env "$store1" --worktree "$wt1" --session-file "$tmp/missing.opencode-session")
case "$out" in
  *"session=ses_other "*"match=worktree"*) ;;
  *) fail "a missing session file must fall back to the worktree match, got: $out" ;;
esac
printf 'ses_absent\n' > "$tmp/absent.opencode-session"
out=$(base_env "$store1" --worktree "$wt1" --session-file "$tmp/absent.opencode-session")
case "$out" in
  *"session=ses_other "*"match=worktree"*) ;;
  *) fail "an unknown recorded id must fall back to the worktree match, got: $out" ;;
esac

# 4. The local config's limit.context supplies a window the catalog lacks.
store4="$tmp/store4"; mkdir -p "$store4"
wt4="$tmp/worktree-four"
cat > "$tmp/spec4.json" <<EOF
{"sessions":[
  {"id":"ses_qwen","directory":"$wt4","parent_id":null,"model":null,"time_updated":5000}
 ],
 "messages":[
  {"id":"m_qwen","session_id":"ses_qwen","time_created":1,
   "data":$(assistant 5000 195000 0 pc02-llamaswap qwen3.6-35b-a3b-dispatch)}
 ]}
EOF
make_db "$store4/opencode.db" "$tmp/spec4.json"
out=$(base_env "$store4" --worktree "$wt4")
case "$out" in
  *"context_tokens=200000 window=262144 "*) ;;
  *) fail "expected the config window override, got: $out" ;;
esac
case "$out" in
  *"band=warn "*) ;;
  *) fail "expected warn band at 200000/262144, got: $out" ;;
esac

# 5. An unknown window still reports tokens, with band=unknown and the reason.
store5="$tmp/store5"; mkdir -p "$store5"
wt5="$tmp/worktree-five"
cat > "$tmp/spec5.json" <<EOF
{"sessions":[
  {"id":"ses_mystery","directory":"$wt5","parent_id":null,"model":null,"time_updated":5000}
 ],
 "messages":[
  {"id":"m_mystery","session_id":"ses_mystery","time_created":1,
   "data":$(assistant 1000 1000 0 not-a-provider not-a-model)}
 ]}
EOF
make_db "$store5/opencode.db" "$tmp/spec5.json"
out=$(base_env "$store5" --worktree "$wt5")
case "$out" in
  *"context_tokens=2000 window=unknown percent=- "*) ;;
  *) fail "expected tokens with an unknown window, got: $out" ;;
esac
case "$out" in
  *" band=unknown "*" reason=unknown-window"*) ;;
  *) fail "expected band=unknown reason=unknown-window, got: $out" ;;
esac

# 6. No store, no session, and no usage are disclosed, never ok.
out=$(base_env "$tmp/store-missing" --worktree "$wt1")
case "$out" in
  *" band=unknown "*" reason=no-store"*) ;;
  *) fail "expected reason=no-store, got: $out" ;;
esac
out=$(base_env "$store1" --worktree "$tmp/worktree-absent")
case "$out" in
  *" band=unknown "*" reason=no-session"*) ;;
  *) fail "expected reason=no-session, got: $out" ;;
esac
store6="$tmp/store6"; mkdir -p "$store6"
cat > "$tmp/spec6.json" <<EOF
{"sessions":[
  {"id":"ses_user_only","directory":"$wt1","parent_id":null,"model":null,"time_updated":5000}
 ],
 "messages":[
  {"id":"m_user","session_id":"ses_user_only","time_created":1,"data":{"role":"user"}}
 ]}
EOF
make_db "$store6/opencode.db" "$tmp/spec6.json"
out=$(base_env "$store6" --worktree "$wt1")
case "$out" in
  *"context_tokens=unknown "*" band=unknown "*" reason=no-usage"*) ;;
  *) fail "expected reason=no-usage, got: $out" ;;
esac

# 7. config/context-thresholds under FM_HOME overrides the shared bands, and a
#    malformed file is rejected loudly.
cfg_home="$tmp/cfg_home"
store7="$tmp/store7"; mkdir -p "$store7"
make_db "$store7/opencode.db" "$tmp/spec1.json"
mkdir -p "$cfg_home/config"
printf 'warn=10000\nrestart=20000\n' > "$cfg_home/config/context-thresholds"
out=$(env FM_OPENCODE_STORE="$store7" FM_OPENCODE_MODELS="$catalog" \
  FM_OPENCODE_CONFIG="$tmp/opencode/opencode.jsonc" FM_HOME="$cfg_home" \
  "$bin" --worktree "$wt1")
case "$out" in
  *"warn_tokens=10000 restart_tokens=20000 band=restart "*) ;;
  *) fail "expected configured thresholds, got: $out" ;;
esac
printf 'warn=abc\n' > "$cfg_home/config/context-thresholds"
if env FM_OPENCODE_STORE="$store7" FM_OPENCODE_MODELS="$catalog" \
  FM_HOME="$cfg_home" "$bin" --worktree "$wt1" 2>"$tmp/err"; then
  fail "expected failure on malformed warn value"
fi
grep -q "malformed warn value" "$tmp/err" || fail "missing loud malformed-warn message"

# 8. A locked database is disclosed as band=unknown reason=locked, never ok.
store8="$tmp/store8"; mkdir -p "$store8"
make_db "$store8/opencode.db" "$tmp/spec1.json"
ready="$tmp/lock.ready"
python3 - "$store8/opencode.db" "$ready" <<'PY' &
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1])
con.execute("PRAGMA journal_mode=DELETE")
con.execute("BEGIN EXCLUSIVE")
open(sys.argv[2], "w").write("ready")
time.sleep(10)
PY
holder=$!
for _ in $(seq 1 50); do [ -s "$ready" ] && break; sleep 0.1; done
[ -s "$ready" ] || { kill "$holder" 2>/dev/null || true; fail "lock holder did not become ready"; }
out=$(env FM_OPENCODE_STORE="$store8" FM_OPENCODE_MODELS="$catalog" \
  FM_OPENCODE_BUSY_TIMEOUT=0 FM_HOME="$tmp/no_config_home" \
  "$bin" --worktree "$wt1")
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
case "$out" in
  *" band=unknown "*" reason=locked"*) ;;
  *) fail "expected reason=locked, got: $out" ;;
esac

echo '# all fm-opencode-context-usage tests passed'

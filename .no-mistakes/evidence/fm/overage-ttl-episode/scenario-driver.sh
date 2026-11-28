. /tmp/fm-ovg.2ycoyH/env.sh
W=$PWD
mode() { echo "$2" > $L/mode/tok-$1; }
meta() { # harness model account [kind]
  { printf 'window=sess:fm-t1\nkind=%s\nharness=%s\nmodel=%s\nproject=alpha\nmode=ship\n' "${4:-ship}" "$1" "$2"
    [ -z "$3" ] || printf 'account=%s\n' "$3"; } > $LAB/state/t1.meta; }
age() { touch -d "-$1 seconds" $LAB/state/t1.meta; }
send() { # label age
  age $2; rm -rf $LAB/state/t1.inbox; : > $L/srv/requests.log
  local t0=$(date +%s.%N) out rc
  out=$(bin/fm-send.sh t1 "ordinary steer" 2>&1); rc=$?
  printf -- '- %-62s idle=%-5s rc=%s queued=%s usage_reads=%s secs=%.1f %s\n' "$1" "$2" "$rc" \
    "$(ls $LAB/state/t1.inbox/*.msg 2>/dev/null | wc -l)" "$(grep -c /usage $L/srv/requests.log)" \
    "$(echo "$(date +%s.%N) - $t0" | bc)" "$(printf '%s' "$out" | grep -o 'idle [0-9]*s (> [0-9]*s prompt-cache TTL)')"
}
cfg() { cat $LAB/config/cache-ttl-seconds 2>/dev/null || echo '<absent>'; }
. /tmp/fm-ovg.2ycoyH/tools/drive.sh
A=$L/acct-a B=$L/acct-b
rm -f $LAB/config/*; mode b healthy
echo "## S1 episode and recovery, TTL file absent"
meta claude claude-opus-5-5 $A
mode a healthy;           send "healthy window" 600
mode a session-exhausted; send "5h window exhausted" 600
mode a weekly-exhausted;  send "weekly window exhausted" 600
mode a extra-usage;       send "weekly 100% with extra usage (overage) enabled" 600
                          send "exhausted, idle under cap" 200
echo "  cache-ttl-seconds during episode: $(cfg)"
mode a healthy;           send "recovered" 600
                          send "recovered, past default" 3700
echo "## S2 configured TTL 1200 restored; tighter/disabled untouched"
echo 1200 > $LAB/config/cache-ttl-seconds
mode a weekly-exhausted;  send "cfg 1200, exhausted" 600
mode a healthy;           send "cfg 1200, recovered" 600
                          send "cfg 1200, recovered, past 1200" 1300
echo "  cache-ttl-seconds after episode: $(cfg)"
mode a weekly-exhausted
echo 120 > $LAB/config/cache-ttl-seconds; send "cfg 120, exhausted (stays 120)" 200
echo 0 > $LAB/config/cache-ttl-seconds;   send "cfg 0, exhausted (stays disabled)" 5000
rm $LAB/config/cache-ttl-seconds
echo "## S3 quota read failures leave TTL unchanged"
for m in http500 badjson hang; do mode a $m; send "usage endpoint $m" 600; done
mode a http500; send "usage endpoint http500, past default" 3700
mv $A/.credentials.json $L/cred.bak; mode a weekly-exhausted; send "credential file missing" 600; mv $L/cred.bak $A/.credentials.json
HTTPS_PROXY=http://127.0.0.1:1 send "network unreachable" 600
echo "## S4 only affected targets"
mode a opus-exhausted
send "opus-only exhausted, model=claude-opus-5-5" 600
meta claude 'opus[1m]' $A;          send "opus-only exhausted, model=opus[1m]" 600
meta claude claude-sonnet-5-5 $A;   send "opus-only exhausted, model=sonnet" 600
mode a weekly-exhausted
meta codex gpt-5 $A;                send "account exhausted, codex target" 600
echo "## S5 target's account, not the home's"
printf '%s\n' $A > $LAB/config/claude-account
mode a weekly-exhausted; mode b healthy
meta claude default $B; send "home pin exhausted, target account healthy" 600
mode a healthy; mode b weekly-exhausted
meta claude default $B; send "home pin healthy, target account exhausted" 600
meta claude default ''; send "no account=, healthy home pin" 600
mode a weekly-exhausted; send "no account=, exhausted home pin" 600
mkdir -p $LAB/config/secondmate-accounts/t1; printf '%s\n' $B > $LAB/config/secondmate-accounts/t1/claude-account
mode b healthy; meta claude default '' secondmate; send "secondmate own pin healthy, home exhausted" 600
mode b weekly-exhausted; mode a healthy; send "secondmate own pin exhausted, home healthy" 600
rm -rf $LAB/config/secondmate-accounts
printf 'nonsense\n' > $LAB/config/claude-account; mode a weekly-exhausted
meta claude default ''; send "malformed home pin (no fallback)" 600
rm $LAB/config/claude-account
. /tmp/fm-ovg.2ycoyH/tools/drive.sh
A=$L/acct-a
rm -f $LAB/config/*; rm -rf $HOME/.cache
mkdir -p $HOME/.claude
sed 's/tok-a/tok-o/' $A/.credentials.json > $HOME/.claude/.credentials.json
echo "## S6 ambient login (no pin) and 'ordinary' pin; 60s reading reuse; ambient lane overrides ignored"
export QUOTA_AXI_SNAPSHOT=/dev/null QUOTA_AXI_CLAUDE_SWAP=1
mode a weekly-exhausted; mode o healthy
meta claude default ''; send "unpinned, ambient login exhausted" 600
mode a healthy;          send "unpinned, recovered <60s ago (reading reused)" 600
sleep_until=$(( $(date +%s) + 62 )); timeout 62 tail -f /dev/null
send "unpinned, recovered, after 62s" 600
printf 'ordinary\n' > $LAB/config/claude-account
mode a weekly-exhausted; send "ordinary pin: ambient exhausted, ~/.claude healthy" 600
mode a healthy; mode o weekly-exhausted; rm -rf $HOME/.cache
send "ordinary pin: ~/.claude exhausted, ambient healthy" 600
rm $LAB/config/claude-account
unset QUOTA_AXI_SNAPSHOT QUOTA_AXI_CLAUDE_SWAP

echo
echo "## S7 fm-returning-session-check (warn band)"
H=$L/mate-home; mkdir -p $H
slug=$(printf %s "$H" | sed 's/[^A-Za-z0-9]/-/g'); mkdir -p $A/projects/$slug
echo '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":180000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":5}}}' > $A/projects/$slug/s.jsonl
for spec in healthy:600 weekly-exhausted:600 weekly-exhausted:200 healthy:600 http500:600; do
  m=${spec%:*}; i=${spec#*:}; mode a $m; meta claude claude-opus-5-5 $A; age $i
  echo "[$m idle=$i] $(bin/fm-returning-session-check.sh $H $LAB/state t1 2>&1 | sed 's/ transcript=.*//')"
done

echo
echo "## S8 fm-fleet-snapshot cache_expiring"
snap() { : > $L/srv/requests.log; v=$(bin/fm-fleet-snapshot.sh --json 2>/dev/null | jq -c '.. | objects | select(.id? == "t1" and has("endpoint")) | {exists:.endpoint.exists, cache_expiring:.endpoint.cache_expiring}'); echo "[$1 idle=$2] $v usage_reads=$(grep -c /usage $L/srv/requests.log)"; }
for spec in healthy:270 weekly-exhausted:270 weekly-exhausted:100 weekly-exhausted:3100 healthy:3100 http500:270 healthy:270; do
  m=${spec%:*}; i=${spec#*:}; mode a $m; meta claude claude-opus-5-5 $A; age $i; snap $m $i
done
mode a weekly-exhausted; meta codex gpt-5 $A; age 270; snap "exhausted codex" 270
meta claude default $A; age 270; : > $L/srv/requests.log
bin/fm-fleet-snapshot.sh --help >/dev/null; echo "[--help] rc=$? usage_reads=$(grep -c /usage $L/srv/requests.log)"
echo "-- rendered fleet view, exhausted vs healthy, idle 270"
for m in weekly-exhausted healthy; do mode a $m; age 270; echo "[$m]"; bin/fm-fleet-view.sh 2>&1 | grep -iE 't1|cache|expir'; done

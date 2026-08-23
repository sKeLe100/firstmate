# shellcheck shell=bash
# Shared crew-dispatch config validity contract.
# Usage: . bin/fm-crew-dispatch-lib.sh
#
# config/crew-dispatch.json's validity rules (documented in
# docs/configuration.md) live here so every reader agrees on one verdict:
# bin/fm-bootstrap.sh's CREW_DISPATCH diagnostic and bin/fm-queue-snapshot.sh's
# dispatch_config field. A file that merely parses as JSON is NOT valid - a rule
# needs a non-empty `when`, `use`/`default` must be a non-empty profile object or
# array, every harness must be a verified adapter, and any effort must be one its
# harness supports.

# fm_crew_dispatch_validate <file>
#   0 - valid (or the file does not exist)
#   1 - invalid; the reason is echoed on stdout
#   2 - cannot be checked here (jq unavailable); nothing echoed
fm_crew_dispatch_validate() {
  local file=$1 err
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 2
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "malformed JSON"
    return 1
  fi
  err=$(jq -r '
    def verified($h): ["claude","codex","opencode","pi","pi-signed","grok","kimi","muse"] | index($h);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "pi" or $h == "pi-signed" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "muse" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" or $h == "kimi" then false
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)));
    def bad_efforts:
      configured_profiles
      | map({h: .harness, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model and effort must be non-empty strings when present"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model and effort must be non-empty strings when present"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "$err"
    return 1
  fi
  return 0
}

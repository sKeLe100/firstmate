#!/usr/bin/env bash
# tests/fm-raw-launch-lib.test.sh - unit tests for the quote-aware raw-launch
# reader (bin/fm-raw-launch-lib.sh). Pure function, no backend required.
#
# The reader promises to agree with bash on every line it accepts, so the
# acceptance half of this suite is DIFFERENTIAL: each literal line is parsed
# by fm_raw_launch_scan and, independently, by bash itself (eval "set -- ..."
# in a subshell with pathname expansion off), and the two word lists must be
# identical. Those lines carry no expansion characters, so the eval performs
# quote removal and word splitting only. The refusal half pins every input the
# reader must decline rather than guess at.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-raw-launch-lib.sh
. "$ROOT/bin/fm-raw-launch-lib.sh"

# bash_words <line>: bash's own parse of a literal line, NUL-joined. Only ever
# called on lines with no $, `, ~, glob or brace characters, so the eval can
# do nothing but quote removal and word splitting.
bash_words() {
  (
    set -f +H
    eval "set -- $1"
    printf '%s\0' "$@"
  )
}

scan_words() {  # <line>: the reader's parse, NUL-joined
  fm_raw_launch_scan "$1" || return 1
  printf '%s\0' "${FM_RAW_WORDS[@]}"
}

assert_agrees_with_bash() {  # <line> <label>
  local line=$1 label=$2 want got
  want=$(bash_words "$line" | od -An -c | tr -s ' \n' ' ')
  got=$(scan_words "$line" | od -An -c | tr -s ' \n' ' ') \
    || fail "$label: reader refused a line bash accepts: $FM_RAW_REFUSAL"
  [ "$want" = "$got" ] || fail "$label: reader and bash disagree on [$line]"$'\n'"bash:   $want"$'\n'"reader: $got"
}

assert_refused() {  # <line> <reason substring> <label>
  local line=$1 reason=$2 label=$3
  if fm_raw_launch_scan "$line"; then
    fail "$label: reader accepted [$line] (exe='${FM_RAW_WORDS[$FM_RAW_EXE_INDEX]}')"
  fi
  assert_contains "$FM_RAW_REFUSAL" "$reason" "$label: refusal did not name the cause"
}

assert_exe() {  # <line> <exe> <label>: accepted with that literal command word
  local line=$1 exe=$2 label=$3
  fm_raw_launch_scan "$line" || fail "$label: reader refused [$line]: $FM_RAW_REFUSAL"
  [ "${FM_RAW_WORDS[$FM_RAW_EXE_INDEX]}" = "$exe" ] \
    || fail "$label: command word is '${FM_RAW_WORDS[$FM_RAW_EXE_INDEX]}', expected '$exe' for [$line]"
}

test_accepted_lines_agree_with_bash() {
  local line
  # Every quoting spelling that defeated a previous reader, plus the plain
  # shapes, plus the double-quote backslash rules bash actually applies.
  while IFS= read -r line; do
    assert_agrees_with_bash "$line" "differential"
  done <<'LINES'
codex --dangerously-bypass-approvals-and-sandbox
RUST_LOG=debug codex --dangerously-bypass-approvals-and-sandbox
RUST_LOG="a b" codex --fast
FOO=bar\ baz codex --fast
FOO='bar baz' codex --fast
FOO='a b' BAR="c d" codex -c x="y z"
\codex \-\-fast
co"dex" --f'ast'
"codex" --fast
'codex' "--fast"
codex --fast=1
codex "a\"b" c\\d "e\fg" 'h\i'
codex ""'' "" --x
	codex	--tab	separated
  codex   --x
FOO+=bar codex --x
"FOO"=bar codex --x
codex a=b --c=d
/usr/local/bin/codex --x
LINES
  pass "the reader agrees with bash on every accepted literal line"
}

test_command_word_and_span_come_from_one_parse() {
  local line
  line='FOO=bar\ baz codex --fast'
  assert_exe "$line" codex "backslash-escaped whitespace in an env value"
  [ "$FM_RAW_EXE_INDEX" = 1 ] || fail "command word index is $FM_RAW_EXE_INDEX, expected 1"
  [ "${line:$FM_RAW_EXE_START:$((FM_RAW_EXE_END - FM_RAW_EXE_START))}" = codex ] \
    || fail "command word span does not cover the raw word: ${line:$FM_RAW_EXE_START:$((FM_RAW_EXE_END - FM_RAW_EXE_START))}"
  [ "${line:0:$FM_RAW_EXE_START}" = 'FOO=bar\ baz ' ] || fail "prefix span lost bytes: '${line:0:$FM_RAW_EXE_START}'"
  [ "${line:$FM_RAW_EXE_END}" = ' --fast' ] || fail "tail span lost bytes: '${line:$FM_RAW_EXE_END}'"
  [ "${FM_RAW_WORDS[2]}" = --fast ] || fail "the fast modifier was not read literally: '${FM_RAW_WORDS[2]}'"

  line='co"dex" --f'"'"'ast'"'"''
  assert_exe "$line" codex "split-quoted executable word"
  [ "${line:$FM_RAW_EXE_START:$((FM_RAW_EXE_END - FM_RAW_EXE_START))}" = 'co"dex"' ] \
    || fail "split-quoted span is wrong: ${line:$FM_RAW_EXE_START:$((FM_RAW_EXE_END - FM_RAW_EXE_START))}"
  [ "${FM_RAW_WORDS[1]}" = --fast ] || fail "split-quoted fast modifier was not read literally: '${FM_RAW_WORDS[1]}'"
  pass "command word, its raw span and every value come from the same pass"
}

test_prefix_assignment_expansions_never_move_the_command_word() {
  # shellcheck disable=SC2016  # unexpanded $HOME is the input under test
  assert_exe 'FOO=$HOME codex --x' codex "parameter expansion in an assignment value"
  assert_exe 'FOO=*.txt codex --x' codex "glob in an assignment value"
  assert_exe 'FOO=~/x codex --x' codex "tilde in an assignment value"
  [ "${FM_RAW_WORD_OPAQUE[0]}" = 1 ] || fail "an expanding assignment value must be marked opaque"
  [ "${FM_RAW_WORD_OPAQUE[1]}" = 0 ] || fail "a literal command word must not be marked opaque"
  pass "expansions inside a leading assignment leave the command word literal"
}

test_tail_expansions_are_marked_opaque_not_refused() {
  # shellcheck disable=SC2016  # unexpanded $MYARG is the input under test
  assert_exe 'some-tool --flag $MYARG' some-tool "parameter expansion after the command word"
  [ "${FM_RAW_WORD_OPAQUE[2]}" = 1 ] || fail "an expanding tail word must be marked opaque"
  [ "${FM_RAW_WORD_OPAQUE[1]}" = 0 ] || fail "a literal tail word must not be marked opaque"
  assert_exe 'some-tool *.txt' some-tool "glob after the command word"
  [ "${FM_RAW_WORD_OPAQUE[1]}" = 1 ] || fail "a glob tail word must be marked opaque"
  assert_exe 'some-tool {a,b}' some-tool "brace pattern after the command word"
  [ "${FM_RAW_WORD_OPAQUE[1]}" = 1 ] || fail "a brace tail word must be marked opaque"
  pass "expansions after the command word are reported opaque for the caller to judge"
}

# shellcheck disable=SC2016,SC2088  # unexpanded shell syntax is the input under test
test_unresolvable_command_words_are_refused() {
  assert_refused '$MYBIN --flag' "cannot be resolved without running it" "parameter expansion as the command word"
  assert_refused '~/bin/codex --x' "cannot be resolved without running it" "tilde in the command word"
  assert_refused 'cod* --x' "cannot be resolved without running it" "glob in the command word"
  assert_refused '{codex,other} --x' "cannot be resolved without running it" "brace pattern in the command word"
  assert_refused 'codex! --x' "cannot be resolved without running it" "history expansion in the command word"
  assert_refused "'' --x" "is empty" "empty command word"
  assert_refused 'FOO=bar' "no command word" "assignments only"
  assert_refused '' "no command word" "empty line"
  assert_refused '   ' "no command word" "blank line"
  pass "a command word only the pane could produce is refused"
}

# shellcheck disable=SC2016,SC1003  # unexpanded shell syntax is the input under test
test_second_commands_and_broken_lines_are_refused() {
  assert_refused 'true; codex --fast' "control operator" "semicolon"
  assert_refused 'true && codex --fast' "control operator" "and-list"
  assert_refused 'codex --x | tee log' "control operator" "pipe"
  assert_refused 'codex --x >log' "control operator or redirection" "redirection"
  assert_refused 'codex --x 2>&1' "control operator or redirection" "fd redirection"
  assert_refused '(codex --fast)' "control operator" "subshell"
  assert_refused 'some-tool $(codex --fast)' "command substitution" "command substitution"
  assert_refused 'some-tool "$(codex --fast)"' "command substitution" "quoted command substitution"
  assert_refused 'some-tool `codex --fast`' "command substitution" "backtick substitution"
  assert_refused 'some-tool "`codex --fast`"' "command substitution" "quoted backtick substitution"
  assert_refused 'codex --x # --fast' "starts a comment" "comment"
  assert_refused "'codex --x" "unterminated quote" "unterminated single quote"
  assert_refused 'codex "--x' "unterminated quote" "unterminated double quote"
  assert_refused 'codex --x\' "trailing backslash" "trailing backslash"
  assert_refused $'codex --x\ncodex --fast' "newline" "newline"
  assert_refused $'codex "a\nb"' "newline" "newline inside quotes"
  assert_refused 'codex "\$X"' "backslash-escaped" "escaped dollar inside double quotes"
  pass "anything that would run a second command or wait for more input is refused"
}

test_accepted_lines_agree_with_bash
test_command_word_and_span_come_from_one_parse
test_prefix_assignment_expansions_never_move_the_command_word
test_tail_expansions_are_marked_opaque_not_refused
test_unresolvable_command_words_are_refused
test_second_commands_and_broken_lines_are_refused

echo "# all fm-raw-launch-lib tests passed"

#!/usr/bin/env bash
# fm-raw-launch-lib.sh - the ONE owner of how a raw (hand-composed) launch
# command line is read before bin/fm-spawn.sh classifies its harness.
#
# Why this exists: the codex spawn guards (lane cap, executable rediscovery and
# pin, fast-modifier refusal) key off the launch's executable word, and the
# pane's shell decides that word with quote-aware lexing. Every earlier reader
# split the line on whitespace FIRST and stripped quotes from each piece AFTER,
# so any shell quoting that hid whitespace before the executable (FOO="a b",
# FOO=bar\ baz) or split the executable itself (co"dex", \codex) moved the word
# boundaries and the guards silently never fired. fm_raw_launch_scan reads the
# line ONCE, character by character, with the shell's own lexical rules, so
# token boundaries and token values come from the same pass and cannot
# disagree. Nothing is executed or expanded.
#
# Accepted grammar - exactly the subset where this reader and bash provably
# agree - and the fail-closed rule for everything else:
#   - Blanks and tabs separate words outside quotes.
#   - '...' is literal; "..." is literal except that \ escapes \ and " (and $
#     and `, which are refused anyway); an unquoted \ makes the next character
#     literal. Adjacent quoted and unquoted pieces join into one word, and an
#     empty quoted string is an empty word, exactly as in bash.
#   - Leading NAME=value / NAME+=value words (NAME unquoted, as bash requires)
#     are environment assignments and are skipped to reach the command word.
#     Their values may carry $, ~, globs or braces: bash expands those in
#     place and never lets them move the command word, so they are accepted
#     and left verbatim.
#   - The COMMAND word must be literal. A word whose value only the pane can
#     produce - a parameter expansion, tilde, glob character, brace pattern,
#     or history-expansion ! - is refused, and so is an empty command word.
#   - Words AFTER the command word may carry those expansions; each is marked
#     opaque (FM_RAW_WORD_OPAQUE=1) and the caller decides whether that harness
#     tolerates an unverifiable argument. Its literal value is reported with
#     the expansion characters kept verbatim.
#   - REFUSED outright, wherever they appear and however quoted: a command
#     substitution ($( or `), a newline. Refused when unquoted: a control
#     operator or redirection (; | & ( ) < >), a # that starts a word, an
#     unterminated quote, and a trailing backslash. A raw launch is ONE simple
#     command; anything that would make the pane run a second command, or
#     leave it waiting for more input, has no classification.
#
# Contract of fm_raw_launch_scan <line>:
#   returns 0 and sets
#     FM_RAW_WORDS        every word's literal value, in order
#     FM_RAW_WORD_OPAQUE  1 iff that word's value depends on a pane-side expansion
#     FM_RAW_EXE_INDEX    index of the command word in FM_RAW_WORDS
#     FM_RAW_EXE_START    byte offset where the command word's raw span starts
#     FM_RAW_EXE_END      byte offset just past that raw span
#   returns 1 and sets FM_RAW_REFUSAL to the concrete reason otherwise.
# The caller rebuilds a pinned launch as
#   ${line:0:FM_RAW_EXE_START}<pinned executable>${line:FM_RAW_EXE_END}
# so every byte before and after the command word is preserved verbatim.
#
# tests/fm-raw-launch-lib.test.sh pins this reader against bash's own parse of
# every accepted literal line (eval "set -- ..." under set -f, with no
# expansion characters present), plus the refusal list above.

fm_raw_launch__refuse() {  # <reason>: records the refusal, always returns 1
  # shellcheck disable=SC2034  # read by the sourcing caller
  FM_RAW_REFUSAL=$1
  return 1
}

fm_raw_launch_scan() {  # <line>: 0 = accepted, globals filled; 1 = refused, FM_RAW_REFUSAL set
  local line=$1
  local n=${#line} i=0 c next state=plain
  local word='' start=-1 in_word=0 opaque=0 glob=0 raw
  local assign_re='^[A-Za-z_][A-Za-z0-9_]*\+?='
  # shellcheck disable=SC2034  # the FM_RAW_* results are read by the sourcing caller
  FM_RAW_WORDS=()
  FM_RAW_WORD_OPAQUE=()
  FM_RAW_EXE_INDEX=-1
  FM_RAW_EXE_START=-1
  FM_RAW_EXE_END=-1
  # shellcheck disable=SC2034
  FM_RAW_REFUSAL=''
  while [ "$i" -le "$n" ]; do
    if [ "$i" -eq "$n" ]; then
      # Virtual terminator: ends a final word, or exposes an open quote.
      [ "$state" = plain ] || fm_raw_launch__refuse "unterminated quote" || return 1
      c=' '
    else
      c=${line:i:1}
    fi
    case "$state" in
      plain)
        case "$c" in
          ' '|$'\t')
            if [ "$in_word" -eq 1 ]; then
              raw=${line:start:i-start}
              if [ "$FM_RAW_EXE_INDEX" -lt 0 ] && [[ $raw =~ $assign_re ]]; then
                # Environment assignment ahead of the command word: expansions
                # in its value stay inside this word in bash, so they cannot
                # move the executable. Globs are literal in an assignment.
                FM_RAW_WORDS+=("$word")
                FM_RAW_WORD_OPAQUE+=("$opaque")
              elif [ "$FM_RAW_EXE_INDEX" -lt 0 ]; then
                if [ "$opaque" -eq 1 ] || [ "$glob" -eq 1 ]; then
                  fm_raw_launch__refuse "executable word '$raw' cannot be resolved without running it (a shell expansion, tilde, glob or brace pattern only the pane can evaluate)" || return 1
                fi
                [ -n "$word" ] || fm_raw_launch__refuse "executable word '$raw' is empty" || return 1
                FM_RAW_EXE_INDEX=${#FM_RAW_WORDS[@]}
                # shellcheck disable=SC2034  # read by the caller to rebuild a pinned launch
                FM_RAW_EXE_START=$start
                # shellcheck disable=SC2034
                FM_RAW_EXE_END=$i
                FM_RAW_WORDS+=("$word")
                FM_RAW_WORD_OPAQUE+=(0)
              else
                FM_RAW_WORDS+=("$word")
                if [ "$opaque" -eq 1 ] || [ "$glob" -eq 1 ]; then
                  FM_RAW_WORD_OPAQUE+=(1)
                else
                  FM_RAW_WORD_OPAQUE+=(0)
                fi
              fi
              word=''
              start=-1
              in_word=0
              opaque=0
              glob=0
            fi
            i=$((i + 1))
            continue
            ;;
          $'\n') fm_raw_launch__refuse "newline in the command line" || return 1 ;;
          "'") state=single ;;
          '"') state=double ;;
          \\)
            [ "$((i + 1))" -lt "$n" ] || fm_raw_launch__refuse "trailing backslash" || return 1
            next=${line:i+1:1}
            [ "$next" != $'\n' ] || fm_raw_launch__refuse "newline in the command line" || return 1
            word="$word$next"
            [ "$start" -ge 0 ] || start=$i
            in_word=1
            i=$((i + 2))
            continue
            ;;
          '$')
            next=${line:i+1:1}
            [ "$next" != '(' ] || fm_raw_launch__refuse "command substitution" || return 1
            opaque=1
            word="$word$c"
            ;;
          '`') fm_raw_launch__refuse "command substitution" || return 1 ;;
          ';'|'|'|'&'|'('|')'|'<'|'>')
            fm_raw_launch__refuse "unquoted control operator or redirection '$c'" || return 1
            ;;
          '#')
            [ "$in_word" -eq 1 ] || fm_raw_launch__refuse "unquoted # starts a comment" || return 1
            word="$word$c"
            ;;
          '~'|'{'|'!')
            # Tilde, brace, or history expansion: the pane decides the value.
            opaque=1
            word="$word$c"
            ;;
          '*'|'?'|'[')
            glob=1
            word="$word$c"
            ;;
          *) word="$word$c" ;;
        esac
        [ "$start" -ge 0 ] || start=$i
        in_word=1
        ;;
      single)
        case "$c" in
          "'") state=plain ;;
          $'\n') fm_raw_launch__refuse "newline in the command line" || return 1 ;;
          *) word="$word$c" ;;
        esac
        ;;
      double)
        case "$c" in
          '"') state=plain ;;
          $'\n') fm_raw_launch__refuse "newline in the command line" || return 1 ;;
          \\)
            next=${line:i+1:1}
            case "$next" in
              '"'|\\)
                word="$word$next"
                i=$((i + 2))
                continue
                ;;
              '$'|'`')
                # \$ and \` are literal in bash, but a $ or ` this close to a
                # quoted expansion is where readers and panes have disagreed;
                # refusing keeps the literal-only promise simple to audit.
                fm_raw_launch__refuse "backslash-escaped $next inside double quotes" || return 1
                ;;
              $'\n') fm_raw_launch__refuse "newline in the command line" || return 1 ;;
              *) word="$word$c" ;;  # bash keeps the backslash before any other character
            esac
            ;;
          '$')
            next=${line:i+1:1}
            [ "$next" != '(' ] || fm_raw_launch__refuse "command substitution" || return 1
            opaque=1
            word="$word$c"
            ;;
          '`') fm_raw_launch__refuse "command substitution" || return 1 ;;
          '!')
            opaque=1
            word="$word$c"
            ;;
          *) word="$word$c" ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
  [ "$FM_RAW_EXE_INDEX" -ge 0 ] || fm_raw_launch__refuse "no command word (only environment assignments, or nothing at all)" || return 1
  return 0
}

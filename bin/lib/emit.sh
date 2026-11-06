#!/usr/bin/env bash
# Presentation: colors, die/log, the JSON emitters shared by diagnose.

# color_init [args...]: scan the option list once, before any output. Called
# from main with the command's arguments; a sourced bin/homefield (tests) calls
# it through the emitters below, so the level of a marker never depends on
# where in main it was set.
color_init() {
  HF_ANSI_OFF=1
  local mode="" arg
  for arg in "$@"; do
    case "$arg" in
      --color=*) mode="${arg#--color=}" ;;
    esac
  done
  case "${mode:-${HOMEFIELD_COLOR:-auto}}" in
    never) HF_ANSI_OFF=1 ;;
    always)
      case "${NO_COLOR:-}" in "") HF_ANSI_OFF=0 ;; *) HF_ANSI_OFF=1 ;; esac
      ;;
    auto|*)
      # A terminal on stdout is the one case auto colors; stderr emitters
      # (die, adopt_warn) follow stdout's decision, so a run is all-or-nothing.
      if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then HF_ANSI_OFF=0; else HF_ANSI_OFF=1; fi
      ;;
  esac
}

# hf_color <code>: prints the ANSI SGR for <code> (1=green,2=yellow,3=red,
# 0=reset) or nothing when colors are off. The escapes are spelled with
# printf's \033 so no literal control bytes land in the source.
hf_color() {
  if [ "$HF_ANSI_OFF" = 0 ]; then
    case "$1" in
      1) printf '\033[32m' ;;
      2) printf '\033[33m' ;;
      3) printf '\033[31m' ;;
      0) printf '\033[0m' ;;
    esac
  fi
}

die() {
  echo "homefield: $(color_wrap 3 "$*")" >&2
  exit 1
}

pf_add() {
  PF_NAME+=("$1")
  PF_LEVEL+=("$2")
  PF_MSG+=("$3")
}

# pf_render_row <prefix> <index>: one prerequisite row — the level word in its
# color, the message. The prefix is "" for preflight's rows, "- " for
# diagnose's list. One rendering, so the two commands cannot disagree about
# what a level looks like.
pf_render_row() {
  local prefix="$1" i="$2" level level_color
  case "${PF_LEVEL[i]}" in
    ok) level=OK; level_color=1 ;;
    warn) level=WARN; level_color=2 ;;
    *) level=FAIL; level_color=3 ;;
  esac
  printf '  %s%s%-6s%s%s\n' "$prefix" "$(hf_color "$level_color")" "$level" "$(hf_color 0)" "${PF_MSG[i]}"
}

# json_str <text>: <text> as a JSON string literal. Plain bash: a stock Mac has
# no jq, and its python3 may be only a stub. Escapes the quote, the backslash
# and every control character; the rest, UTF-8 included, passes through.
json_str() {
  local s="$1" out="" c i n code
  case "$s" in
    *[\"\\[:cntrl:]]*) ;;
    *) printf '"%s"' "$s"; return 0 ;;
  esac
  n=${#s}
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    case "$c" in
      '"') out="$out\\\"" ;;
      \\) out="$out\\\\" ;;
      $'\n') out="$out\\n" ;;
      $'\r') out="$out\\r" ;;
      $'\t') out="$out\\t" ;;
      [[:cntrl:]]) printf -v code '\\u%04x' "'$c"; out="$out$code" ;;
      *) out="$out$c" ;;
    esac
  done
  printf '"%s"' "$out"
}

# json_bool <yes|no|true|false>: true or false; null for anything else.
json_bool() {
  case "$1" in
    yes | true) printf true ;;
    no | false) printf false ;;
    *) printf null ;;
  esac
}

# json_words <text>: the words of <text> as a JSON array of strings.
json_words() {
  local words=() i first=1
  read -ra words <<<"$1"
  printf '['
  for ((i = 0; i < ${#words[@]}; i++)); do
    [ "$first" = 1 ] || printf ', '
    first=0
    json_str "${words[i]}"
  done
  printf ']'
}

# json_lines <text>: the lines of <text> as a JSON array of strings.
json_lines() {
  local line first=1
  printf '['
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$first" = 1 ] || printf ', '
    first=0
    json_str "$line"
  done <<<"$1"
  printf ']'
}

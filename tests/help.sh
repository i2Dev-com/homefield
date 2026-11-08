#!/usr/bin/env bash
# tests/help.sh — the help surfaces: `--help`, `help`, `help <command>` and
# `<command> --help`.
#
# The full text (`homefield help`) is the reference every piece was split from;
# the short overview (`--help`, no command) is the concise one. Each surface is
# checked for what it must and must not contain, and `<command> --help` must
# print exactly what `help <command>` prints, so the two cannot drift.
#
# Run:  bash tests/help.sh
# Exit: 0 when every case passes, 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

HF="$ROOT/bin/homefield"

out="$(env -i HOME="$HOME" PATH="$PATH" "$HF" --help 2>&1 </dev/null)"; rc=$?
record "--help: exits 0" "0" "$rc"
record "--help: names the usage line" "yes" "$(has "$out" 'Usage: bin/homefield <command> [options]')"
record "--help: one line per command" "yes/yes" "$(has "$out" '  install    Create the VM')/$(has "$out" '  version    Show the installed version')"
record "--help: names the per-command help and the full reference" "yes/yes" "$(has "$out" 'help <command>')/$(has "$out" 'bin/homefield
help` for the full reference')"
record "--help: names the guides" "yes/yes" "$(has "$out" 'getting-started.md')/$(has "$out" 'cli.md')"
record "--help: no option sections (they live in the full text)" "no" "$(has "$out" '--group-exists')"

out="$(env -i HOME="$HOME" PATH="$PATH" "$HF" help 2>&1 </dev/null)"; rc=$?
record "help: exits 0" "0" "$rc"
record "help: the full reference" "yes/yes" "$(has "$out" 'Usage: bin/homefield')/$(has "$out" 'install (and setup, which takes the same options):')"
record "help: the diagnose section with --json" "yes/yes" "$(has "$out" '  diagnose   One read-only report')/$(has "$out" 'diagnose:
  --json')"
record "help: the adopt section" "yes" "$(has "$out" '  --wait             with --setup:')"

for cmd in setup install upgrade status start stop diagnose uninstall reset route preflight adopt memory report version; do
  out="$(env -i HOME="$HOME" PATH="$PATH" "$HF" help "$cmd" 2>&1 </dev/null)"; rc=$?
  record "help $cmd: exits 0" "0" "$rc"
  out2="$(env -i HOME="$HOME" PATH="$PATH" "$HF" "$cmd" --help 2>&1 </dev/null)"; rc2=$?
  record "$cmd --help: exits 0 and equals help $cmd" "0/yes" "$rc2/$( [ "$out" = "$out2" ] && echo yes || echo no )"
  other='  version    Show the installed version'
  [ "$cmd" = version ] && other='  install    Create the VM'
  record "help $cmd: its own paragraph, not other commands'" "yes/no" "$(has "$out" "  $cmd  ")/$(has "$out" "$other")"
done

out="$(env -i HOME="$HOME" PATH="$PATH" "$HF" help install 2>&1 </dev/null)"
record "help install: install's options" "yes/yes" "$(has "$out" '--url URL')/$(has "$out" '--group-exists')"
record "help install: the token paragraph" "yes" "$(has "$out" 'Registration and removal need a one-hour token')"
record "help install: not adopt's options" "no" "$(has "$out" '--wait-timeout')"

out="$(env -i HOME="$HOME" PATH="$PATH" "$HF" help setup 2>&1 </dev/null)"
record "help setup: install's options (setup takes them)" "yes/yes" "$(has "$out" '--url URL')/$(has "$out" 'Takes install')"

out="$(env -i HOME="$HOME" PATH="$PATH" "$HF" help status 2>&1 </dev/null)"
record "help status: the global --instance note" "yes" "$(has "$out" '--instance NAME')"
record "help status: its --json section" "yes" "$(has "$out" 'status:
  --json')"
record "help status: no install section" "no" "$(has "$out" '--group-exists')"

out="$(env -i HOME="$HOME" PATH="$PATH" "$HF" help bogus 2>&1 </dev/null)"; rc=$?
record "help bogus: refuses, naming it" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" "unknown command 'bogus'")"

out="$(env -i HOME="$HOME" PATH="$PATH" "$HF" 2>&1 </dev/null)"; rc=$?
record "no command: the short overview on a failure" "nonzero/yes/no" "$(nonzero "$rc")/$(has "$out" 'Usage: bin/homefield')/$(has "$out" '--group-exists')"

out="$(env -i HOME="$HOME" PATH="$PATH" "$HF" frobnicate 2>&1 </dev/null)"; rc=$?
record "unknown command: the short overview" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'Usage: bin/homefield')"

out="$(env -i HOME="$HOME" PATH="$PATH" "$HF" -h 2>&1 </dev/null)"; rc=$?
record "-h: the short overview, exit 0" "0/yes" "$rc/$(has "$out" 'Usage: bin/homefield')"

summary
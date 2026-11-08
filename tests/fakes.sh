#!/usr/bin/env bash
# Shared fake commands for the suites. A suite supplies only the handler body;
# this writes the executable, its shebang, the invocation log line and chmod,
# so every stub records the same way and cannot forget to log a call.
#
# fake_stub <dir> <name> [log-var] [interpreter] < body
#   Writes <dir>/<name> that appends "<name> <args>" to the file named by the
#   log variable (default CALLS), then runs the body supplied on stdin. Pass
#   the body as a heredoc, without a shebang or the log line:
#
#     fake_stub "$stubs" gh CALLS <<'EOF'
#     case "$*" in
#       *repos/*/tags*) printf '%s\n' "$TAGS" ;;
#     esac
#     EOF
#
#   interpreter defaults to sh. Pass bash only when the suite's PATH has bash:
#   many suites run under `env -i` with a stub-only PATH, where `/usr/bin/env
#   bash` cannot resolve.
fake_stub() {
  local dir="$1" name="$2" logvar="${3:-CALLS}" interp="${4:-sh}" file shebang="#!/bin/sh"
  [ "$interp" = bash ] && shebang="#!/usr/bin/env bash"
  mkdir -p "$dir"
  file="$dir/$name"
  {
    printf '%s\n' "$shebang"
    # shellcheck disable=SC2016  # this line is written into the stub literally
    printf 'echo "%s $*" >>"${%s:?fake_stub needs %s}"\n' "$name" "$logvar" "$logvar"
    cat
  } >"$file"
  chmod +x "$file"
}

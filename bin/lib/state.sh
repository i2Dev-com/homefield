#!/usr/bin/env bash
# The per-VM state file and the installed-tool wrapper helpers.

# state_get <key>: its value, or nothing. The key goes to awk as data (-v),
# not into a sed program: only the fixed group_created key made the sed safe.
state_get() {
  local f
  f="$(state_file)"
  [ -f "$f" ] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$f"
}

# state_set <key> <value>: written to a temp file next to the state file and
# moved over it, so a reader never sees half a file; other keys are kept.
state_set() {
  local f dir tmp
  f="$(state_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.${INSTANCE}.state.XXXXXX")" || return 1
  {
    [ ! -f "$f" ] || awk -v k="$1" 'index($0, k "=") != 1' "$f"
    printf '%s=%s\n' "$1" "$2"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# tool_bin_dirs: every place the command can be; the Homebrew prefix install.sh
# found then may not be the one found now.
tool_bin_dirs() {
  local prefix
  if [ -n "${HOMEFIELD_BIN_DIR:-}" ]; then
    printf '%s\n' "$HOMEFIELD_BIN_DIR"
    return 0
  fi
  if command -v brew >/dev/null 2>&1 && prefix="$(brew --prefix 2>/dev/null)" && [ -n "$prefix" ]; then
    printf '%s\n' "$prefix/bin"
  fi
  printf '%s\n' "$HOME/.local/bin"
}

# tool_wrappers: the `homefield` commands that run this install dir, one per
# line. install.sh's write_wrapper only replaces a regular file whose last line
# runs <dir>/bin/homefield; this also needs the line to name the install dir
# being removed, so another installation's command is left alone.
tool_wrappers() {
  local install_dir dir
  install_dir="$(tool_install_dir)"
  while IFS= read -r dir; do
    if [ -f "$dir/homefield" ] && [ ! -L "$dir/homefield" ] &&
      grep -qxF "exec \"${install_dir}/bin/homefield\" \"\$@\"" "$dir/homefield"; then
      printf '%s\n' "$dir/homefield"
    fi
  done < <(tool_bin_dirs)
  return 0
}

# tool_dir: the install dir, if install.sh put it there (it writes
# .homefield-ref; a git checkout has none) and it is a path install.sh would
# have accepted. Nothing otherwise.
tool_dir() {
  local dir dir_re='^/[A-Za-z0-9_./@+ -]+$'
  dir="$(tool_install_dir)"
  if [[ "$dir" =~ $dir_re && "$dir" != *..* && "$dir" != "$HOME" ]] &&
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/.homefield-ref" ]; then
    printf '%s\n' "$dir"
  fi
  return 0
}

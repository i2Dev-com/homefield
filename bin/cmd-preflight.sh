#!/usr/bin/env bash
# The preflight command: what this Mac needs before a VM can be set up.

# preflight_collect: everything an install needs, checked one by one instead of
# stopping at the first failure like check_host, into PF_NAME / PF_LEVEL /
# PF_MSG (parallel arrays, in the order preflight prints them). PF_LEVEL is ok,
# warn or fail, and a failure's message carries the command that fixes it.
# cmd_preflight prints the arrays; diagnose reads them, so the two cannot
# disagree about what a prerequisite is.
# gh is not strictly needed: without it, install asks for a pasted token, so
# gh missing is a failure to fix, gh logged out is a failure too, and a token
# without admin:org only warns (an organization URL is what needs that scope,
# a repository URL is registered with repo; `gh auth refresh -s admin:org`).
# gh >= 2.32 is the version floor: `gh auth status --json hosts` (the account
# check below, via gh_active_account) and `gh api --jq` (the registration
# token) need it; an older gh fails here with the upgrade command, not
# mid-setup with an opaque API error.
# Lima >= 2.3 is the same check as check_host's.
PF_NAME=()
PF_LEVEL=()
PF_MSG=()

preflight_collect() {
  local login scopes whoami py_version
  PF_NAME=()
  PF_LEVEL=()
  # PF_MSG is read by lib/emit.sh's pf_render_row
  # shellcheck disable=SC2034
  PF_MSG=()
  # Lima
  if ! command -v limactl >/dev/null 2>&1; then
    pf_add lima fail "Lima not found: run 'brew install lima'"
  else
    lima_major_minor
    if [ -z "$LIMA_MAJOR" ] || ! { [ "$LIMA_MAJOR" -gt 2 ] || { [ "$LIMA_MAJOR" -eq 2 ] && [ "$LIMA_MINOR" -ge 3 ]; }; }; then
      pf_add lima fail "Lima >= 2.3 required, found ${LIMA_VERSION:-unknown}: run 'brew install lima'"
    else
      pf_add lima ok "Lima $LIMA_VERSION"
    fi
  fi
  # gh: the active account, by login and scopes. App-installed tokens report no
  # scopes; the `Token scopes` line of `gh auth status` is absent for them, and
  # `gh auth status` also lists accounts that are not active.
  if ! command -v gh >/dev/null 2>&1; then
    pf_add gh fail "gh (GitHub CLI) not found: run 'brew install gh'"
  elif ! gh_at_least "$GH_MIN_MAJOR" "$GH_MIN_MINOR"; then
    pf_add gh fail "gh >= ${GH_MIN_MAJOR}.${GH_MIN_MINOR} required (auth status --json, api --jq), found ${GH_MAJOR:-unknown}.${GH_MINOR:-unknown}: run 'brew upgrade gh'"
  else
    whoami="$(gh_active_account)" || whoami="|"
    login="${whoami%%|*}"
    scopes="${whoami#*|}"
    # GitHub reports scopes comma-space separated ("repo, admin:org"); the
    # spaces come off here, so the `,scope,` match works whichever order they
    # come back in (gh_active_account strips them too; an override in a test
    # may not).
    scopes="${scopes// /}"
    if [ -z "$login" ]; then
      pf_add gh fail "gh not logged in: run 'gh auth login'"
    elif [ -z "$scopes" ]; then
      pf_add gh ok "gh authenticated as $login (no scope reported; an organization URL needs admin:org)"
    elif case ",$scopes," in *,admin:org,*) true ;; *) false ;; esac; then
      pf_add gh ok "gh authenticated as $login (admin:org scope)"
    else
      pf_add gh warn "gh authenticated as $login, no admin:org scope (an organization URL needs it: gh auth refresh -s admin:org)"
    fi
  fi
  # python3: resolving on PATH is not enough — a broken shim prints but exits
  # non-zero, so the version command's own status decides.
  if ! command -v python3 >/dev/null 2>&1; then
    pf_add python3 fail "python3 not found: run 'brew install python'"
  elif py_version="$(python3 --version 2>&1)"; then
    pf_add python3 ok "python3 ($py_version)"
  else
    pf_add python3 fail "python3 cannot run (${py_version:-no output}): reinstall it, e.g. run 'brew install python'"
  fi
  # brew
  if command -v brew >/dev/null 2>&1; then
    pf_add brew ok "brew available"
  else
    pf_add brew fail "brew not found: install Homebrew from https://brew.sh"
  fi
  # macOS (Darwin), by product version rather than kernel release
  if [ "$(uname -s)" = "Darwin" ]; then
    pf_add macos ok "macOS $(sw_vers -productVersion)"
  else
    pf_add macos fail "needs macOS (Darwin): found $(uname -s)"
  fi
  # Apple Silicon
  if [ "$(uname -m)" = "arm64" ]; then
    pf_add arm64 ok "arm64 (Apple Silicon)"
  else
    pf_add arm64 fail "needs Apple Silicon (arm64): found $(uname -m)"
  fi
}

# pf_line <ok|warn|fail> <message>: render one status row outside preflight_collect.
pf_line() {
  local level_kind="$1" msg="$2" level level_color
  case "$level_kind" in
    ok) level=OK; level_color=1 ;;
    warn) level=WARN; level_color=2 ;;
    *) level=FAIL; level_color=3 ;;
  esac
  printf '  %s%-6s%s%s\n' "$(hf_color "$level_color")" "$level" "$(hf_color 0)" "$msg"
}

# pf_sha256_cmd: print the sha256 command to use on this host. Falls back to
# standard OS paths so minimal-PATH test suites still verify real digests.
pf_sha256_cmd() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "shasum -a 256"
  elif [ -x /usr/bin/shasum ]; then
    printf '%s' "/usr/bin/shasum -a 256"
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "sha256sum"
  elif [ -x /usr/bin/sha256sum ]; then
    printf '%s' "/usr/bin/sha256sum"
  elif [ -x /bin/sha256sum ]; then
    printf '%s' "/bin/sha256sum"
  else
    return 1
  fi
}

pf_sha256_str() {
  local cmd out
  cmd="$(pf_sha256_cmd)" || return 1
  # shellcheck disable=SC2086  # pf_sha256_cmd returns command and optional -a 256
  out="$(printf '%s' "$1" | $cmd 2>/dev/null)" || return 1
  out="${out%%[[:space:]]*}"
  [ "${#out}" -eq 64 ] || return 1
  printf '%s' "$out" | awk '{print tolower($0)}'
}

pf_sha256_file() {
  local cmd out
  cmd="$(pf_sha256_cmd)" || return 1
  # shellcheck disable=SC2086  # pf_sha256_cmd returns command and optional -a 256
  out="$($cmd "$1" 2>/dev/null)" || return 1
  out="${out%%[[:space:]]*}"
  [ "${#out}" -eq 64 ] || return 1
  printf '%s' "$out" | awk '{print tolower($0)}'
}

# preflight_resolve_image: print `<url>|<sha256_hex>` for vm/lima.yaml's arch
# and non-minimal base image, using HOMEFIELD_LIMA_TEMPLATE when set or
# `limactl info` to locate Lima's template file.
preflight_resolve_image() {
  # shellcheck disable=SC2153  # LIMA_YAML is defined in bin/homefield
  local lima_yaml="${LIMA_YAML:?}" base arch tpl_name tpl_file
  [ -f "$lima_yaml" ] || return 1
  base="$(awk -v key="base" -v q="'" '
    $0 ~ "^" key ":" {
      v = $0; sub("^[^:]+:[[:space:]]*", "", v)
      sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v)
      if ((substr(v,1,1)=="\"" && substr(v,length(v),1)=="\"") ||
          (substr(v,1,1)==q && substr(v,length(v),1)==q))
        v = substr(v, 2, length(v)-2)
      print v; exit
    }
  ' "$lima_yaml")" || return 1
  arch="$(awk -v key="arch" -v q="'" '
    $0 ~ "^" key ":" {
      v = $0; sub("^[^:]+:[[:space:]]*", "", v)
      sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v)
      if ((substr(v,1,1)=="\"" && substr(v,length(v),1)=="\"") ||
          (substr(v,1,1)==q && substr(v,length(v),1)==q))
        v = substr(v, 2, length(v)-2)
      print v; exit
    }
  ' "$lima_yaml")" || return 1
  [ -n "$base" ] && [ -n "$arch" ] || return 1
  tpl_name="${base#template:}"
  if [ -n "${HOMEFIELD_LIMA_TEMPLATE:-}" ]; then
    tpl_file="$HOMEFIELD_LIMA_TEMPLATE"
  else
    tpl_file="$(limactl info 2>/dev/null | awk -v target="$tpl_name" '
      BEGIN { RS = "{" }
      index($0, "\"" target "\"") && index($0, "\"location\"") {
        s = $0
        sub(/^.*"location"[[:space:]]*:[[:space:]]*"/, "", s)
        sub(/".*$/, "", s)
        print s
        exit
      }
    ')" || tpl_file=""
  fi
  [ -n "$tpl_file" ] && [ -f "$tpl_file" ] || return 1
  awk -v want_arch="$arch" -v q="'" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+#.*$/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function unq(s) {
      s = trim(s)
      if ((substr(s,1,1)=="\"" && substr(s,length(s),1)=="\"") ||
          (substr(s,1,1)==q && substr(s,length(s),1)==q))
        s = substr(s, 2, length(s)-2)
      return s
    }
    function check() {
      if (loc != "" && img_arch == want_arch && var != "minimal" &&
          dig ~ /^sha256:[0-9a-fA-F]{64}$/) {
        print loc "|" tolower(substr(dig, 8))
        found = 1
        exit 0
      }
    }
    /^images:/ { in_img = 1; next }
    !in_img { next }
    /^[^[:space:]#-]/ { check(); exit 0 }
    /^[[:space:]]*-[[:space:]]+/ {
      check()
      loc = ""; img_arch = ""; dig = ""; var = ""
      line = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", line)
      k = line; sub(/:.*/, "", k); k = trim(k)
      v = line; sub(/^[^:]+:[[:space:]]*/, "", v); v = unq(v)
      if (k == "location") loc = v
      else if (k == "arch") img_arch = v
      else if (k == "digest") dig = v
      else if (k == "variant") var = v
      next
    }
    /^[[:space:]]+[A-Za-z0-9_-]+:/ {
      line = $0
      k = line; sub(/:.*/, "", k); k = trim(k)
      v = line; sub(/^[^:]+:[[:space:]]*/, "", v); v = unq(v)
      if (k == "location") loc = v
      else if (k == "arch") img_arch = v
      else if (k == "digest") dig = v
      else if (k == "variant") var = v
    }
    END { if (!found) check() }
  ' "$tpl_file"
}

# preflight_image: check Lima's download cache for vm/lima.yaml's pinned image
# and pre-fetch (digest-verified) when absent or stale. Failures warn rather than
# failing preflight: `install` will fetch via Lima as before.
preflight_image() {
  local resolved url digest_hex url_hash cache_root cache_dir cached_sha part_sha name
  local lock_dir lock_pid attempts=0 missing_pid=0 max_attempts="${HOMEFIELD_PREFETCH_LOCK_TRIES:-300}" part_file
  if ! resolved="$(preflight_resolve_image)" || [ -z "$resolved" ]; then
    pf_line warn "VM image pre-fetch skipped (could not resolve Lima image template); install will download it"
    return 0
  fi
  url="${resolved%|*}"
  digest_hex="${resolved#*|}"
  name="${url##*/}"
  if ! url_hash="$(pf_sha256_str "$url")" || [ -z "$url_hash" ]; then
    pf_line warn "VM image pre-fetch skipped (no sha256 tool found); install will download it"
    return 0
  fi
  cache_root="${HOMEFIELD_LIMA_CACHE_DIR:-$HOME/Library/Caches/lima}"
  cache_dir="${cache_root}/download/by-url-sha256/${url_hash}"
  if ! mkdir -p "$cache_dir"; then
    if [ -s "$cache_dir/data" ]; then
      cached_sha="$(pf_sha256_file "$cache_dir/data")" || cached_sha=""
      if [ "$cached_sha" = "$digest_hex" ]; then
        pf_line ok "VM image cached (${name}, sha256:${digest_hex:0:12})"
        return 0
      fi
    fi
    pf_line warn "VM image pre-fetch skipped (cannot create cache dir); install will download it"
    return 0
  fi

  lock_dir="$cache_dir/.prefetch.lock"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    lock_pid=""
    if [ -r "$lock_dir/pid" ]; then
      IFS= read -r lock_pid <"$lock_dir/pid" || lock_pid=""
    fi
    if [ -n "$lock_pid" ]; then
      missing_pid=0
      case "$lock_pid" in
        *[!0-9]*)
          rm -rf "$lock_dir"
          continue
          ;;
      esac
      if ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -rf "$lock_dir"
        continue
      fi
    else
      missing_pid=$((missing_pid + 1))
      if [ "$missing_pid" -ge 3 ]; then
        rm -rf "$lock_dir"
        missing_pid=0
        continue
      fi
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$max_attempts" ]; then
      pf_line warn "VM image pre-fetch skipped (cache lock busy); install will download it"
      return 0
    fi
    /bin/sleep 0.1 2>/dev/null || /bin/sleep 1 2>/dev/null || true
  done
  printf '%s\n' "$$" >"$lock_dir/pid" 2>/dev/null || true

  if [ -s "$cache_dir/data" ]; then
    cached_sha="$(pf_sha256_file "$cache_dir/data")" || cached_sha=""
    if [ "$cached_sha" = "$digest_hex" ]; then
      rm -rf "$lock_dir"
      pf_line ok "VM image cached (${name}, sha256:${digest_hex:0:12})"
      return 0
    fi
    rm -f "$cache_dir/data"
  fi
  if ! command -v curl >/dev/null 2>&1; then
    rm -rf "$lock_dir"
    pf_line warn "VM image pre-fetch skipped (curl not found); install will download it"
    return 0
  fi
  part_file="$cache_dir/data.part.$$"
  rm -f "$part_file" "$cache_dir/data.part"
  if ! curl -fSL -o "$part_file" "$url" 2>/dev/null; then
    rm -f "$part_file"
    rm -rf "$lock_dir"
    pf_line warn "VM image pre-fetch failed (download failed); install will download it"
    return 0
  fi
  part_sha="$(pf_sha256_file "$part_file")" || part_sha=""
  if [ "$part_sha" != "$digest_hex" ]; then
    rm -f "$part_file" "$cache_dir/data"
    rm -rf "$lock_dir"
    pf_line warn "VM image pre-fetch failed (sha256 mismatch); install will download it"
    return 0
  fi
  if ! { printf '%s' "$url" >"$cache_dir/url" &&
    printf 'sha256:%s' "$digest_hex" >"$cache_dir/sha256.digest" &&
    printf 'application/octet-stream' >"$cache_dir/type" &&
    mv -f "$part_file" "$cache_dir/data"; }; then
    rm -f "$part_file" "$cache_dir/data"
    rm -rf "$lock_dir"
    pf_line warn "VM image pre-fetch failed (could not write cache); install will download it"
    return 0
  fi
  rm -rf "$lock_dir"
  pf_line ok "VM image pre-fetched (${name}, sha256:${digest_hex:0:12})"
  return 0
}

# cmd_preflight [--prefetch|--no-prefetch]: preflight_collect's checks, one
# line each, each failure with the command that fixes it, plus optional VM
# image cache check/pre-fetch when all prerequisite checks pass. Exits 0 when
# every prerequisite check passes, 1 otherwise.
cmd_preflight() {
  local prefetch=0 no_prefetch=0 failed=0 total i
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefetch) prefetch=1; no_prefetch=0; shift ;;
      --no-prefetch) no_prefetch=1; prefetch=0; shift ;;
      *) die "preflight: unknown option $1 (see bin/homefield help preflight)" ;;
    esac
  done
  preflight_collect
  total=${#PF_NAME[@]}
  for ((i = 0; i < total; i++)); do
    pf_render_row "" "$i"
    [ "${PF_LEVEL[i]}" = ok ] || [ "${PF_LEVEL[i]}" = warn ] || failed=$((failed + 1))
  done
  # Summary
  echo ""
  if [ "$failed" -eq 0 ]; then
    printf '%s\n' "$(color_wrap 1 "All checks passed (${total}/${total}).")"
    if [ "$prefetch" -eq 1 ] || { [ "$no_prefetch" -eq 0 ] && have_terminal; }; then
      preflight_image
    fi
    return 0
  fi
  printf '%s ' "$(color_wrap 3 "FAILED ${failed}/${total} check(s).")"
  echo "Fix the above and retry."
  return 1
}

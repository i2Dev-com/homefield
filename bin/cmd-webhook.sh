#!/usr/bin/env bash
# cmd-webhook.sh — the webhook receiver's command (#309).
#
# `webhook setup` wires a cloudflared named tunnel to the loopback receiver
# (`bin/webhook-receiver.py`, supervised by the com.homefield.webhook
# LaunchAgent), `webhook connect` installs the workflow_job webhook on a
# consumer repository, `webhook status` reports the pieces, and
# `webhook remove [--purge]` takes it down. Each verified delivery makes the
# receiver spawn one `fleet watch --max-ticks 1` tick, so a dark VM's wake
# no longer waits up to the route-watcher's tick interval; the tick stays
# the only decision point.

# webhook_dir: the receiver's state (secret, config, tick.pid, logs) under
# the route-watcher's state directory, where the scaler's records live.
webhook_dir() { printf '%s/webhook' "$(route_watcher_dir)"; }
webhook_secret_file() { printf '%s/secret' "$(webhook_dir)"; }
webhook_config_file() { printf '%s/config' "$(webhook_dir)"; }
webhook_log_file() { printf '%s/log' "$(webhook_dir)"; }
webhook_plist_path() { printf '%s/com.homefield.webhook.plist' "${HOMEFIELD_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"; }
# The tunnel name, resolved the same way the receiver resolves it (the
# plist bakes HOMEFIELD_WEBHOOK_TUNNEL and webhook-receiver.py reads it):
# setup must discover, create and route the very tunnel the agent runs, or
# an override would route the hostname to one tunnel while the receiver
# starts another.
webhook_tunnel_name() { printf '%s' "${HOMEFIELD_WEBHOOK_TUNNEL:-homefield-webhook}"; }

# webhook_tunnel_id <name>: the tunnel's UUID, from cloudflared's own list
# (the credentials file is named after it: ~/.cloudflared/<id>.json). Empty
# when the tunnel does not exist yet. The name is the one the caller means:
# setup looks up the name it is setting up, status the installed one.
webhook_tunnel_id() {
  local name="${1:-}"
  [ -n "$name" ] || name="$(webhook_installed_tunnel)"
  cloudflared tunnel list --output json 2>/dev/null |
    jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -1
}

# webhook_installed_tunnel: the tunnel name the installed setup recorded
# (the config's tunnel= line), or the env/default when nothing is
# installed. Removal and status must act on the tunnel the setup actually
# created: a setup that ran with HOMEFIELD_WEBHOOK_TUNNEL has to be
# removed and reported the same way from a shell without the variable,
# and the default name must never be deleted in its place.
webhook_installed_tunnel() {
  local saved
  saved="$(webhook_config_get tunnel || true)"
  if [ -n "$saved" ]; then
    printf '%s' "$saved"
  else
    webhook_tunnel_name
  fi
}

# webhook_config_get <key>: one KEY=value line from the setup's config file.
webhook_config_get() {
  [ -f "$(webhook_config_file)" ] || return 1
  sed -n "s/^$1=//p" "$(webhook_config_file)" | head -1
}

# webhook_port_free <port>: 0 when nothing is listening on the loopback port.
webhook_port_free() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(0)
sys.exit(1)
PY
}

# webhook_receiver_answers <port>: 0 when the endpoint on the loopback port
# answers the receiver's healthz — the listener is our receiver, so
# re-running setup on its port is reconfiguration, not a conflict.
webhook_receiver_answers() {
  python3 - "$1" <<'PY'
import http.client, sys
try:
    c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=2)
    c.request("GET", "/healthz")
    r = c.getresponse()
    r.read()
    sys.exit(0 if r.status == 200 else 1)
except OSError:
    sys.exit(1)
PY
}

# webhook_url: the public URL deliveries are posted to, from the config file.
webhook_url() {
  local hostname
  hostname="$(webhook_config_get hostname)" || return 1
  printf 'https://%s/webhook' "$hostname"
}

webhook_setup() {
  local hostname="" port="${HOMEFIELD_WEBHOOK_PORT:-8787}" overwrite_dns=0 tunnel cert id creds
  while [ $# -gt 0 ]; do
    case "$1" in
      --hostname) hostname="${2:?webhook setup: --hostname needs a value}"; shift 2 ;;
      --port) port="${2:?webhook setup: --port needs a value}"; shift 2 ;;
      --overwrite-dns) overwrite_dns=1; shift ;;
      *) die "webhook setup: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  [ -n "$hostname" ] || die "webhook setup: --hostname <fqdn> is required (the DNS name the tunnel is served on)"
  case "$hostname" in
    *[!a-zA-Z0-9.-]* | [!a-zA-Z0-9]* | *[!a-zA-Z0-9] | *. | .* | -* | *-)
      die "webhook setup: --hostname must be a plain DNS name (letters, digits, dots, inner hyphens): $hostname" ;;
    *.*) ;;
    *) die "webhook setup: --hostname must be a fully qualified name with a dot: $hostname" ;;
  esac
  case "$port" in
    '' | *[!0-9]*) die "webhook setup: --port must be a number, got: $port" ;;
  esac
  command -v cloudflared >/dev/null 2>&1 || die "webhook setup: cloudflared is not on PATH (brew install cloudflared)"
  command -v jq >/dev/null 2>&1 || die "webhook setup: jq is not on PATH (brew install jq)"
  command -v python3 >/dev/null 2>&1 || die "webhook setup: python3 is required (xcode-select --install)"
  webhook_port_free "$port" || {
    if webhook_receiver_answers "$port"; then
      # The listener answers the receiver's healthz: it is the installed
      # receiver, and re-running setup on its port is reconfiguration
      # (changed webhook or scaler settings), not a conflict.
      log "port $port is the installed receiver's own; reinstalling the agent on it"
    else
      die "webhook setup: port $port is already in use on this Mac (pick another with --port)"
    fi
  }

  # The tunnel login is an interactive browser flow the tool cannot do:
  # say so precisely instead of failing deep in the tunnel steps.
  cert="${TUNNEL_ORIGIN_CERT:-$HOME/.cloudflared/cert.pem}"
  [ -f "$cert" ] ||
    die "webhook setup: no cloudflared login found ($cert); run 'cloudflared tunnel login' first (a browser approves the zone)"

  tunnel="$(webhook_tunnel_name)"
  id="$(webhook_tunnel_id "$tunnel")"
  if [ -z "$id" ]; then
    cloudflared tunnel create "$tunnel" || die "webhook setup: could not create the tunnel '$tunnel'"
    id="$(webhook_tunnel_id "$tunnel")"
    [ -n "$id" ] || die "webhook setup: tunnel '$tunnel' created but not listed; check 'cloudflared tunnel list'"
  fi
  creds="$HOME/.cloudflared/$id.json"
  [ -f "$creds" ] || die "webhook setup: tunnel credentials missing ($creds); re-run 'cloudflared tunnel create $tunnel'"

  # An existing DNS record is not automatically fine: the route error says
  # nothing about the existing record's target, and the record is a
  # proxied CNAME whose target resolution cannot reveal — it may point at
  # this tunnel (a re-run) or at another tunnel or service, in which case
  # deliveries would never arrive and scaling would never run. Overwrite
  # only when the operator asks; refuse with the exact command otherwise.
  local route_out
  if ! route_out="$(cloudflared tunnel route dns "$tunnel" "$hostname" 2>&1)"; then
    case "$route_out" in
      *"already exists"*)
        if [ "$overwrite_dns" = 1 ]; then
          if ! cloudflared tunnel route dns --overwrite-dns "$tunnel" "$hostname" 2>&1; then
            die "webhook setup: could not replace the DNS record for $hostname (delete it in the Cloudflare dashboard, then re-run 'homefield webhook setup')"
          fi
          log "replaced the existing DNS record for $hostname (it may have pointed at another tunnel or service)"
        else
          die "webhook setup: a DNS record for $hostname already exists (it may point at another tunnel or service, in which case deliveries would not arrive). If it is this tunnel's, re-run with --overwrite-dns; otherwise fix the record in the Cloudflare dashboard first"
        fi
        ;;
      *) die "webhook setup: could not route $hostname to the tunnel: $route_out" ;;
    esac
  fi

  local secret
  secret="$(webhook_secret_file)"
  mkdir -p "$(webhook_dir)" || die "webhook setup: could not create $(webhook_dir)"
  if [ ! -s "$secret" ]; then
    (umask 077 && python3 -c 'import secrets; print(secrets.token_hex(32))' >"$secret") ||
      die "webhook setup: could not write the webhook secret"
  fi

  # The config the status/remove paths read back (hostname first: the URL).
  (umask 077 && printf 'hostname=%s\nport=%s\ntunnel=%s\n' "$hostname" "$port" "$tunnel" >"$(webhook_config_file)") ||
    die "webhook setup: could not write $(webhook_config_file)"

  webhook_agent_install "$port"

  log "webhook receiver installed; deliveries to $(webhook_url) ring the scaler"
  log "next: connect repositories with 'homefield webhook connect <owner/repo>'"
}

# webhook_agent_install [port]: write and load the LaunchAgent. Idempotent
# like the route watcher's: an existing agent is unloaded and rewritten.
# The agent runs the receiver through /bin/sh so it survives python3 moving
# (a brew upgrade), with the PATH it needs for gh, limactl, jq and
# cloudflared — launchd's own PATH has none of them.
webhook_agent_install() {
  local port="${1:-8787}" plist dir log py
  command -v launchctl >/dev/null 2>&1 || {
    echo "homefield: launchctl is required to install the webhook receiver" >&2
    return 1
  }
  py="$(command -v python3)" || {
    echo "homefield: the webhook receiver needs python3; install it (xcode-select --install) and re-run webhook setup" >&2
    return 1
  }
  plist="$(webhook_plist_path)"
  dir="$(dirname "$plist")"
  log="$(webhook_log_file)"
  mkdir -p "$dir" "$(webhook_dir)" || {
    echo "homefield: could not create ${dir} or $(webhook_dir); the receiver was not installed" >&2
    return 1
  }
  # launchd does not inherit a shell's environment: every variable the
  # receiver and its tick child read must be baked into the plist's own
  # environment block (the same rule the route watcher follows).
  local env_xml=""
  # The port is always baked: an explicit --port must reach the receiver,
  # whose own default (8787) would otherwise disagree with the config file
  # status reads back.
  env_xml="${env_xml}    <key>HOMEFIELD_WEBHOOK_PORT</key>"$'\n'"    <string>$(route_watcher_xml_escape "$port")</string>"$'\n'
  if [ -n "${HOMEFIELD_STATE_DIR:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_STATE_DIR</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_STATE_DIR")</string>"$'\n'
  fi
  if [ -n "${LIMA_HOME:-}" ]; then
    env_xml="${env_xml}    <key>LIMA_HOME</key>"$'\n'"    <string>$(route_watcher_xml_escape "$LIMA_HOME")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_WEBHOOK_ACTIONS:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_WEBHOOK_ACTIONS</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_WEBHOOK_ACTIONS")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_WEBHOOK_DEBOUNCE:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_WEBHOOK_DEBOUNCE</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_WEBHOOK_DEBOUNCE")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_WEBHOOK_TUNNEL:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_WEBHOOK_TUNNEL</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_WEBHOOK_TUNNEL")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_WEBHOOK_READ_TIMEOUT:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_WEBHOOK_READ_TIMEOUT</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_WEBHOOK_READ_TIMEOUT")</string>"$'\n'
  fi
  if [ -n "${HOMEFIELD_WEBHOOK_MAX_CONNECTIONS:-}" ]; then
    env_xml="${env_xml}    <key>HOMEFIELD_WEBHOOK_MAX_CONNECTIONS</key>"$'\n'"    <string>$(route_watcher_xml_escape "$HOMEFIELD_WEBHOOK_MAX_CONNECTIONS")</string>"$'\n'
  fi
  # The scaler's tuning reaches this agent the same way it reaches the
  # route watcher's: a webhook-triggered tick is the same tick, and an
  # operator's fleet cap, idle cooldown or scale-to-zero switch must bind
  # it too, or deliveries would scale with the defaults while the
  # periodic ticks enforce the configured policy. A setting the shell
  # does not carry is read back from the installed route watcher's plist
  # (install/upgrade --auto-route baked it there), so a webhook setup in
  # a plain shell still inherits the policy the fleet runs under.
  local scale_var scale_val
  for scale_var in HOMEFIELD_SCALE_INTERVAL HOMEFIELD_SCALE_WAIT HOMEFIELD_SCALE_IDLE HOMEFIELD_SCALE_MAX HOMEFIELD_SCALE_ZERO HOMEFIELD_SCALE_TICK_BUDGET; do
    scale_val="${!scale_var:-}"
    if [ -z "$scale_val" ] && [ -f "$(route_watcher_plist_path)" ]; then
      scale_val="$(sed -n "/<key>$scale_var<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}" "$(route_watcher_plist_path)")"
    fi
    [ -n "$scale_val" ] && env_xml="${env_xml}    <key>$scale_var</key>"$'\n'"    <string>$(route_watcher_xml_escape "$scale_val")</string>"$'\n'
  done
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.homefield.webhook</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>exec "$(route_watcher_xml_escape "$py")" "$(route_watcher_xml_escape "$ROOT/bin/webhook-receiver.py")"</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(route_watcher_xml_escape "$PATH")</string>
${env_xml}  </dict>
  <key>StandardOutPath</key>
  <string>$(route_watcher_xml_escape "$log")</string>
  <key>StandardErrorPath</key>
  <string>$(route_watcher_xml_escape "$log")</string>
</dict>
</plist>
EOF
  launchctl unload -w "$plist" 2>/dev/null || true
  launchctl load -w "$plist" || {
    echo "homefield: could not load the webhook receiver LaunchAgent ${plist}" >&2
    return 1
  }
  log "installed the webhook receiver (${plist}, port ${port})"
}

webhook_connect() {
  local repo="${1:-}"
  [ -n "$repo" ] || die "webhook connect: needs a repository (owner/repo)"
  case "$repo" in
    */*) ;;
    *) die "webhook connect: expected owner/repo, got: $repo" ;;
  esac
  local url secret body hook_id
  url="$(webhook_url)" || die "webhook connect: no setup config; run 'homefield webhook setup --hostname <fqdn>' first"
  secret="$(webhook_secret_file)"
  [ -s "$secret" ] || die "webhook connect: no webhook secret; run 'homefield webhook setup' first"

  hook_id="$(gh api "repos/$repo/hooks" --paginate --jq ".[] | select(.config.url == \"$url\") | .id" 2>/dev/null | head -1)"

  # The secret reaches GitHub through the request body, built from the
  # secret file by python3 — never a command line (ps), never the
  # environment — and the body file is 0600 in the state dir, removed on
  # every exit path.
  body="$(webhook_dir)/connect-body.json"
  (umask 077 && python3 - "$secret" "$url" >"$body" <<'PY'
import json, sys
secret = open(sys.argv[1]).read().strip()
print(json.dumps({
    # GitHub's create-repository-webhook API requires the hook name "web"
    # ("webhook" is a 422: Hook.name invalid) — discovered on the live
    # connect, the stubbed suite never validated it.
    "name": "web",
    "active": True,
    "events": ["workflow_job"],
    "config": {"url": sys.argv[2], "content_type": "json", "secret": secret},
}))
PY
  ) || die "webhook connect: could not build the request body"

  if [ -n "$hook_id" ]; then
    # A hook already exists for this URL: refresh it with the current
    # secret and subscription instead of treating the URL match as
    # sufficient — a remove + re-setup rotates the secret, and GitHub
    # signing deliveries with the old one would 403 every one of them.
    if ! gh api "repos/$repo/hooks/$hook_id" -X PATCH --input "$body" --jq .id >/dev/null 2>&1; then
      rm -f "$body"
      die "webhook connect: could not refresh the webhook on $repo (hook $hook_id; gh failed)"
    fi
    rm -f "$body"
    log "$repo: webhook refreshed with the current secret (hook $hook_id)"
    return 0
  fi

  if ! hook_id="$(gh api "repos/$repo/hooks" --input "$body" --jq .id 2>/dev/null)"; then
    rm -f "$body"
    die "webhook connect: could not create the webhook on $repo (gh failed; check its auth and the repo admin scope)"
  fi
  rm -f "$body"
  log "$repo: webhook connected (hook $hook_id), events workflow_job, url $url"
}

webhook_status() {
  local rc=0 port hostname
  if [ ! -f "$(webhook_plist_path)" ]; then
    echo "agent: not installed (run 'homefield webhook setup --hostname <fqdn>')"
    return 1
  fi
  # launchctl list writes the agent list to stdout, and grep -q's early exit
  # SIGPIPEs the producer — which set -o pipefail turns into a false "not
  # loaded" (#318 review; the list is large enough that this fires whether
  # the producer is launchctl or a printf of the captured list). Match in
  # bash: no pipe, no producer to signal.
  local launchctl_list
  launchctl_list="$(launchctl list 2>/dev/null || true)"
  case "$launchctl_list" in
    *"com.homefield.webhook"*)
      echo "agent: loaded ($(webhook_plist_path))" ;;
    *)
      echo "agent: installed but not loaded (launchctl load $(webhook_plist_path))"
      rc=1 ;;
  esac
  hostname="$(webhook_config_get hostname)" &&
    port="$(webhook_config_get port)" ||
    {
      echo "setup: config missing (re-run 'homefield webhook setup --hostname <fqdn>')"
      return 1
    }
  echo "url: $(webhook_url)"
  [ -s "$(webhook_secret_file)" ] && echo "secret: present" || {
    echo "secret: missing (re-run 'homefield webhook setup')"
    rc=1
  }
  local id
  id="$(webhook_tunnel_id)" && [ -n "$id" ] && echo "tunnel: $id" || {
    echo "tunnel: not found (cloudflared tunnel list; re-run 'homefield webhook setup')"
    rc=1
  }
  if ! webhook_port_free "$port"; then
    echo "receiver: listening on 127.0.0.1:$port"
  else
    echo "receiver: not answering on 127.0.0.1:$port (check $(webhook_log_file))"
    rc=1
  fi
  return "$rc"
}

webhook_remove() {
  local purge=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1; shift ;;
      *) die "webhook remove: unknown option $1 (see bin/homefield help)" ;;
    esac
  done
  local plist
  plist="$(webhook_plist_path)"
  if [ -f "$plist" ]; then
    launchctl unload -w "$plist" 2>/dev/null || true
    rm -f "$plist"
    log "removed the webhook receiver agent"
  else
    log "the webhook receiver agent was not installed"
  fi
  if [ "$purge" = 1 ]; then
    local tunnel
    tunnel="$(webhook_installed_tunnel)"
    cloudflared tunnel cleanup "$tunnel" 2>/dev/null || true
    if cloudflared tunnel delete "$tunnel" 2>/dev/null; then
      log "deleted the tunnel '$tunnel'"
    else
      log "could not delete the tunnel '$tunnel' (delete it by hand: cloudflared tunnel delete $tunnel)"
    fi
  fi
  # The secret and config go with the receiver; connected repositories keep
  # their webhook and GitHub keeps retrying (then disables it) until the
  # hook is deleted or a tunnel serves the URL again — the DNS record stays
  # in the Cloudflare dashboard either way.
  rm -f "$(webhook_secret_file)" "$(webhook_config_file)" "$(webhook_dir)/tick.pid" "$(webhook_dir)/tick.log" "$(webhook_dir)/connect-body.json"
  rmdir "$(webhook_dir)" 2>/dev/null || true
  [ "$purge" = 1 ] && log "removed the receiver state (secret, config)" || true
}

cmd_webhook() {
  local sub="${1:-}"
  case "$sub" in
    setup) shift; webhook_setup "$@" ;;
    connect) shift; webhook_connect "$@" ;;
    status) webhook_status "$@" ;;
    remove) shift; webhook_remove "$@" ;;
    *) die "webhook: expected setup, connect, status, or remove (see bin/homefield help)" ;;
  esac
}
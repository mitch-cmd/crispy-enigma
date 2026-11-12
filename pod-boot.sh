#!/usr/bin/env bash
# pod-boot.sh: join a fresh RunPod pod to the tailnet at boot, then
# (optionally) run setup-gpu-ollama.sh.
#
# Runs from the template's Container start command, in the background, before
# RunPod's /start.sh:
#
#   bash -c 'curl -fsSL https://raw.githubusercontent.com/mitch-cmd/crispy-enigma/<commit-sha>/pod-boot.sh -o /pod-boot.sh && (setsid bash /pod-boot.sh > /var/log/pod-boot.log 2>&1 < /dev/null &); unset TS_AUTHKEY; exec /start.sh'
#
# Also safe to run by hand on a live pod: every step is skipped if already done.
#
# Environment (set in the template):
#   TS_AUTHKEY      Auth key (tskey-auth-...) or OAuth client secret (tskey-client-...).
#                   Use a RunPod secret: {{ RUNPOD_SECRET_ts_authkey }}.
#                   Unset: falls back to the browser login link (written to the log,
#                   and pushed to NTFY_TOPIC if set).
#   TS_HOSTNAME     Tailnet name for the pod (default: gpu-ollama)
#   TS_TAGS         Tags to advertise (default: tag:gpu). Required with an OAuth secret.
#   TS_EPHEMERAL    true/false (default: false). Only for an OAuth secret. The free plan
#                   allows 1,000 ephemeral-device minutes a month, so the default is a
#                   normal device; the name cleanup below removes the old one instead.
#   TS_OAUTH_CLIENT_ID  OAuth client ID (not secret). With an OAuth secret in TS_AUTHKEY,
#                   enables freeing TS_HOSTNAME first: any *offline* device with that
#                   exact name and one of TS_TAGS is deleted, so the pod keeps the name
#                   instead of becoming <name>-1. Client needs scopes auth_keys + devices:core.
#   TS_REPLACE_ONLINE  1 = also delete a matching device that is still online.
#   TS_IPV4         Optional fixed tailnet IPv4 (e.g. 100.100.99.121). After joining, the
#                   pod's address is changed to this via the API, so every pod has the
#                   same IP and cached DNS on clients never goes stale. Needs the same
#                   OAuth setup as the name cleanup, and the old device must be gone.
#   TS_CLEANUP_DRY_RUN 1 = only log which devices would be deleted.
#   NTFY_TOPIC      Optional ntfy.sh topic for "pod is up" / login-link messages.
#   MODEL           If set, run setup-gpu-ollama.sh --model "$MODEL" afterwards.
#   CONTEXT_LENGTH  Passed to setup-gpu-ollama.sh --context-length if set.
#   BOOT_BASE_URL   Where to fetch setup-gpu-ollama.sh from (same place as this script).

set -euo pipefail

TS_HOSTNAME="${TS_HOSTNAME:-gpu-ollama}"
TS_TAGS="${TS_TAGS:-tag:gpu}"
TS_AUTHKEY="${TS_AUTHKEY:-}"

log()    { printf '[pod-boot %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
notify() {
  [[ -n "${NTFY_TOPIC:-}" ]] || return 0
  curl -fsS -m 10 -H "Title: ${TS_HOSTNAME}" -d "$*" "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null || true
}
fail()   { log "FAIL: $*"; notify "pod-boot failed: $*"; exit 1; }
backend_state() {
  tailscale status --json 2>/dev/null | grep -m1 -o '"BackendState": *"[A-Za-z]*"' | grep -o '[A-Za-z]*"$' | tr -d '"'
}

# Delete stale devices holding TS_HOSTNAME, via the Tailscale API.
# Best effort: any problem is logged and boot carries on (worst case: <name>-1).
free_hostname() {
  if [[ "$TS_AUTHKEY" != tskey-client-* ]]; then
    log "name cleanup skipped: needs an OAuth client secret in TS_AUTHKEY"; return 0
  fi
  if [[ -z "${TS_OAUTH_CLIENT_ID:-}" ]]; then
    log "name cleanup skipped: TS_OAUTH_CLIENT_ID not set"; return 0
  fi
  if ! command -v python3 >/dev/null; then
    log "name cleanup skipped: python3 not found"; return 0
  fi
  log "freeing the name ${TS_HOSTNAME} (offline devices tagged ${TS_TAGS})"
  # Secret goes in via the environment of this one process, never argv.
  _TS_SECRET="$TS_AUTHKEY" TS_HOSTNAME="$TS_HOSTNAME" TS_TAGS="$TS_TAGS" \
  TS_OAUTH_CLIENT_ID="$TS_OAUTH_CLIENT_ID" TS_REPLACE_ONLINE="${TS_REPLACE_ONLINE:-0}" \
  TS_CLEANUP_DRY_RUN="${TS_CLEANUP_DRY_RUN:-0}" \
  python3 -I - <<'PY' 2>&1 | sed 's/^/    /' || log "name cleanup failed; carrying on"
import json, os, sys, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone

API = "https://api.tailscale.com/api/v2"

def call(method, url, form=None, token=None):
    headers, body = {}, None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if form is not None:
        body = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None

def is_online(d):
    if "connectedToControl" in d:
        return bool(d["connectedToControl"])
    # Older API responses: treat "seen in the last 10 minutes" as online.
    try:
        seen = datetime.fromisoformat(d["lastSeen"].replace("Z", "+00:00"))
        return datetime.now(timezone.utc) - seen < timedelta(minutes=10)
    except Exception:
        return True  # unknown: don't delete

want = os.environ["TS_HOSTNAME"].lower()
tags = {t.strip() for t in os.environ["TS_TAGS"].split(",") if t.strip()}
replace_online = os.environ["TS_REPLACE_ONLINE"] == "1"
dry_run = os.environ["TS_CLEANUP_DRY_RUN"] == "1"
secret = os.environ["_TS_SECRET"].split("?", 1)[0]

try:
    token = call("POST", f"{API}/oauth/token",
                 form={"client_id": os.environ["TS_OAUTH_CLIENT_ID"], "client_secret": secret})["access_token"]
    devices = call("GET", f"{API}/tailnet/-/devices", token=token)["devices"]
except urllib.error.HTTPError as e:
    print(f"API error {e.code}: {e.read()[:200].decode(errors='replace')}")
    sys.exit(1)

matched = 0
for d in devices:
    # "name" is the MagicDNS name (gpu-ollama-v2.tailXXXX.ts.net); "hostname" is the
    # container's own hostname, so match on the first label of "name", exactly.
    if d.get("name", "").split(".")[0].lower() != want:
        continue
    matched += 1
    label = f"{d['name']} (id {d['id']}, last seen {d.get('lastSeen', '?')})"
    if not tags & set(d.get("tags") or []):
        print(f"keep {label}: not tagged {', '.join(sorted(tags))}; delete it in the admin console")
    elif is_online(d) and not replace_online:
        print(f"keep {label}: still online (TS_REPLACE_ONLINE=1 to replace it)")
    elif dry_run:
        print(f"would delete {label} (dry run)")
    else:
        call("DELETE", f"{API}/device/{d['id']}", token=token)
        print(f"deleted {label}")
if not matched:
    print(f"no existing device named {want}")
PY
}

# Change this device's tailnet IPv4 to TS_IPV4, via the Tailscale API.
# Best effort: on any problem the pod keeps the address it was given.
pin_ipv4() {
  [[ -n "${TS_IPV4:-}" ]] || return 0
  local current
  current="$(tailscale ip -4 2>/dev/null | head -1)"
  if [[ "$current" == "$TS_IPV4" ]]; then
    log "tailnet IP already ${TS_IPV4}"; return 0
  fi
  if [[ "$TS_AUTHKEY" != tskey-client-* || -z "${TS_OAUTH_CLIENT_ID:-}" ]] || ! command -v python3 >/dev/null; then
    log "IP pinning skipped: needs an OAuth secret, TS_OAUTH_CLIENT_ID and python3"; return 0
  fi
  log "changing tailnet IP ${current} -> ${TS_IPV4}"
  if ! _TS_SECRET="$TS_AUTHKEY" TS_OAUTH_CLIENT_ID="$TS_OAUTH_CLIENT_ID" \
       TS_IPV4="$TS_IPV4" TS_CURRENT_IP="$current" \
       python3 -I - <<'PY' 2>&1 | sed 's/^/    /'
import json, os, sys, urllib.error, urllib.parse, urllib.request
API = "https://api.tailscale.com/api/v2"
def call(method, url, form=None, js=None, token=None):
    headers, body = {}, None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if form is not None:
        body = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if js is not None:
        body = json.dumps(js).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None
try:
    token = call("POST", f"{API}/oauth/token", form={
        "client_id": os.environ["TS_OAUTH_CLIENT_ID"],
        "client_secret": os.environ["_TS_SECRET"].split("?", 1)[0]})["access_token"]
    devices = call("GET", f"{API}/tailnet/-/devices", token=token)["devices"]
    me = next((d for d in devices if os.environ["TS_CURRENT_IP"] in (d.get("addresses") or [])), None)
    if me is None:
        print("couldn't find this device in the API's device list"); sys.exit(1)
    call("POST", f"{API}/device/{me['id']}/ip", js={"ipv4": os.environ["TS_IPV4"]}, token=token)
    print(f"requested {os.environ['TS_IPV4']} for {me['name']}")
except urllib.error.HTTPError as e:
    print(f"API error {e.code}: {e.read()[:200].decode(errors='replace')}"); sys.exit(1)
PY
  then
    log "IP pinning failed; keeping ${current}"; return 0
  fi
  for _ in $(seq 1 30); do
    [[ "$(tailscale ip -4 2>/dev/null | head -1)" == "$TS_IPV4" ]] && { log "tailnet IP now ${TS_IPV4}"; return 0; }
    sleep 1
  done
  log "API accepted ${TS_IPV4} but the pod still shows $(tailscale ip -4 | head -1); check the admin console"
}

# ---------- 1. install ----------
if ! command -v tailscaled >/dev/null; then
  log "installing tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh || fail "tailscale install failed"
else
  log "tailscale already installed: $(tailscale version | head -1)"
fi

# ---------- 2. start tailscaled (userspace mode: no systemd, no /dev/net/tun) ----------
if pgrep -x tailscaled >/dev/null; then
  log "tailscaled already running"
else
  log "starting tailscaled"
  mkdir -p /var/lib/tailscale /var/run/tailscale
  setsid nohup tailscaled \
    --tun=userspace-networking \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    --socks5-server=localhost:1055 \
    --outbound-http-proxy-listen=localhost:1055 \
    > /var/log/tailscaled.log 2>&1 < /dev/null &
fi

# Wait for the daemon to answer, instead of a fixed sleep.
state=""
for _ in $(seq 1 30); do
  state="$(backend_state || true)"
  [[ -n "$state" ]] && break
  sleep 1
done
[[ -n "$state" ]] || fail "tailscaled didn't start; see /var/log/tailscaled.log"
log "tailscaled state: $state"

# ---------- 3. join the tailnet ----------
if [[ "$state" == "Running" ]]; then
  log "already on the tailnet as $(tailscale status | awk 'NR==1{print $2}')"
elif [[ -n "$TS_AUTHKEY" ]]; then
  free_hostname
  log "joining as ${TS_HOSTNAME} with an auth key"
  key="$TS_AUTHKEY"
  extra=()
  if [[ "$key" == tskey-client-* ]]; then
    # OAuth client secret: pre-approved node, ephemeral only if asked. Tags are required.
    [[ "$key" == *\?* ]] || key="${key}?ephemeral=${TS_EPHEMERAL:-false}&preauthorized=true"
    extra+=(--advertise-tags="$TS_TAGS")
  fi
  # Pass the key through a private file, so it isn't in the process list.
  keyfile="$(mktemp)"; chmod 600 "$keyfile"
  trap 'rm -f "$keyfile"' EXIT
  printf '%s' "$key" > "$keyfile"
  unset key
  timeout 60 env -u TS_AUTHKEY tailscale up --hostname="$TS_HOSTNAME" --auth-key="file:${keyfile}" "${extra[@]}" \
    || fail "tailscale up with auth key failed"
  rm -f "$keyfile"
  pin_ipv4
  unset TS_AUTHKEY
else
  # No key: today's flow. Run `tailscale up` in the background so it waits for
  # approval without being killed, and surface the login link.
  log "no TS_AUTHKEY: falling back to the browser login link"
  setsid nohup tailscale up --hostname="$TS_HOSTNAME" > /var/log/tailscale-up.log 2>&1 < /dev/null &
  link=""
  for _ in $(seq 1 30); do
    link="$(grep -o 'https://login.tailscale.com/a/[A-Za-z0-9]*' /var/log/tailscale-up.log | head -1 || true)"
    [[ -n "$link" ]] && break
    sleep 1
  done
  [[ -n "$link" ]] || fail "no login link; see /var/log/tailscale-up.log"
  log "approve this device: $link"
  notify "Approve ${TS_HOSTNAME}: ${link}"
  # Wait up to 30 minutes for someone to approve it.
  for _ in $(seq 1 360); do
    [[ "$(backend_state || true)" == "Running" ]] && break
    sleep 5
  done
fi

[[ "$(backend_state || true)" == "Running" ]] || fail "not on the tailnet (state: $(backend_state || echo unknown))"
ts_name="$(tailscale status | awk 'NR==1{print $2}')"
ts_ip="$(tailscale ip -4)"
log "on the tailnet as ${ts_name} (${ts_ip})"

# ---------- 4. optional: Ollama ----------
if [[ -n "${MODEL:-}" ]]; then
  [[ -n "${BOOT_BASE_URL:-}" ]] || fail "MODEL is set but BOOT_BASE_URL isn't, so setup-gpu-ollama.sh can't be fetched"
  log "fetching setup-gpu-ollama.sh"
  curl -fsSL "${BOOT_BASE_URL}/setup-gpu-ollama.sh" -o /root/setup-gpu-ollama.sh || fail "couldn't fetch setup-gpu-ollama.sh"
  args=(--model "$MODEL")
  [[ -n "${CONTEXT_LENGTH:-}" ]] && args+=(--context-length "$CONTEXT_LENGTH")
  log "running setup-gpu-ollama.sh ${args[*]}"
  bash /root/setup-gpu-ollama.sh "${args[@]}" || fail "setup-gpu-ollama.sh failed; see /var/log/pod-boot.log"
  notify "${ts_name} ready: ${ts_ip}, ${MODEL} on :11434"
else
  notify "${ts_name} on the tailnet: ${ts_ip}"
fi

log "done"

#!/usr/bin/env bash
# setup-gpu-ollama.sh
#
# Sets up Ollama on a fresh RunPod pod so it can be reached over the tailnet,
# following gpu-ollama-setup.md (steps 2-5):
#
#   tailnet :11434 -> tailscale serve -> 127.0.0.1:11435 (nginx, rewrites Host) -> 127.0.0.1:11434 (ollama)
#
# Assumes Tailscale is already set up and logged in (see runpod-tailscale.md).
# Safe to run more than once.
#
# Usage (as root on the pod):
#   bash setup-gpu-ollama.sh                       # default model, 64K context
#   bash setup-gpu-ollama.sh --model gpt-oss:120b --context-length 131072
#   bash setup-gpu-ollama.sh --model qwen3-coder-next --context-length 131072
#   bash setup-gpu-ollama.sh --model gpt-oss:120b --pull   # also update the model
#
# Rerunning it is safe on a live pod: it restarts Ollama only if the context
# changed, pulls the model only if it isn't there yet (or with --pull), and
# leaves `tailscale serve` alone if it's already set up.
#
# Copy it over from the Mac first:
#   scp setup-gpu-ollama.sh <pod-name>:/root/

set -euo pipefail

# ---------- settings ----------
MODEL="qwen3-coder:30b"
CONTEXT_LENGTH=65536                 # 64K; Ollama's own default (256K) can push big models off the GPU
OLLAMA_ADDR="127.0.0.1:11434"        # Ollama: localhost only
PROXY_ADDR="127.0.0.1:11435"         # nginx #2: localhost only
TS_PORT="11434"                      # port published on the tailnet
NGINX_CONF="/etc/nginx/ollama-tailnet.conf"
NGINX_PID="/run/nginx-ollama.pid"
OLLAMA_LOG="/tmp/ollama.log"
OPENCODE_OUT="/root/opencode.jsonc"  # generated opencode config for the Mac
FORCE_PULL=0                         # 1 = pull even if the model is already on the pod

usage() {
  cat <<EOF
Usage: $(basename "$0") [--model NAME] [--context-length TOKENS] [--pull]

  -m, --model NAME             Ollama model to set up and test (default: $MODEL)
                               e.g. qwen3-coder:30b, qwen3-coder-next, gpt-oss:120b
                               Downloaded only if it isn't on the pod yet
  -c, --context-length TOKENS  Default context for every model (default: $CONTEXT_LENGTH)
                               Sets OLLAMA_CONTEXT_LENGTH; Ollama restarts if it differs
                               gpt-oss:120b on a 96 GB card: use 131072 (fits 100% on GPU)
      --pull                   Pull the model even if it's already on the pod
                               (updates it if the tag moved upstream; the digest may change)
  -h, --help                   Show this help

Assumes Tailscale is already running and logged in on this machine.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)
      [[ $# -ge 2 && -n "$2" ]] || { echo "error: $1 needs a model name" >&2; exit 2; }
      MODEL="$2"; shift 2 ;;
    --model=*)
      MODEL="${1#*=}"; [[ -n "$MODEL" ]] || { echo "error: --model needs a model name" >&2; exit 2; }
      shift ;;
    -c|--context-length)
      [[ $# -ge 2 && -n "$2" ]] || { echo "error: $1 needs a number of tokens" >&2; exit 2; }
      CONTEXT_LENGTH="$2"; shift 2 ;;
    --context-length=*)
      CONTEXT_LENGTH="${1#*=}"; shift ;;
    --pull) FORCE_PULL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$CONTEXT_LENGTH" =~ ^[1-9][0-9]*$ ]] || { echo "error: --context-length must be a positive whole number, got '$CONTEXT_LENGTH'" >&2; exit 2; }
(( CONTEXT_LENGTH >= 2048 )) || { echo "error: --context-length below 2048 is too small for a coding agent" >&2; exit 2; }
# `ollama ps` shows an untagged model as NAME:latest
[[ "$MODEL" == *:* ]] && MODEL_PS="$MODEL" || MODEL_PS="${MODEL}:latest"

# ---------- helpers ----------
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[33mwarn\033[0m %s\n' "$*"; }
die()  { printf '    \033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# Wait up to $2 seconds for URL $1 to answer 200 (extra curl args after).
wait_http() {
  local url="$1" secs="$2"; shift 2
  for _ in $(seq 1 "$secs"); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$@" "$url" || true)" == 200 ]] && return 0
    sleep 1
  done
  return 1
}

listening_on() { ss -tln | awk '{print $4}' | grep -qx "$1"; }

# OLLAMA_CONTEXT_LENGTH of the running `ollama serve` (empty if unset or not running).
running_context() {
  local pid; pid="$(pgrep -x ollama | head -1)" || return 0
  tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | sed -n 's/^OLLAMA_CONTEXT_LENGTH=//p'
}

# ---------- 0. preflight ----------
step "Preflight"
[[ $EUID -eq 0 ]] || die "run as root"
command -v tailscale >/dev/null || die "tailscale not installed: do the Tailscale setup first (runpod-tailscale.md)"
pgrep -x tailscaled >/dev/null  || die "tailscaled not running: do the Tailscale setup first (runpod-tailscale.md)"
tailscale status >/dev/null 2>&1 || die "tailscale not logged in: run 'tailscale up' first"
TS_NAME="$(tailscale status | awk 'NR==1{print $2}')"
ok "tailscale up as '${TS_NAME}'"
ok "model: ${MODEL}, context: ${CONTEXT_LENGTH} tokens"

# ---------- 1. packages ----------
step "Installing packages (lshw zstd curl nginx)"
export DEBIAN_FRONTEND=noninteractive
missing=()
for p in lshw zstd curl nginx; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if ((${#missing[@]})); then
  apt-get update -qq
  apt-get install -y -qq "${missing[@]}" >/dev/null
  ok "installed: ${missing[*]}"
else
  ok "already installed"
fi

# ---------- 2. ollama ----------
step "Installing Ollama"
if command -v ollama >/dev/null; then
  ok "already installed: $(ollama --version 2>/dev/null | tail -1)"
else
  # Warns "systemd is not running"; expected in a container.
  curl -fsSL https://ollama.com/install.sh | sh
  ok "installed: $(ollama --version 2>/dev/null | tail -1)"
fi

step "Starting Ollama on ${OLLAMA_ADDR}, context ${CONTEXT_LENGTH} (detached)"
if pgrep -x ollama >/dev/null && listening_on "$OLLAMA_ADDR" && ! listening_on "*:11434" && ! listening_on "0.0.0.0:11434" \
   && [[ "$(running_context)" == "$CONTEXT_LENGTH" ]]; then
  ok "already running on ${OLLAMA_ADDR} with context ${CONTEXT_LENGTH}"
else
  if pgrep -x ollama >/dev/null; then
    ok "restarting (running context: '$(running_context)', wanted: ${CONTEXT_LENGTH})"
  fi
  pkill -x ollama 2>/dev/null || true
  sleep 2
  OLLAMA_HOST="$OLLAMA_ADDR" OLLAMA_CONTEXT_LENGTH="$CONTEXT_LENGTH" \
    setsid nohup ollama serve > "$OLLAMA_LOG" 2>&1 < /dev/null &
  wait_http "http://${OLLAMA_ADDR}" 30 || die "ollama didn't start; see ${OLLAMA_LOG}"
  ok "started (log: ${OLLAMA_LOG})"
fi
gpu_line="$(grep -h 'inference compute' "$OLLAMA_LOG" 2>/dev/null | tail -1 || true)"
if [[ -n "$gpu_line" ]]; then
  ok "GPU: $(sed -E 's/.*description="([^"]*)".*total="([^"]*)".*/\1, \2/' <<<"$gpu_line")"
else
  warn "no GPU line in ${OLLAMA_LOG} yet (or Ollama was already running with a different log)"
fi

# ---------- 3. nginx #2: Host-rewriting proxy ----------
step "Starting Host-rewriting proxy on ${PROXY_ADDR}"
cat > "$NGINX_CONF" <<EOF
# Separate nginx instance: ${PROXY_ADDR} -> Ollama, rewriting Host so Ollama's
# Host-header check accepts requests that arrive via tailscale serve.
# Written by setup-gpu-ollama.sh.
pid ${NGINX_PID};
error_log /var/log/nginx-ollama-error.log;
events {}
http {
    access_log /var/log/nginx-ollama-access.log;
    server {
        listen ${PROXY_ADDR};
        location / {
            proxy_pass http://${OLLAMA_ADDR};
            proxy_set_header Host ${OLLAMA_ADDR};
            proxy_http_version 1.1;
            proxy_buffering off;          # stream tokens as they are generated
            proxy_read_timeout 3600s;     # long generations / model loads
            proxy_send_timeout 3600s;
            client_max_body_size 0;       # no limit on request size
        }
    }
}
EOF
nginx -t -q -c "$NGINX_CONF" || die "nginx config test failed: ${NGINX_CONF}"
if [[ -f "$NGINX_PID" ]] && kill -0 "$(cat "$NGINX_PID")" 2>/dev/null; then
  nginx -c "$NGINX_CONF" -s reload
  ok "reloaded"
else
  nginx -c "$NGINX_CONF"
  ok "started (config: ${NGINX_CONF})"
fi
wait_http "http://${PROXY_ADDR}" 10 -H "Host: ${TS_NAME}:${TS_PORT}" \
  || die "proxy doesn't pass a non-local Host header through; see /var/log/nginx-ollama-error.log"
ok "proxy accepts Host: ${TS_NAME}:${TS_PORT}"

# ---------- 4. tailscale serve ----------
step "Publishing on the tailnet: ${TS_NAME}:${TS_PORT} -> ${PROXY_ADDR}"
# Already published? Then leave it alone, so clients on the tailnet aren't cut off.
serve_status="$(tailscale serve status 2>/dev/null || true)"
if grep -q "^http://${TS_NAME}:${TS_PORT} " <<<"$serve_status" && grep -q "proxy http://${PROXY_ADDR}" <<<"$serve_status"; then
  ok "already published: tailscale serve -> http://${PROXY_ADDR}"
else
  tailscale serve --http="$TS_PORT" off >/dev/null 2>&1 || true
  timeout 30 tailscale serve --bg --http="$TS_PORT" "http://${PROXY_ADDR}" >/dev/null \
    || die "tailscale serve failed"
  tailscale serve status | grep -q "proxy http://${PROXY_ADDR}" || die "tailscale serve status doesn't show the proxy"
  ok "tailscale serve -> http://${PROXY_ADDR}"
fi

# ---------- 5. model ----------
if (( ! FORCE_PULL )) && ollama list | awk 'NR>1{print $1}' | grep -qxF "$MODEL_PS"; then
  step "Model ${MODEL}"
  ok "already on the pod ($(ollama list | awk -v m="$MODEL_PS" '$1==m{print $2}')); not pulling. Use --pull to update it"
else
  step "Pulling ${MODEL}"
  start=$(date +%s)
  ollama pull "$MODEL" || die "pull failed; check the name at https://ollama.com/library"
  ok "pulled in $(( $(date +%s) - start ))s"
fi
if ollama show "$MODEL" 2>/dev/null | sed -n '/Capabilities/,/^$/p' | grep -qw tools; then
  ok "model reports 'tools' capability"
else
  warn "model does not report 'tools'; opencode needs tool calling"
fi

# ---------- 6. checks ----------
step "Checks"
for a in "$OLLAMA_ADDR" "$PROXY_ADDR"; do
  listening_on "$a" && ok "listening on ${a}" || die "not listening on ${a}"
done
eth0_ip="$(hostname -I | awk '{print $1}')"
for p in 11434 11435; do
  if curl -s -o /dev/null -m 3 "http://${eth0_ip}:${p}"; then
    die "port ${p} answers on container address ${eth0_ip}; should be localhost only"
  fi
done
ok "11434/11435 refused on container address ${eth0_ip}"

echo "    ...tool-call test (loads the model onto the GPU; can take a minute)"
req=$(cat <<EOF
{"model":"${MODEL}","stream":false,
 "messages":[{"role":"user","content":"Read the file src/main.py"}],
 "tools":[{"type":"function","function":{"name":"read_file","description":"Read a file from disk",
   "parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}]}
EOF
)
resp="$(curl -s -m 600 "http://${PROXY_ADDR}/v1/chat/completions" \
  -H "Host: ${TS_NAME}:${TS_PORT}" -H 'Content-Type: application/json' -d "$req" || true)"
if grep -Eq '"finish_reason": ?"tool_calls"' <<<"$resp" && grep -q '"read_file"' <<<"$resp"; then
  ok "structured tool call returned"
else
  warn "no structured tool call; opencode may not work with this model"
  echo "    response: ${resp:0:300}"
fi
ollama ps | sed 's/^/    /'
ps_line="$(ollama ps | awk -v m="$MODEL_PS" '$1==m')"
if [[ -z "$ps_line" ]]; then
  warn "${MODEL} isn't loaded, so GPU placement couldn't be checked"
elif grep -q '100% GPU' <<<"$ps_line"; then
  ok "${MODEL} is 100% on the GPU"
else
  warn "${MODEL} is NOT fully on the GPU, so it will be slow. Try a smaller --context-length"
fi
if [[ -n "$ps_line" ]]; then
  if grep -qw "$CONTEXT_LENGTH" <<<"$ps_line"; then
    ok "loaded with context ${CONTEXT_LENGTH}"
  else
    warn "loaded context differs from ${CONTEXT_LENGTH} (the model's own maximum may be lower)"
  fi
fi
df -h "$HOME" | awk 'NR==2{print "    disk: "$4" free of "$2}'

# ---------- 7. opencode config for the Mac ----------
step "Writing opencode config for the Mac: ${OPENCODE_OUT}"
# Provider id = tailnet name (DNS label: a-z 0-9 -), so models show as <tailnet-name>/<model>.
PROVIDER_ID="$TS_NAME"
model_entries=""
while read -r m; do
  [[ -n "$m" ]] || continue
  # Context opencode should assume: our OLLAMA_CONTEXT_LENGTH, unless the model's own max is lower.
  ctx="$CONTEXT_LENGTH"
  max="$(ollama show "$m" 2>/dev/null | awk '/context length/{print $3; exit}' || true)"
  if [[ "$max" =~ ^[0-9]+$ ]] && (( max < ctx )); then ctx="$max"; fi
  out=$(( ctx / 4 ))
  if (( out > 16384 )); then out=16384; fi
  [[ -n "$model_entries" ]] && model_entries+=$',\n'
  model_entries+="        \"${m}\": { \"name\": \"${m} (${TS_NAME})\", \"limit\": { \"context\": ${ctx}, \"output\": ${out} } }"
done < <(ollama list | awk 'NR>1{print $1}')
[[ -n "$model_entries" ]] || die "no models in 'ollama list'"

cat > "$OPENCODE_OUT" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "${PROVIDER_ID}": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (${TS_NAME})",
      "options": { "baseURL": "http://${TS_NAME}:${TS_PORT}/v1" },
      "models": {
${model_entries}
      }
    }
  },
  "model": "${PROVIDER_ID}/${MODEL_PS}"
}
EOF
if command -v python3 >/dev/null; then
  python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$OPENCODE_OUT" \
    && ok "valid JSON" || warn "generated config is not valid JSON; check ${OPENCODE_OUT}"
fi
ok "default model: ${PROVIDER_ID}/${MODEL_PS}"

# ---------- done ----------
step "Done"
cat <<EOF
    API on the tailnet:  http://${TS_NAME}:${TS_PORT}   (OpenAI-compatible: /v1)
    Default context:     ${CONTEXT_LENGTH} tokens

    Nothing here restarts on its own after a pod restart. Rerun this script.

    opencode config: the block below goes on the machine you run opencode on
    (e.g. your Mac), not on this pod.

      Where it lives:   ~/.config/opencode/opencode.jsonc   (macOS / Linux)
      Not sure?         run  opencode debug config  there; it lists the files it reads

      Install it (on the opencode machine):
        mkdir -p ~/.config/opencode
        cp ~/.config/opencode/opencode.jsonc ~/.config/opencode/opencode.jsonc.bak 2>/dev/null  # back up
        scp root@${TS_NAME}:${OPENCODE_OUT} ~/.config/opencode/opencode.jsonc
      or copy the block below, then on macOS:
        pbpaste > ~/.config/opencode/opencode.jsonc

      This replaces the file. If it already has other providers you want to keep,
      copy just the "${PROVIDER_ID}": { ... } entry into its "provider" section.
      For one project only, save it as opencode.jsonc in that project's folder instead.

EOF
echo "----- 8< ----- opencode.jsonc -----"
cat "$OPENCODE_OUT"
echo "----- 8< ----- end -----"
cat <<EOF

    Then check on the Mac:
      curl http://${TS_NAME}:${TS_PORT}
      opencode models | grep '${PROVIDER_ID}/'
      opencode run "Reply with just the word: pong"
EOF

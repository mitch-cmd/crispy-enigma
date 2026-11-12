# crispy-enigma

Boot scripts for a RunPod GPU pod that joins a Tailscale tailnet by itself and serves Ollama on it. Nothing is exposed to the internet.

| File | What it does |
|---|---|
| `pod-boot.sh` | Runs at pod start. Installs Tailscale, starts `tailscaled` in userspace mode (pods have no systemd and no `/dev/net/tun`), and joins the tailnet with an auth key. If `MODEL` is set, it then runs `setup-gpu-ollama.sh`. |
| `setup-gpu-ollama.sh` | Installs Ollama, puts an nginx proxy in front of it to rewrite the `Host` header, and publishes it on the tailnet at `<name>:11434` with `tailscale serve`. Also writes an opencode config to `/root/opencode.jsonc`. |

Both scripts are safe to rerun on a live pod.

## RunPod template

Use a RunPod PyTorch image, which runs `/start.sh`. The start command replaces the image's CMD (`/start.sh`), so it has to hand over to `/start.sh` at the end, or the pod loses SSH and stops.

**Container start command** (pin a commit, not `main`):

```bash
bash -c 'curl -fsSL https://raw.githubusercontent.com/mitch-cmd/crispy-enigma/<commit-sha>/pod-boot.sh -o /pod-boot.sh && (setsid bash /pod-boot.sh > /var/log/pod-boot.log 2>&1 < /dev/null &); unset TS_AUTHKEY; exec /start.sh'
```

`unset TS_AUTHKEY` keeps the key out of `/etc/rp_environment`, the world-readable file where `/start.sh` saves every environment variable.

**Environment variables:**

| Name | Example | Notes |
|---|---|---|
| `TS_AUTHKEY` | `{{ RUNPOD_SECRET_ts_authkey }}` | A Tailscale OAuth client secret (`tskey-client-…`) or an ephemeral auth key. Always store it as a RunPod Secret. If unset, the script falls back to the browser login link. |
| `TS_OAUTH_CLIENT_ID` | `k123…` | Needed for the step that frees the hostname (see below). |
| `TS_HOSTNAME` | `gpu-ollama-v2` | The pod's name on the tailnet. |
| `TS_TAGS` | `tag:gpu` | The default. |
| `TS_EPHEMERAL` | `false` | The default. Only applies to an OAuth secret. The free plan allows 1,000 ephemeral-device minutes a month, so pods join as normal devices and the hostname step removes old ones. |
| `BOOT_BASE_URL` | `https://raw.githubusercontent.com/mitch-cmd/crispy-enigma/<commit-sha>` | Where `setup-gpu-ollama.sh` is fetched from. |
| `MODEL` | `gpt-oss:120b` | Optional. If set, Ollama is set up with this model. |
| `CONTEXT_LENGTH` | `131072` | Optional. |
| `NTFY_TOPIC` | a long random string | Optional. Push notifications through ntfy.sh. |
| `TS_CLEANUP_DRY_RUN` | `1` | Optional. Only logs what the hostname step would delete. |
| `TS_REPLACE_ONLINE` | `1` | Optional. Also replaces a device with the same name that is still online. |

## Keeping the same hostname

Each pod is a new Tailscale device. If a device with the same name is still in the tailnet, the new pod becomes `<name>-1`. When `TS_AUTHKEY` holds an OAuth client secret and `TS_OAUTH_CLIENT_ID` is set, `pod-boot.sh` first deletes **offline** devices with exactly `TS_HOSTNAME` that carry one of `TS_TAGS`. It never touches untagged devices, and it leaves online ones alone unless `TS_REPLACE_ONLINE=1`.

## Tailscale setup

1. **Access rules:** add `tag:gpu` to `tagOwners`, and allow your own devices to reach `tag:gpu:22` and `tag:gpu:11434`. Give `tag:gpu` no access to anything else.
2. **OAuth client:** create one with write access to auth keys and to devices (`devices:core`), limited to `tag:gpu`.

## Logs on the pod

- `/var/log/pod-boot.log`: this script
- `/var/log/tailscaled.log`: the Tailscale daemon

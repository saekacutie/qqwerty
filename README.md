# qqwerty — Caddy + SSH + UDP Gateway (Cloud Run)

Gaming-tunnel gateway image: **Caddy** (edge proxy) → Python WS→SSH bridge → **sshd**,
plus **BadVPN UDPGW** for UDP-based game traffic.

```
client ──/saeka-ssh*──> :8080 (caddy) ──> 127.0.0.1:2222 (bridge.py) ──> 127.0.0.1:22 (sshd)
                                                        └─ UDP via badvpn-udpgw 127.0.0.1:7300
```

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | `ubuntu:22.04` + openssh, caddy (official repo), badvpn built from source |
| `Caddyfile` | `:8080`; `/saeka-ssh*` → `127.0.0.1:2222` (`flush_interval -1` for low latency) |
| `entrypoint.sh` | sshd + udpgw + inline WS bridge + watchdog + caddy |
| `deploy.sh` | Quota-aware Cloud Run deployer (`gcloud builds submit` + `gcloud run deploy`) |
| `banner.txt` | SSH login banner |

## Deploy

```bash
chmod +x deploy.sh
./deploy.sh
```

The SSH password for user `saeka` is **generated at container start** and printed to the
logs (override with the `SSH_PASSWORD` environment variable). It is never baked into the image.

## Tuning

The image ships performance tunables (see Dockerfile/entrypoint comments):
`UseDNS no`, keepalives, `MaxSessions 50`, 1MB socket buffers, `ulimit -n 65535`.

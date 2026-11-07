# xgcpx

Production-oriented GCP package for a Cloud Run API gateway, persistent Compute Engine gateway tier, global HTTPS load balancing, and Cloud Armor policy. Cloud Run provides HTTP autoscaling; the VM managed instance group provides persistent gateway capacity and a place for raw TCP/TLS proxy listeners.

## Layout

```text
.
├── deploy.sh
├── Dockerfile                  # Unified Gateway (Caddy)
├── entrypoint.sh
├── backend/                    # Go health/status service
├── proxies/
│   ├── caddy/
│   ├── envoy/
│   ├── nginx/
│   ├── traefik/
│   ├── openvpn/                # Certificate-authenticated UDP VPN VM image/config
│   └── xray/                   # Authenticated native protocol VM image/config
└── terraform/                  # Cloud Run, MIG, protocol VM, HTTPS LB, firewalls
```

## Deploy

Use Google Cloud Shell with an active project, `gcloud`, Docker, and Terraform installed:

```sh
chmod +x deploy.sh
./deploy.sh
# Optional: choose a specific region explicitly.
./deploy.sh --region asia-southeast1
```

The script verifies the active gcloud account, Terraform Application Default Credentials (ADC), project access, and billing, then enables required APIs before asking for deployment settings. Terraform uses ADC separately from the active gcloud CLI account: on a local machine run `gcloud auth application-default login`, or set `GOOGLE_APPLICATION_CREDENTIALS` to an authorized credential file. The deployer also needs sufficient project IAM permissions for the APIs and resources in the Terraform configuration; an active login alone does not grant those permissions. Region precedence is `--region`, `XGCPX_REGION`, `CLOUDSDK_COMPUTE_REGION`, then `gcloud config get-value compute/region`. The live region selector intersects Cloud Run-supported locations, Compute Engine regions with status `UP`, and regions where the selected VM family is listed. It reads regional CPU quota usage and blocks when visible quota is below the VM count required by the selected runtime; it warns if the quota cannot cover the full autoscaling ceiling. Flags show approximate region geography, not the operator's physical location. Service API support, quota, machine-type listing, and enabled billing do not guarantee zonal capacity or bypass organization policies, student-workspace restrictions, or IAM denials. A saved Terraform plan is generated before apply so provider credentials and plan-time permission errors are surfaced before Terraform applies managed resources.

The script selects a gateway, protocol set, service name, region, and VM tier; accepts optional Cloud Armor rules; generates credentials in Secret Manager; builds the required images; and applies a verified Terraform plan. The optional application upstream defaults to the built-in Cloud Run API sidecar; `/persistent/*` uses the VM only when an external application upstream is configured. `XGCPX_PROTOCOLS` accepts `1`-`8`, comma-separated selections, `9`, or `all`; the current mapping is documented below. Selected protocol ports are opened to public IPv4 sources. OpenVPN uses UDP 1194 on the protocol VM's static public IP and cannot be relayed through a Cloud Run URL. The generated client profile is written locally with mode `0600`; create DNS A records for the load-balancer and relay hostnames using their separately printed IPs.
The protocol runtime defaults to the existing hybrid behavior. Set `XGCPX_PROTOCOL_RUNTIME=cloud-run` (or choose it interactively) to run HTTP-compatible Xray transports inside a Cloud Run sidecar. The existing gateway VM/MIG remains for `/persistent/*`. In Cloud Run mode, option 4 (Shadowsocks raw TCP/UDP) is rejected; options 1-3 and 6-8 run in Cloud Run. Option 5 (OpenVPN UDP) remains on a protocol VM, which is not created unless OpenVPN is selected. `9`/`all` selects all Cloud Run-compatible services plus OpenVPN, but excludes Shadowsocks in this mode. The shared Cloud Run revision uses a 3600-second timeout; long-lived streams still consume request concurrency and are subject to Cloud Run scaling and billing.

The script selects a gateway, protocol set, service name, region, and VM tier; accepts optional Cloud Armor rules; generates credentials in Secret Manager; builds the required images; and applies a verified Terraform plan. The optional application upstream defaults to the built-in Cloud Run API sidecar; `/persistent/*` uses the VM only when an external application upstream is configured. `XGCPX_PROTOCOLS` accepts `1`-`8`, comma-separated selections, `9`, or `all`; the current mapping is documented below. Selected protocol ports are opened to public IPv4 sources. OpenVPN uses UDP 1194 on the protocol VM's static public IP and cannot be relayed through a Cloud Run URL. The generated client profile is written locally with mode `0600`; create DNS A records for the load-balancer and relay hostnames using their separately printed IPs.

The deploy script does not create GitHub repositories or push source code. Manage repository remotes and commits separately from infrastructure deployment.

## Architecture and protocol boundaries

### Current Protocol Selector

`deploy.sh` accepts a single number, comma-separated numbers, or `all` through `XGCPX_PROTOCOLS` (or its interactive prompt): 1 VLESS WebSocket/HTTPUpgrade; 2 VLESS gRPC; 3 xHTTP packet-up, stream-up, and stream-one; 4 Shadowsocks TCP/UDP; 5 OpenVPN UDP; 6 Trojan WebSocket/HTTPUpgrade; 7 VMess WebSocket; 8 SSH-over-WebSocket; and 9 or `all` for all services. In hybrid mode, HTTP transports route through the Cloud Run gateway to the protocol VM. In Cloud Run mode, HTTP transports terminate in the Xray sidecar; OpenVPN UDP remains a direct VM endpoint. Shadowsocks raw TCP/UDP is VM-only and rejected in Cloud Run mode.

TCP 80/443 are common relay listeners retained for HTTP redirects and ACME TLS; protocol-specific ports are added to that baseline.

- The global external Application Load Balancer terminates TLS, provides HTTP/2 and HTTP/3 to clients, and applies Cloud Armor WAF, IP rules, and rate limits.
- Requests go to a Cloud Run serverless NEG. `/persistent/*` routes to the VM managed instance group only when an external HTTPS application upstream is configured; otherwise it stays on Cloud Run.
- Cloud Run runs the selected HTTP proxy and a small built-in Go API sidecar on a shared instance network. With no external upstream, `/healthz`, `/status`, and JSON responses are served by that sidecar. It is a connectivity/control-plane placeholder, not a production app or WebSocket/gRPC server. Use an application upstream that implements WebSocket or gRPC for those protocols. The gateway hostname is never used as its own upstream, avoiding an HTTP proxy loop.
- In hybrid mode, a separate Compute Engine VM with a reserved public IP serves selected Xray inbounds. In Cloud Run mode, the Xray sidecar handles selected HTTP transports and the protocol VM is created only for OpenVPN. Any relay VM uses `relay.<your-domain>`; its public firewall rules are not protected by Cloud Armor L7.
- In hybrid mode, the protocol VM runs Xray behind Caddy TLS termination: VLESS WebSocket and HTTPUpgrade on TLS 443; gRPC on TLS 443 and 50051; xHTTP packet-up, stream-up, and stream-one on TLS 443 and 8080; Trojan WebSocket and HTTPUpgrade on TLS 443; VMess WebSocket on TLS 443; optional SSH-over-WebSocket on TLS 443; and authenticated Shadowsocks on TCP/UDP 8388. Selection 9 / `all` enables every service, including OpenVPN. In Cloud Run mode these HTTP transports use the Xray sidecar; OpenVPN remains VM-only. The 80/TCP listener supports relay redirects and ACME issuance in hybrid mode.
- The gateway VM/MIG remains in both modes. The protocol VM is created for hybrid mode or when OpenVPN is selected in Cloud Run mode.
- Protocol menu mapping: 1-3 VLESS transports, 4 Shadowsocks (mux is client-side), 5 OpenVPN, 6 Trojan WebSocket/HTTPUpgrade, 7 VMess, 8 SSH-over-WebSocket, and 9/all all services.
- Xray mux is a client-side outbound setting, not a server listener or port. `deploy.sh` generates mode-0600 Xray client JSON profiles with mux enabled for selected VLESS, Trojan, VMess, and Shadowsocks TCP transports; Shadowsocks UDP, OpenVPN UDP, and the `websocat` SSH client do not use Xray mux. Profiles use the Cloud Run hostname for HTTP transports and the relay hostname for Shadowsocks.
- When selected, a separate OpenVPN container runs on the same protocol VM and static IP on UDP 1194. It uses a generated CA, client/server certificates, a `tls-crypt` key, and full-tunnel IPv4 routing with NAT; its server private key stays in Secret Manager and the client profile is written to a mode-0600 local `.ovpn` file. OpenVPN is not hosted by Cloud Run.
- The pinned Xray release accepts the configured transports and protocols, but warns that WebSocket, HTTPUpgrade, gRPC, Shadowsocks, Trojan, and VMess are deprecated upstream; Shadowsocks and VMess also lack forward secrecy. They are included for client compatibility, while xHTTP is the preferred option for new clients. Review upstream Xray release notes before upgrades.
- Xray configuration is generated from `proxies/xray/config.json` using fresh VLESS and VMess UUIDs, Trojan and Shadowsocks passwords, and (when selected) a separate SSH password. Only selected inbounds are included. The rendered configuration and SSH credential are stored together in Secret Manager; the protocol VM or Cloud Run sidecar runtime identity receives access only when that runtime is enabled. Credentials are shown once in deploy output—store them securely.
- Hybrid mode opens selected protocol VM ports to public IPv4 sources. Cloud Run mode exposes only HTTP-compatible paths through the load balancer; OpenVPN UDP remains public on its protocol VM, and option 4 is rejected because raw Shadowsocks TCP/UDP cannot run on Cloud Run. VLESS/VMess require generated UUIDs, Trojan/Shadowsocks require generated passwords, SSH-over-WebSocket requires a generated high-entropy password, and OpenVPN requires the generated client certificate/private key. SSH root login is disabled, only `xgcpx` can authenticate, and only local SSH forwarding is allowed. Use public endpoints only for authorized clients, and rotate exposed credentials.
- For SSH-over-WebSocket clients, install `websocat` locally and use the `ProxyCommand` printed by `deploy.sh`; it connects to the public gateway hostname on `/ssh-ws`, then the selected gateway proxies the WebSocket to the protocol VM's Caddy listener. This option is separate from SSH access to the VM's host OS.
- Proxy configurations provide WebSocket upgrade forwarding, gRPC/HTTP/2 routing, custom status headers, JSON access logs, and short-lived static asset caching. Caddy and Nginx failover retries are limited to safe/idempotent requests; proxy retries are not enabled for API writes. The Nginx and Envoy gateways require the primary/fallback HTTPS upstreams to share a hostname (for correct TLS SNI and Host routing). Set `UPSTREAM_PRIMARY` and `UPSTREAM_FALLBACK` to real HTTPS application URLs.
- Cloud Run accepts HTTP requests only. Raw TCP/TLS proxying belongs on the VM tier and requires explicit VM listener and firewall configuration. Cloud Armor's L7 policy does not inspect arbitrary TCP traffic; use network firewall rules and, where required, Cloud Armor Network Security for L4 protection.
- Cloud Run supports HTTP/1.1, HTTP/2, WebSockets, and gRPC over HTTP; the gateway routes selected protocol paths to the Xray sidecar in Cloud Run mode or to the protocol VM in hybrid mode. It does not expose raw UDP/TCP listeners for OpenVPN or SSH; OpenVPN remains on the separate VM public IP, while SSH-over-WebSocket is carried as HTTP and terminated by the Xray/SSH sidecar or protocol VM. The repository's legacy root `entrypoint.sh` is not used by this deployment.
- The VM tier is deployed behind the load balancer for HTTP traffic. It is not automatically a health-based fallback for Cloud Run: the load balancer routes `/persistent/*` explicitly to the VM. Configure the proxy upstream fallback variables when application-level failover is needed.
- Envoy additionally listens on VM ports 9000 (TCP) and 9443 (TLS passthrough). Deployment creates regional external TCP load balancers with stable IPs only when source CIDRs are provided; otherwise both listeners remain private. Update TCP/TLS upstreams before enabling them. Envoy's current HTTP failover TLS context uses the primary upstream's SNI, so primary and fallback should share a certificate name or be adjusted in the Envoy template.
- Cloud Armor and load balancer protection reduce risk but do not guarantee DDoS immunity. Review quotas, budgets, logging retention, and organization policy before production use.

## Component Responsibilities

| Component | Responsibility |
|---|---|
| `deploy.sh` | Validates project and required tools; collects gateway and protocol choices; generates credentials; stores protocol secrets; builds and pushes selected images; animates long-running terminal steps; and applies Terraform. |
| `Dockerfile` and `proxies/*/Dockerfile` | Package the unified gateway, selected Envoy/Nginx/Caddy/Traefik engine, and Xray/OpenSSH/OpenVPN runtime images for the VM or optional Cloud Run sidecar. |
| `proxies/caddy/Caddyfile` and `proxies/*` configs | `proxies/caddy/Caddyfile` is the canonical application-gateway Caddy config used by both root and Caddy Dockerfiles. Other proxy config files define their engine-specific routing. |
| `proxies/xray/entrypoint.sh` and `proxies/xray/sshd_config` | Retrieve the Xray config/optional SSH credential from Secret Manager, configure the non-root SSH account when enabled, and start Xray, Caddy, and the optional SSH daemon. |
| `proxies/xray/config.json` | Credential-free Xray template for VLESS WebSocket/HTTPUpgrade/gRPC, three xHTTP modes, Trojan WebSocket/HTTPUpgrade, VMess WebSocket, SSH-over-WebSocket, and Shadowsocks. `deploy.sh` filters inbounds to selected menu options and stores the rendered config and optional SSH credential in Secret Manager. |
| `proxies/openvpn/` | OpenVPN server image/config and Secret Manager-backed runtime entrypoint; `deploy.sh` generates the server identity and local client profile. |
| `entrypoint.sh` | Retains the legacy SSH/UDP relay startup sequence. The unified Caddy image now uses the explicit `caddy` binary entrypoint and does not execute this script. |
| `backend/` | Provides the Go JSON health/status/API sidecar on port 8081. `deploy.sh` builds it separately and Terraform starts it alongside the selected Cloud Run gateway. |
| `terraform/` | Creates Cloud Run, the gateway VM managed group, an optional protocol VM/static IP, an optional Xray Cloud Run sidecar identity, Secret Manager access, selected public port rules, Cloud Armor, and the global HTTPS load balancer. |
| `.dockerignore` | Excludes Git metadata, Terraform state/cache, logs, and local files from Docker build contexts, reducing build uploads and accidental file inclusion. |

## VM Tier and Free-Tier Notes

- `e2-micro` is a shared-core machine with 2 vCPUs and 1 GiB memory. It may qualify for the Compute Engine Always Free VM allowance only in `us-central1`, `us-west1`, or `us-east1`, subject to current account terms and monthly limits. On this tier each provisioned VM uses a 15 GB `pd-standard` boot disk, and the gateway autoscaler is capped at one replica; with the gateway VM plus an OpenVPN VM the combined disks total 30 GB. The remaining hybrid resources can still incur charges. Check current GCP terms and billing details before relying on free usage.
- `e2-small`, `e2-medium`, `c2-standard-4`, and `c2d-highcpu-8` are not Always Free VM tiers.
- Choosing `e2-micro` does not make the entire hybrid deployment free. The protocol endpoint is an additional Compute Engine VM, boot disk, and reserved IP; the stack also provisions global load balancing, Cloud Armor, Cloud Run, and network traffic. These resources can incur charges. Prices and eligibility vary by region and can change.
- The live region list intersects Cloud Run locations, Compute regions with status `UP`, and the selected VM-family inventory. Regional CPU quota is checked when available, but this does not promise zonal machine capacity or free-tier eligibility. Review quotas and configure budget alerts before applying.

## Connection Stability

- Caddy preserves WebSocket upgrades and uses `flush_interval -1` on API and persistent routes to avoid response buffering delay. Keep upstream health checks pointed at a lightweight endpoint.
- Nginx uses an upstream keepalive pool, HTTP/2, WebSocket upgrade mapping, TLS certificate validation, TCP keepalive, and 3600-second HTTP/gRPC timeouts. Align long-lived request timeouts with application and GCP limits; use application idempotency protection before retrying non-idempotent operations.
- Envoy's raw TCP/TLS listeners are VM-only and allow 24 hours of idle time. Firewall openings stay disabled unless explicit source CIDRs are provided; use the stable regional forwarding IPs and monitor TCP health checks.
- Cloud Run serves HTTP traffic only. The VM's raw TCP/TLS listeners provide the persistent connection path; the HTTPS load balancer and Cloud Armor L7 policy do not proxy arbitrary TCP sessions.
- The application gateway and native protocol service are separate workloads. A firewall rule alone permits packets but does not create a listener; the protocol VM image starts Caddy and Xray, validates the generated config before serving, and reads credentials only from Secret Manager.

## Build and Operations

Container builds use `.dockerignore`; Debian package installation is noninteractive. Do not copy secrets into Docker build context or image layers; use Secret Manager or runtime identity. Terraform state is stored in a project-owned GCS bucket with uniform access, public access prevention, and object versioning.

The region list uses the Cloud Run locations API and Compute Engine region/machine-type APIs for the active project. It checks regional CPU quota where exposed, but cannot predict live zonal capacity, organization policy, or all student/workspace restrictions; the Terraform plan is the final pre-apply diagnostic.

## Operations

Review `terraform/variables.tf`, especially the allow/deny CIDR lists, upstream destinations, rate limit, and protocol ports, before applying. `deploy.sh` keeps Cloud Run ingress restricted to the load balancer path; the protocol VM is a separate public endpoint.

Useful checks:

```sh
bash -n deploy.sh entrypoint.sh
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

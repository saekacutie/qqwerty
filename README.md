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

The script enables the required Google Cloud APIs before asking for deployment settings. It selects a gateway and protocol set, service name, region, and VM tier; accepts optional Cloud Armor IP deny/allow CIDRs; stores generated protocol credentials in Secret Manager; builds the selected gateway and supporting backend/protocol images; and applies Terraform. Region precedence is `--region`, `XGCPX_REGION`, `CLOUDSDK_COMPUTE_REGION`, then `gcloud config get-value compute/region`. If none is set, the region menu shows location descriptions and country flags; it does not guess the operator's physical location. The application-upstream prompt is optional: blank selects the built-in Cloud Run API sidecar at `127.0.0.1:8081`; a supplied external HTTPS upstream is used instead. All gateway images proxy application paths to the configured upstream. The `/persistent/*` load-balancer route uses the VM only when a real external application upstream is configured; with the built-in backend it remains on Cloud Run, avoiding a VM proxy to a sidecar that does not exist on the VM. The Cloud Run service and HTTPS forwarding route are provisioned before the protocol VM. `XGCPX_PROTOCOLS=all` or a comma-separated selection such as `1,3,4,6` can drive the protocol menu. Selection `6` enables OpenVPN; `all`/`5` enables every protocol. Selected ports are opened to public IPv4 sources. OpenVPN uses UDP 1194 on the protocol VM's static public IP and certificate authentication; it cannot be relayed through a Cloud Run URL. The generated client profile is written locally with mode `0600` and excluded from Git and Docker build contexts. The script's animated progress indicators run only in interactive terminals; they report deployment progress and do not run inside Cloud Run. Create A records for the load-balancer hostname and relay hostname using their separately printed IPs. Caddy obtains the relay certificate after DNS resolves; certificate provisioning may take several minutes.

The deploy script does not create GitHub repositories or push source code. Manage repository remotes and commits separately from infrastructure deployment.

## Architecture and protocol boundaries

- The global external Application Load Balancer terminates TLS, provides HTTP/2 and HTTP/3 to clients, and applies Cloud Armor WAF, IP rules, and rate limits.
- Requests go to a Cloud Run serverless NEG. `/persistent/*` routes to the VM managed instance group only when an external HTTPS application upstream is configured; otherwise it stays on Cloud Run.
- Cloud Run runs the selected HTTP proxy and a small built-in Go API sidecar on a shared instance network. With no external upstream, `/healthz`, `/status`, and JSON responses are served by that sidecar. It is a connectivity/control-plane placeholder, not a production app or WebSocket/gRPC server. Use an application upstream that implements WebSocket or gRPC for those protocols. The gateway hostname is never used as its own upstream, avoiding an HTTP proxy loop.
- A separate Compute Engine VM with a reserved public IP serves the selected native protocol inbounds. Cloud Run and its load-balancer IP continue serving the application gateway; the relay VM uses `relay.<your-domain>`. It is not a Cloud Run listener and its public firewall rules are not protected by Cloud Armor L7.
- The protocol VM runs Xray behind Caddy TLS termination: VLESS WebSocket and HTTPUpgrade on TLS 443; gRPC on TLS 443 and 50051; xHTTP packet-up, stream-up, and stream-one on TLS 443 and 8080; and authenticated Shadowsocks on TCP/UDP 8388. Selection 5 / `all` enables each. The 80/TCP listener supports HTTP-to-HTTPS redirects and ACME certificate issuance.
- When selected, a separate OpenVPN container runs on the same protocol VM and static IP on UDP 1194. It uses a generated CA, client/server certificates, a `tls-crypt` key, and full-tunnel IPv4 routing with NAT; its server private key stays in Secret Manager and the client profile is written to a mode-0600 local `.ovpn` file. OpenVPN is not hosted by Cloud Run.
- Xray 26.10.31 accepts all configured transports, but warns that WebSocket, HTTPUpgrade, gRPC, and Shadowsocks are deprecated upstream; Shadowsocks also lacks forward secrecy. They remain available to satisfy the compatibility menu, while xHTTP is the preferred option for new clients. Review upstream Xray release notes before upgrades.
- Xray configuration is generated from `proxies/xray/config.json` using fresh VLESS UUID and Shadowsocks password values. The rendered configuration is stored in Secret Manager; the VM service account can read that single secret. Credentials are shown once in deploy output—store them securely.
- Public ingress is deliberately enabled for selected protocol ports as requested. This makes the VM reachable from any IPv4 source, but it does not make the protocol listeners anonymous: VLESS and Shadowsocks require generated credentials, and OpenVPN requires the client certificate/private key in the generated profile. Use the VM IP/DNS only for your own authorized clients, and rotate credentials if they are exposed.
- Proxy configurations provide WebSocket upgrade forwarding, gRPC/HTTP/2 routing, custom status headers, JSON access logs, and short-lived static asset caching. Caddy and Nginx failover retries are limited to safe/idempotent requests; proxy retries are not enabled for API writes. The Nginx and Envoy gateways require the primary/fallback HTTPS upstreams to share a hostname (for correct TLS SNI and Host routing). Set `UPSTREAM_PRIMARY` and `UPSTREAM_FALLBACK` to real HTTPS application URLs.
- Cloud Run accepts HTTP requests only. Raw TCP/TLS proxying belongs on the VM tier and requires explicit VM listener and firewall configuration. Cloud Armor's L7 policy does not inspect arbitrary TCP traffic; use network firewall rules and, where required, Cloud Armor Network Security for L4 protection.
- Cloud Run supports HTTP/1.1, HTTP/2, WebSockets, and gRPC over HTTP when an application upstream implements those protocols. It does not expose arbitrary UDP/TCP listeners for OpenVPN or SSH tunnels; adding a URL path cannot add those transport capabilities. OpenVPN remains on the separate VM public IP and cannot be relayed through the Cloud Run URL, including when OpenVPN is the only selected protocol.
- The VM tier is deployed behind the load balancer for HTTP traffic. It is not automatically a health-based fallback for Cloud Run: the load balancer routes `/persistent/*` explicitly to the VM. Configure the proxy upstream fallback variables when application-level failover is needed.
- Envoy additionally listens on VM ports 9000 (TCP) and 9443 (TLS passthrough). The setup creates regional external TCP load balancers with stable IPs only when source CIDRs are provided; otherwise both listeners remain private. Update TCP/TLS upstreams before enabling them. Envoy's current HTTP failover TLS context uses the primary upstream's SNI, so primary and fallback should share a certificate name or be adjusted in the Envoy template.
- Cloud Armor and load balancer protection reduce risk but do not guarantee DDoS immunity. Review quotas, budgets, logging retention, and organization policy before production use.

## Component Responsibilities

| Component | Responsibility |
|---|---|
| `deploy.sh` | Validates project and required tools; collects gateway and protocol choices; generates credentials; stores protocol secrets; builds and pushes selected images; animates long-running terminal steps; and applies Terraform. |
| `Dockerfile` and `proxies/*/Dockerfile` | Package the unified gateway, selected Envoy/Nginx/Caddy/Traefik engine, and separate authenticated Xray/OpenVPN protocol services. |
| `proxies/caddy/Caddyfile` and `proxies/*` configs | `proxies/caddy/Caddyfile` is the canonical application-gateway Caddy config used by both root and Caddy Dockerfiles. Other proxy config files define their engine-specific routing. |
| `proxies/xray/config.json` | Credential-free Xray template for VLESS WebSocket/HTTPUpgrade/gRPC, three xHTTP modes, and Shadowsocks. `deploy.sh` filters inbounds to the selected menu options and stores the rendered config in Secret Manager. |
| `proxies/openvpn/` | OpenVPN server image/config and Secret Manager-backed runtime entrypoint; `deploy.sh` generates the server identity and local client profile. |
| `entrypoint.sh` | Retains the legacy SSH/UDP relay startup sequence. The unified Caddy image now uses the explicit `caddy` binary entrypoint and does not execute this script. |
| `backend/` | Provides the Go JSON health/status/API sidecar on port 8081. `deploy.sh` builds it separately and Terraform starts it alongside the selected Cloud Run gateway. |
| `terraform/` | Creates Cloud Run, the gateway VM managed group, the dedicated protocol VM and static IP, Secret Manager access, selected public port rules, Cloud Armor, and the global HTTPS load balancer. |
| `.dockerignore` | Excludes Git metadata, Terraform state/cache, logs, and local files from Docker build contexts, reducing build uploads and accidental file inclusion. |

## VM Tier and Free-Tier Notes

- `e2-micro` is a shared-core machine with 2 vCPUs and 1 GiB memory. It may qualify for the Compute Engine Always Free allowance only in currently eligible US regions and within current monthly usage limits and account terms. Check the current GCP Free Tier terms and project billing details before relying on this allowance.
- `e2-small`, `e2-medium`, `c2-standard-4`, and `c2d-highcpu-8` are not Always Free VM tiers.
- Choosing `e2-micro` does not make the entire hybrid deployment free. The protocol endpoint is an additional Compute Engine VM, boot disk, and reserved IP; the stack also provisions global load balancing, Cloud Armor, Cloud Run, and network traffic. These resources can incur charges. Prices and eligibility vary by region and can change.
- The region list reports regions with status `UP`; it does not promise VM family capacity, quota, or free-tier eligibility. Review quotas and configure budget alerts before applying.

## Connection Stability

- Caddy preserves WebSocket upgrades and uses `flush_interval -1` on API and persistent routes to avoid response buffering delay. Keep upstream health checks pointed at a lightweight endpoint.
- Nginx uses an upstream keepalive pool, HTTP/2, WebSocket upgrade mapping, TLS certificate validation, TCP keepalive, and 3600-second HTTP/gRPC timeouts. Align long-lived request timeouts with application and GCP limits; use application idempotency protection before retrying non-idempotent operations.
- Envoy's raw TCP/TLS listeners are VM-only and allow 24 hours of idle time. Firewall openings stay disabled unless explicit source CIDRs are provided; use the stable regional forwarding IPs and monitor TCP health checks.
- Cloud Run serves HTTP traffic only. The VM's raw TCP/TLS listeners provide the persistent connection path; the HTTPS load balancer and Cloud Armor L7 policy do not proxy arbitrary TCP sessions.
- The application gateway and native protocol service are separate workloads. A firewall rule alone permits packets but does not create a listener; the protocol VM image starts Caddy and Xray, validates the generated config before serving, and reads credentials only from Secret Manager.

## Build and Operations

Container builds use `.dockerignore`; Debian package installation is noninteractive. Do not copy secrets into Docker build context or image layers; use Secret Manager or runtime identity. Terraform state is stored in a project-owned GCS bucket with uniform access, public access prevention, and object versioning.

The region list comes from `gcloud compute regions list`; it identifies active GCP regions, not project-specific quota or capacity. The VM tier menu maps directly to the requested machine families.

## Operations

Review `terraform/variables.tf`, especially the allow/deny CIDR lists, upstream destinations, rate limit, and protocol ports, before applying. `deploy.sh` keeps Cloud Run ingress restricted to the load balancer path; the protocol VM is a separate public endpoint.

Useful checks:

```sh
bash -n deploy.sh entrypoint.sh
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

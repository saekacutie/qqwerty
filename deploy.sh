#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly APP_NAME="xgcpx"
readonly DEFAULT_SERVICE="api-gateway-404"
if [[ -t 1 && "${TERM:-}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
  readonly RED=$'\033[0;31m' GREEN=$'\033[0;32m' CYAN=$'\033[0;36m'
  readonly YELLOW=$'\033[0;33m' BLUE=$'\033[0;34m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
  readonly RED="" GREEN="" CYAN="" YELLOW="" BLUE="" BOLD="" RESET=""
fi
PROTOCOL_CONFIG_FILE=""
OPENVPN_SECRET_FILE=""
OPENVPN_PKI_DIR=""
TERRAFORM_PLAN_FILE=""

info() { printf '%s==>%s %s\n' "$CYAN" "$RESET" "$*"; }
success() { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%s✗ ERROR%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
section() {
  printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$BLUE" "$RESET"
  printf '%s%s %s%s\n' "$BOLD" "$BLUE" "$*" "$RESET"
  printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$BLUE" "$RESET"
}
validate_https_upstream() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

try:
    parsed = urlsplit(sys.argv[1])
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or "@" in parsed.netloc
        or parsed.query
        or parsed.fragment
        or "?" in sys.argv[1]
        or "#" in sys.argv[1]
    ):
        raise ValueError
    if parsed.port is not None and not 1 <= parsed.port <= 65535:
        raise ValueError
except ValueError:
    raise SystemExit(1)
PY
}
# Animate long deployment steps only in interactive terminals, and preserve command output.
run_with_spinner() {
  local label="$1" output_file status=0 frame=0
  shift
  if [[ ! -t 1 || ! -t 2 || "${TERM:-}" == "dumb" || -n "${NO_COLOR:-}" ]]; then
    info "$label"
    if "$@"; then
      success "$label"
      return 0
    else
      status=$?
      printf '%sERROR%s %s failed (exit %s).\n' "$RED" "$RESET" "$label" "$status" >&2
      return "$status"
    fi
  fi

  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  output_file="$(mktemp)"
  "$@" >"$output_file" 2>&1 &
  local command_pid=$!
  while jobs -pr | grep -Fxq "$command_pid"; do
    printf '\r%s%s%s %s' "$CYAN" "${frames[$frame]}" "$RESET" "$label"
    frame=$(((frame + 1) % ${#frames[@]}))
    sleep 0.12
  done
  wait "$command_pid" || status=$?
  printf '\r\033[K'
  if ((status == 0)); then
    success "$label"
    tail -n 8 "$output_file"
  else
    printf "${RED}ERROR${RESET} %s failed:\n" "$label" >&2
    cat "$output_file" >&2
  fi
  rm -f -- "$output_file"
  return "$status"
}
# Include the failing source line and command when strict-mode execution aborts.
on_error() { printf "${RED}ERROR${RESET} deploy failed at line %s (command: %s)\n" "$1" "$2" >&2; }
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
cleanup() {
  if [[ -n "$PROTOCOL_CONFIG_FILE" ]]; then rm -f -- "$PROTOCOL_CONFIG_FILE"; fi
  if [[ -n "$OPENVPN_SECRET_FILE" ]]; then rm -f -- "$OPENVPN_SECRET_FILE"; fi
  if [[ -n "$OPENVPN_PKI_DIR" ]]; then rm -rf -- "$OPENVPN_PKI_DIR"; fi
  if [[ -n "$TERRAFORM_PLAN_FILE" ]]; then rm -f -- "$TERRAFORM_PLAN_FILE"; fi
}
trap cleanup EXIT

REGION_HINT="${XGCPX_REGION:-${CLOUDSDK_COMPUTE_REGION:-}}"
REGION_HINT_SOURCE="environment"
CLI_REGION=""
while (($# > 0)); do
  case "$1" in
    --region)
      (($# >= 2)) || fail "--region requires a region name."
      CLI_REGION="$2"
      shift 2
      ;;
    --region=*)
      CLI_REGION="${1#--region=}"
      [[ -n "$CLI_REGION" ]] || fail "--region requires a region name."
      shift
      ;;
    --help|-h)
      printf 'Usage: %s [--region REGION]\n' "$0"
      printf 'Region precedence: --region, XGCPX_REGION, CLOUDSDK_COMPUTE_REGION, gcloud compute/region.\n'
      exit 0
      ;;
    *)
      fail "Unknown argument: $1 (use --help for usage)."
      ;;
  esac
done
if [[ -n "$CLI_REGION" ]]; then
  REGION_HINT="$CLI_REGION"
  REGION_HINT_SOURCE="--region"
fi

for tool in gcloud docker terraform python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done

PROJECT_ID="$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || fail "No active project. Run 'gcloud config set project PROJECT_ID'."
ACTIVE_ACCOUNT="$(gcloud config get-value account 2>/dev/null | tr -d '[:space:]')"
[[ -n "$ACTIVE_ACCOUNT" && "$ACTIVE_ACCOUNT" != "(unset)" ]] || fail "No active gcloud account. Authenticate with gcloud."
if ! gcloud auth print-access-token --account="$ACTIVE_ACCOUNT" >/dev/null 2>&1; then
  fail "The active gcloud account cannot obtain an access token. Re-authenticate with 'gcloud auth login' and confirm this account has access to project ${PROJECT_ID}."
fi

printf '\n%s\n' "xgcpx | GCP Gateway Deployment"
printf 'Project: %s | Account: %s\n\n' "$PROJECT_ID" "$ACTIVE_ACCOUNT"

# Enable APIs before project, billing, region, or Terraform preflight checks.
section "PREFLIGHT  |  Enable required Google Cloud APIs"
REQUIRED_APIS=(
  serviceusage.googleapis.com
  cloudresourcemanager.googleapis.com
  compute.googleapis.com
  run.googleapis.com
  artifactregistry.googleapis.com
  iam.googleapis.com
  logging.googleapis.com
  storage.googleapis.com
  secretmanager.googleapis.com
  cloudbilling.googleapis.com
)
if ! run_with_spinner "Enable required APIs in ${PROJECT_ID}" \
  gcloud services enable "${REQUIRED_APIS[@]}" --project="$PROJECT_ID" --quiet; then
  fail "Required APIs could not be enabled. Grant serviceusage.services.enable (typically roles/serviceusage.serviceUsageAdmin) and check organization policy."
fi

if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  [[ -r "$GOOGLE_APPLICATION_CREDENTIALS" ]] \
    || fail "GOOGLE_APPLICATION_CREDENTIALS is set but unreadable: ${GOOGLE_APPLICATION_CREDENTIALS}"
  if ! python3 - "$GOOGLE_APPLICATION_CREDENTIALS" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as credentials_file:
        credentials = json.load(credentials_file)
except (OSError, ValueError):
    raise SystemExit(1)
if not isinstance(credentials, dict) or credentials.get("type") not in {
    "service_account", "authorized_user", "external_account", "impersonated_service_account"
}:
    raise SystemExit(1)
PY
  then
    fail "GOOGLE_APPLICATION_CREDENTIALS is not a valid Google ADC JSON credentials file."
  fi
elif ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  fail "Terraform has no Application Default Credentials (ADC). Run 'gcloud auth application-default login' or set GOOGLE_APPLICATION_CREDENTIALS to a valid credential file. The gcloud login and Terraform ADC are separate."
fi

PROJECT_STATUS="$(gcloud projects describe "$PROJECT_ID" --format='value(lifecycleState)' 2>/dev/null)" \
  || fail "Cannot read project ${PROJECT_ID}. Check the project ID, gcloud account, and resourcemanager.projects.get permission."
[[ "$PROJECT_STATUS" == "ACTIVE" ]] || fail "Project ${PROJECT_ID} is not ACTIVE (state: ${PROJECT_STATUS:-unknown})."

if ! BILLING_STATUS="$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null)"; then
  fail "Cannot verify billing for ${PROJECT_ID}. Ensure Cloud Billing API is enabled and this account has billing.resourceAssociations.get permission."
fi
[[ "$BILLING_STATUS" == "True" || "$BILLING_STATUS" == "true" ]] \
  || fail "Billing is not enabled for ${PROJECT_ID}. Link an active billing account before deploying Cloud Run, Compute Engine, load balancing, or Cloud Armor."

if [[ -z "$REGION_HINT" ]]; then
  configured_region="$(gcloud config get-value compute/region 2>/dev/null || true)"
  if [[ -n "$configured_region" && "$configured_region" != "(unset)" ]]; then
    REGION_HINT="$configured_region"
    REGION_HINT_SOURCE="gcloud config"
  fi
fi

section "GATEWAY  |  Select the Cloud Run HTTP proxy"
printf '%s\n' "1) Envoy" "2) Nginx" "3) Caddy" "4) Traefik" "5) Unified Gateway (Caddy)"
read -r -p "Gateway service [1-5, default 5]: " GATEWAY_CHOICE
case "${GATEWAY_CHOICE:-5}" in
  1) GATEWAY="envoy"; DOCKERFILE="proxies/envoy/Dockerfile" ;;
  2) GATEWAY="nginx"; DOCKERFILE="proxies/nginx/Dockerfile" ;;
  3) GATEWAY="caddy"; DOCKERFILE="proxies/caddy/Dockerfile" ;;
  4) GATEWAY="traefik"; DOCKERFILE="proxies/traefik/Dockerfile" ;;
  5) GATEWAY="unified"; DOCKERFILE="Dockerfile" ;;
  *) fail "Choose a gateway from 1 to 5." ;;
esac
info "Selected ${GATEWAY} gateway; the image will be built from ${DOCKERFILE}."

# The separate static-IP VM serves native protocols; Cloud Run remains HTTP(S)-only.
section "PROTOCOLS  |  Select services for the separate protocol VM"
printf '\n%s\n' \
  "Protocol services (separate VM IP):" \
  "1) VLESS over WebSocket and HTTPUpgrade (TLS via Caddy on 443)" \
  "2) VLESS gRPC over TLS (443 and 50051)" \
  "3) VLESS xHTTP packet-up, stream-up, and stream-one (443 and 8080)" \
  "4) Shadowsocks TCP and UDP (8388)" \
  "5) All protocol services" \
  "6) OpenVPN over UDP (1194; VM public IP only, never Cloud Run)"
PROTOCOL_SELECTION="${XGCPX_PROTOCOLS:-}"
if [[ -z "$PROTOCOL_SELECTION" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Protocols [1-4, 6, comma-separated, or all; default all]: " PROTOCOL_SELECTION
  fi
  PROTOCOL_SELECTION="${PROTOCOL_SELECTION:-all}"
fi
PROTOCOL_SELECTION="${PROTOCOL_SELECTION,,}"
PROTOCOL_SELECTION="${PROTOCOL_SELECTION//[[:space:]]/}"
[[ "$PROTOCOL_SELECTION" =~ ^(all|5|[1-46](,[1-46])*)$ ]] || fail "Choose all, 5, 6, or comma-separated selections from 1 to 4 and 6."

PROTOCOL_OPTIONS=()
if [[ "$PROTOCOL_SELECTION" == "all" || "$PROTOCOL_SELECTION" == "5" ]]; then
  PROTOCOL_OPTIONS=(1 2 3 4 6)
else
  IFS=',' read -r -a PROTOCOL_OPTIONS <<< "$PROTOCOL_SELECTION"
fi
PROTOCOL_TCP_PORTS=(80 443)
PROTOCOL_UDP_PORTS=()
PROTOCOL_TAGS=()
ENABLE_OPENVPN=false
SEEN_PROTOCOLS=" "
for protocol in "${PROTOCOL_OPTIONS[@]}"; do
  [[ "$SEEN_PROTOCOLS" != *" $protocol "* ]] || fail "Protocol selections must not contain duplicates."
  SEEN_PROTOCOLS+="${protocol} "
  case "$protocol" in
    1) PROTOCOL_TAGS+=(vless-ws vless-httpupgrade) ;;
    2) PROTOCOL_TAGS+=(vless-grpc); PROTOCOL_TCP_PORTS+=(50051) ;;
    3) PROTOCOL_TAGS+=(xhttp-packet xhttp-chunked xhttp-request-response); PROTOCOL_TCP_PORTS+=(8080) ;;
    4) PROTOCOL_TAGS+=(shadowsocks); PROTOCOL_TCP_PORTS+=(8388); PROTOCOL_UDP_PORTS+=(8388) ;;
    6) ENABLE_OPENVPN=true; PROTOCOL_UDP_PORTS+=(1194) ;;
  esac
done
if [[ ${#PROTOCOL_OPTIONS[@]} -eq 1 && "${PROTOCOL_OPTIONS[0]}" == "6" ]]; then
  warn "OpenVPN-only still deploys its UDP listener on the protocol VM; Cloud Run cannot relay UDP."
fi
if [[ "$ENABLE_OPENVPN" == "true" ]]; then
  command -v openssl >/dev/null 2>&1 || fail "OpenVPN certificate generation requires openssl."
fi
read -r -p "Service name [${DEFAULT_SERVICE}]: " SERVICE_NAME
SERVICE_NAME="${SERVICE_NAME:-$DEFAULT_SERVICE}"
[[ "$SERVICE_NAME" =~ ^[a-z]([-a-z0-9]{0,47}[a-z0-9])?$ ]] || fail "Invalid Cloud Run service name: $SERVICE_NAME"

section "COMPUTE  |  Select the VM tier"
printf '\n%s\n' "Compute tier:" "1) e2-micro" "2) e2-small" "3) e2-medium" "4) c2-standard-4" "5) c2d-highcpu-8"
read -r -p "VM tier [1-5, default 2]: " TIER_CHOICE
case "${TIER_CHOICE:-2}" in
  1) MACHINE_TYPE="e2-micro" ;;
  2) MACHINE_TYPE="e2-small" ;;
  3) MACHINE_TYPE="e2-medium" ;;
  4) MACHINE_TYPE="c2-standard-4" ;;
  5) MACHINE_TYPE="c2d-highcpu-8" ;;
  *) fail "Choose a compute tier from 1 to 5." ;;
esac
info "Selected VM machine type: ${MACHINE_TYPE}."
if [[ "$MACHINE_TYPE" == "e2-micro" ]]; then
  warn "e2-micro is a shared-core 2-vCPU, 1-GiB VM; it may qualify for Always Free only in eligible US regions and within current monthly limits."
  warn "The protocol gateway is an additional VM. This stack also includes disks, load balancers, Cloud Armor, Cloud Run, and network egress that may incur charges."
else
  warn "${MACHINE_TYPE} is not an Always Free VM tier; check current GCP pricing and quotas before deployment."
fi

section "LOCATION  |  Select a Compute Engine region"
info "Checking Cloud Run support, active Compute Engine regions, and ${MACHINE_TYPE} availability for ${PROJECT_ID}"
if ! RUN_REGION_JSON="$(gcloud run regions list --project="$PROJECT_ID" --format=json)"; then
  fail "Cannot query Cloud Run region support. Check run.locations.list permission, the Cloud Run API, and gcloud SDK version."
fi
if ! COMPUTE_REGION_JSON="$(gcloud compute regions list --project="$PROJECT_ID" --filter='status=UP' --format=json)"; then
  fail "Cannot query active Compute Engine regions. Check compute.regions.list permission and the Compute Engine API."
fi
if ! MACHINE_TYPE_JSON="$(gcloud compute machine-types list --project="$PROJECT_ID" --filter="name=${MACHINE_TYPE}" --format=json)"; then
  fail "Cannot query ${MACHINE_TYPE} availability. Check compute.machineTypes.list permission and the Compute Engine API."
fi
REGION_ROWS="$(python3 -c '
import json
import re
import sys
run_regions, compute_regions, machine_types = map(json.loads, sys.argv[1:])
def location_name(resource):
    if isinstance(resource, str):
        return resource.rsplit("/locations/", 1)[-1]
    if not isinstance(resource, dict):
        return ""
    for key in ("locationId", "name", "uri"):
        value = resource.get(key, "")
        if "/locations/" in value:
            return value.rsplit("/locations/", 1)[1]
        if value and "/" not in value:
            return value
    return ""
run_names = {location_name(item) for item in run_regions}
compute_by_name = {
    item.get("name", ""): item
    for item in compute_regions
    if item.get("status") == "UP"
}
machine_regions = set()
for item in machine_types:
    zone = item.get("zone") or item.get("selfLink", "")
    match = re.search(r"/zones/([^/]+)", zone)
    if match:
        zone = match.group(1)
    if zone:
        machine_regions.add(zone.rsplit("-", 1)[0])
for name in sorted(run_names & compute_by_name.keys() & machine_regions):
    region = compute_by_name[name]
    description = region.get("description") or name
    print(name + "\t" + description)
' "$RUN_REGION_JSON" "$COMPUTE_REGION_JSON" "$MACHINE_TYPE_JSON")" \
  || fail "Unable to parse the live Cloud Run, Compute Engine, and machine-type region responses."
REGIONS=()
if [[ -n "$REGION_ROWS" ]]; then mapfile -t REGIONS <<<"$REGION_ROWS"; fi
((${#REGIONS[@]} > 0)) || fail "No region currently satisfies all three checks: Cloud Run support, Compute Engine region status UP, and ${MACHINE_TYPE} listed for this project."
region_flag() {
  case "$1" in
    us-central1*) printf '🇺🇸 Iowa, USA' ;;
    us-east1*) printf '🇺🇸 South Carolina, USA' ;;
    us-east4*) printf '🇺🇸 Northern Virginia, USA' ;;
    us-east5*) printf '🇺🇸 Columbus, USA' ;;
    us-south1*) printf '🇺🇸 Dallas, USA' ;;
    us-west1*) printf '🇺🇸 Oregon, USA' ;;
    us-west2*) printf '🇺🇸 Los Angeles, USA' ;;
    us-west3*) printf '🇺🇸 Salt Lake City, USA' ;;
    us-west4*) printf '🇺🇸 Las Vegas, USA' ;;
    northamerica-northeast1*) printf '🇨🇦 Montreal, Canada' ;;
    northamerica-northeast2*) printf '🇨🇦 Toronto, Canada' ;;
    northamerica-south1*) printf '🇲🇽 Mexico' ;;
    southamerica-east1*) printf '🇧🇷 Sao Paulo, Brazil' ;;
    southamerica-west1*) printf '🇨🇱 Santiago, Chile' ;;
    europe-west1*) printf '🇧🇪 Belgium' ;;
    europe-west2*) printf '🇬🇧 London, UK' ;;
    europe-west3*) printf '🇩🇪 Frankfurt, Germany' ;;
    europe-west4*) printf '🇳🇱 Netherlands' ;;
    europe-west6*) printf '🇨🇭 Zurich, Switzerland' ;;
    europe-west8*) printf '🇮🇹 Milan, Italy' ;;
    europe-west9*) printf '🇫🇷 Paris, France' ;;
    europe-west10*) printf '🇩🇪 Berlin, Germany' ;;
    europe-west12*) printf '🇮🇹 Turin, Italy' ;;
    europe-north1*) printf '🇫🇮 Finland' ;;
    europe-north2*) printf '🇸🇪 Stockholm, Sweden' ;;
    europe-central2*) printf '🇵🇱 Warsaw, Poland' ;;
    europe-southwest1*) printf '🇪🇸 Madrid, Spain' ;;
    asia-east1*) printf '🇹🇼 Taiwan' ;;
    asia-east2*) printf '🇭🇰 Hong Kong' ;;
    asia-northeast1*) printf '🇯🇵 Tokyo, Japan' ;;
    asia-northeast2*) printf '🇯🇵 Osaka, Japan' ;;
    asia-northeast3*) printf '🇰🇷 Seoul, South Korea' ;;
    asia-south1*) printf '🇮🇳 Mumbai, India' ;;
    asia-south2*) printf '🇮🇳 Delhi, India' ;;
    asia-south3*) printf '🇮🇳 India' ;;
    asia-southeast1*) printf '🇸🇬 Singapore' ;;
    asia-southeast2*) printf '🇮🇩 Jakarta, Indonesia' ;;
    asia-southeast3*) printf '🇹🇭 Bangkok, Thailand' ;;
    australia-southeast1*) printf '🇦🇺 Sydney, Australia' ;;
    australia-southeast2*) printf '🇦🇺 Melbourne, Australia' ;;
    me-central1*) printf '🇶🇦 Doha, Qatar' ;;
    me-central2*) printf '🇸🇦 Dammam, Saudi Arabia' ;;
    me-west1*) printf '🇮🇱 Tel Aviv, Israel' ;;
    africa-south1*) printf '🇿🇦 Johannesburg, South Africa' ;;
    *) printf '🌐 %s' "$2" ;;
  esac
}
region_name() { printf '%s' "${1%%$'\t'*}"; }
region_description() { printf '%s' "${1#*$'\t'}"; }
for index in "${!REGIONS[@]}"; do
  region="$(region_name "${REGIONS[$index]}")"
  description="$(region_description "${REGIONS[$index]}")"
  printf '  %2d) %-24s %-20s %s\n' "$((index + 1))" "$region" "$(region_flag "$region" "$description")" "$description"
done

REGION=""
if [[ -n "$REGION_HINT" ]]; then
  for row in "${REGIONS[@]}"; do
    if [[ "$(region_name "$row")" == "$REGION_HINT" ]]; then REGION="$REGION_HINT"; break; fi
  done
  if [[ -n "$REGION" ]]; then
    info "Auto-selected ${REGION} from ${REGION_HINT_SOURCE} ($(region_flag "$REGION" "$REGION"))."
  elif [[ "$REGION_HINT_SOURCE" == "--region" || "$REGION_HINT_SOURCE" == "environment" ]]; then
    fail "Configured region '${REGION_HINT}' is not in the live Cloud Run + Compute + ${MACHINE_TYPE} availability set for project ${PROJECT_ID}."
  else
    warn "Configured gcloud region '${REGION_HINT}' is not active; choose an available region below."
  fi
fi
if [[ -z "$REGION" ]]; then
  REGION_DEFAULT_INDEX=-1
  for index in "${!REGIONS[@]}"; do
    if [[ "$(region_name "${REGIONS[$index]}")" == "us-central1" ]]; then REGION_DEFAULT_INDEX="$index"; break; fi
  done
  if [[ -t 0 ]]; then
    if (( REGION_DEFAULT_INDEX < 0 )); then REGION_DEFAULT_INDEX=0; fi
    info "No region is configured in gcloud; choose a region. The default is a fallback, not a location estimate."
    read -r -p "Region [1-${#REGIONS[@]}, default $((REGION_DEFAULT_INDEX + 1))]: " REGION_CHOICE
    REGION_CHOICE="${REGION_CHOICE:-$((REGION_DEFAULT_INDEX + 1))}"
    [[ "$REGION_CHOICE" =~ ^[0-9]+$ ]] && (( REGION_CHOICE >= 1 && REGION_CHOICE <= ${#REGIONS[@]} )) || fail "Select a listed region number."
    REGION="$(region_name "${REGIONS[$((REGION_CHOICE - 1))]}")"
  elif (( REGION_DEFAULT_INDEX >= 0 )); then
    REGION="us-central1"
    warn "No region is configured; using us-central1. Set XGCPX_REGION or pass --region to choose another location."
  else
    fail "No region is configured and us-central1 is unavailable. Set XGCPX_REGION, CLOUDSDK_COMPUTE_REGION, or pass --region."
  fi
fi

case "$MACHINE_TYPE" in
  e2-*) VCPU_COUNT=2; FAMILY_CPU_QUOTA="E2_CPUS" ;;
  c2-standard-4) VCPU_COUNT=4; FAMILY_CPU_QUOTA="C2_CPUS" ;;
  c2d-highcpu-8) VCPU_COUNT=8; FAMILY_CPU_QUOTA="C2D_CPUS" ;;
esac
MINIMUM_VCPU_QUOTA=$((VCPU_COUNT * 2))
RECOMMENDED_VCPU_QUOTA=$((VCPU_COUNT * 4))
if ! REGION_QUOTA_JSON="$(gcloud compute regions describe "$REGION" --project="$PROJECT_ID" --format=json)"; then
  fail "Cannot inspect regional quotas for ${REGION}. Check compute.regions.get permission."
fi
QUOTA_REPORT=""
quota_status=0
if QUOTA_REPORT="$(python3 - "$REGION_QUOTA_JSON" "$FAMILY_CPU_QUOTA" "$MINIMUM_VCPU_QUOTA" "$RECOMMENDED_VCPU_QUOTA" <<'PY'
import json
import sys

region = json.loads(sys.argv[1])
family_metric = sys.argv[2]
minimum = float(sys.argv[3])
recommended = float(sys.argv[4])
quotas = {item["metric"]: item for item in region.get("quotas", [])}
metrics = [metric for metric in (family_metric, "CPUS") if metric in quotas]
if not metrics:
    print("UNKNOWN\tNo family-specific or aggregate CPU quota was returned.")
    raise SystemExit(0)
insufficient = False
below_recommended = False
for metric in metrics:
    quota = quotas[metric]
    limit = float(quota.get("limit", 0))
    usage = float(quota.get("usage", 0))
    available = max(0, limit - usage)
    print(f"{metric}\t{available:g}\t{limit:g}\t{usage:g}")
    insufficient |= available < minimum
    below_recommended |= available < recommended
if insufficient:
    raise SystemExit(2)
if below_recommended:
    raise SystemExit(3)
PY
)"; then
  quota_status=0
else
  quota_status=$?
fi
if ((quota_status == 0)); then
  while IFS=$'\t' read -r metric available limit usage; do
    if [[ "$metric" == "UNKNOWN" ]]; then
      warn "Regional CPU quota was not returned by the API; Terraform plan is still required to confirm account eligibility."
    else
      info "Regional quota ${metric}: ${available} CPU(s) free of ${limit} (${usage} in use)."
    fi
  done <<<"$QUOTA_REPORT"
else
  if ((quota_status == 2)); then
    printf '%s\n' "$QUOTA_REPORT" >&2
    fail "Current ${REGION} CPU quota is below the ${MINIMUM_VCPU_QUOTA} vCPU minimum for the gateway and protocol VMs. Request quota in Cloud Console or choose a smaller eligible tier."
  elif ((quota_status == 3)); then
    while IFS=$'\t' read -r metric available limit usage; do
      info "Regional quota ${metric}: ${available} CPU(s) free of ${limit} (${usage} in use)."
    done <<<"$QUOTA_REPORT"
    warn "Quota supports the initial two VMs but not the ${RECOMMENDED_VCPU_QUOTA} vCPU recommended for full gateway autoscaling."
  else
    fail "Unable to evaluate regional CPU quotas (status ${quota_status})."
  fi
fi
info "Quota check covers the initial two VMs; it cannot guarantee future zonal capacity or organization-policy approval."

section "APPLICATION  |  Configure the HTTPS hostname and upstream"
read -r -p "Hostname for managed HTTPS certificate (e.g. api.example.com): " DOMAIN
[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || fail "Enter a valid DNS hostname."
RELAY_DOMAIN="relay.${DOMAIN}"
(( ${#RELAY_DOMAIN} <= 253 )) || fail "The generated protocol hostname exceeds the DNS name length limit."
info "Cloud Run serves HTTP(S), WebSocket, and gRPC-over-HTTP routes; OpenVPN UDP remains on the VM."
read -r -p "Optional HTTPS application upstream [blank uses the built-in Cloud Run API]: " UPSTREAM_PRIMARY_INPUT
if [[ -z "$UPSTREAM_PRIMARY_INPUT" ]]; then
  UPSTREAM_PRIMARY="http://127.0.0.1:8081"
  UPSTREAM_FALLBACK="$UPSTREAM_PRIMARY"
  info "Using the built-in Cloud Run API sidecar; no self-referential domain upstream is configured."
else
  UPSTREAM_PRIMARY="$UPSTREAM_PRIMARY_INPUT"
  [[ "$UPSTREAM_PRIMARY" == https://* ]] || fail "Use an HTTPS URL, or leave this blank for the built-in Cloud Run API."
  case "$UPSTREAM_PRIMARY" in *[[:space:]]*|*\"*|*\\*) fail "Upstream URL contains unsupported whitespace or quoting." ;; esac
  validate_https_upstream "$UPSTREAM_PRIMARY" || fail "Enter a valid HTTPS upstream URL without credentials, query, or fragment."
  upstream_host="$(python3 -c 'import sys; from urllib.parse import urlsplit; print(urlsplit(sys.argv[1]).hostname)' "$UPSTREAM_PRIMARY")"
  [[ "${upstream_host,,}" != "${DOMAIN,,}" && "${upstream_host,,}" != "${RELAY_DOMAIN,,}" ]] \
    || fail "The upstream cannot use the gateway or relay hostname; that would proxy back into this deployment."
  read -r -p "Fallback HTTPS application upstream URL [same as primary]: " UPSTREAM_FALLBACK
  UPSTREAM_FALLBACK="${UPSTREAM_FALLBACK:-$UPSTREAM_PRIMARY}"
  [[ "$UPSTREAM_FALLBACK" == https://* ]] || fail "Use an HTTPS fallback URL."
  case "$UPSTREAM_FALLBACK" in *[[:space:]]*|*\"*|*\\*) fail "Fallback URL contains unsupported whitespace or quoting." ;; esac
  validate_https_upstream "$UPSTREAM_FALLBACK" || fail "Enter a valid HTTPS fallback URL without credentials, query, or fragment."
  fallback_host="$(python3 -c 'import sys; from urllib.parse import urlsplit; print(urlsplit(sys.argv[1]).hostname)' "$UPSTREAM_FALLBACK")"
  [[ "${fallback_host,,}" != "${DOMAIN,,}" && "${fallback_host,,}" != "${RELAY_DOMAIN,,}" ]] \
    || fail "The fallback cannot use the gateway or relay hostname; that would create a proxy loop."
  if [[ "$GATEWAY" == "nginx" || "$GATEWAY" == "envoy" ]]; then
    primary_authority="${UPSTREAM_PRIMARY#https://}"
    fallback_authority="${UPSTREAM_FALLBACK#https://}"
    [[ "$primary_authority" != *[/?#]* && "$fallback_authority" != *[/?#]* ]] \
      || fail "${GATEWAY} currently supports root-path HTTPS upstream URLs only; remove any path, query, or fragment."
    [[ "$upstream_host" != *:* && "$fallback_host" != *:* ]] \
      || fail "${GATEWAY} currently supports DNS names and IPv4 upstreams, not IPv6 literals."
    [[ "${upstream_host,,}" == "${fallback_host,,}" ]] \
      || fail "${GATEWAY} failover requires the primary and fallback to share one hostname for correct Host and TLS SNI routing."
  fi
fi

section "SECURITY  |  Configure optional Cloud Armor source rules"
read -r -p "Cloud Armor deny CIDRs (comma-separated, blank for none): " BLOCKED_CIDR_INPUT
read -r -p "Cloud Armor allow CIDRs (comma-separated, blank for unrestricted): " ALLOWED_CIDR_INPUT
BLOCKED_CIDRS=()
ALLOWED_CIDRS=()
if [[ -n "$BLOCKED_CIDR_INPUT" ]]; then IFS=',' read -r -a BLOCKED_CIDRS <<< "$BLOCKED_CIDR_INPUT"; fi
if [[ -n "$ALLOWED_CIDR_INPUT" ]]; then IFS=',' read -r -a ALLOWED_CIDRS <<< "$ALLOWED_CIDR_INPUT"; fi
for index in "${!BLOCKED_CIDRS[@]}"; do BLOCKED_CIDRS[$index]="${BLOCKED_CIDRS[$index]//[[:space:]]/}"; done
for index in "${!ALLOWED_CIDRS[@]}"; do ALLOWED_CIDRS[$index]="${ALLOWED_CIDRS[$index]//[[:space:]]/}"; done
for cidr in "${BLOCKED_CIDRS[@]}" "${ALLOWED_CIDRS[@]}"; do
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || fail "Invalid IPv4 CIDR: $cidr"
done
if ((${#ALLOWED_CIDRS[@]} > 0)); then
  warn "Cloud Armor will deny every client IP not present in the allowlist."
fi

TCP_RANGES=()
TCP_UPSTREAM_HOST="tcp.example.com:9000"
TLS_UPSTREAM_HOST="tls.example.com:9443"
if [[ "$GATEWAY" == "envoy" ]]; then
  read -r -p "Envoy TCP upstream host:port [${TCP_UPSTREAM_HOST}]: " TCP_UPSTREAM_HOST_INPUT
  TCP_UPSTREAM_HOST="${TCP_UPSTREAM_HOST_INPUT:-$TCP_UPSTREAM_HOST}"
  read -r -p "Envoy TLS passthrough upstream host:port [${TLS_UPSTREAM_HOST}]: " TLS_UPSTREAM_HOST_INPUT
  TLS_UPSTREAM_HOST="${TLS_UPSTREAM_HOST_INPUT:-$TLS_UPSTREAM_HOST}"
  [[ "$TCP_UPSTREAM_HOST" =~ ^([A-Za-z0-9.-]+):[0-9]{1,5}$ ]] || fail "Use a valid TCP upstream host:port."
  [[ "$TLS_UPSTREAM_HOST" =~ ^([A-Za-z0-9.-]+):[0-9]{1,5}$ ]] || fail "Use a valid TLS upstream host:port."
  read -r -p "Optional CIDRs for Envoy VM TCP/TLS ports 9000/9443 (comma-separated, blank disables): " TCP_SOURCE_RANGES
  if [[ -n "$TCP_SOURCE_RANGES" ]]; then
    IFS=',' read -r -a TCP_RANGES <<< "$TCP_SOURCE_RANGES"
    for index in "${!TCP_RANGES[@]}"; do TCP_RANGES[$index]="${TCP_RANGES[$index]//[[:space:]]/}"; done
    for cidr in "${TCP_RANGES[@]}"; do
      [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || fail "Invalid IPv4 CIDR in TCP source list: $cidr"
    done
  fi
fi

# Serialize Bash arguments as a JSON list for Terraform list(string) variables.
json_array() {
  local result="[" item
  for item in "$@"; do result+="\"${item}\","; done
  printf '%s]\n' "${result%,}"
}

section "DEPLOY  |  Prepare state, images, and protocol credentials"
STATE_BUCKET="${PROJECT_ID}-xgcpx-tfstate"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
if gcloud storage buckets describe "gs://${STATE_BUCKET}" --format='value(projectNumber)' >/dev/null 2>&1; then
  BUCKET_PROJECT_NUMBER="$(gcloud storage buckets describe "gs://${STATE_BUCKET}" --format='value(projectNumber)')"
  [[ "$BUCKET_PROJECT_NUMBER" == "$PROJECT_NUMBER" ]] || fail "Terraform state bucket exists but is not owned by project ${PROJECT_ID}."
else
  info "Creating private Terraform state bucket gs://${STATE_BUCKET}"
  gcloud storage buckets create "gs://${STATE_BUCKET}" --location="$REGION" --project="$PROJECT_ID" \
    --uniform-bucket-level-access --public-access-prevention=enforced
fi
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning --public-access-prevention=enforced \
  --uniform-bucket-level-access

AR_REPO="${APP_NAME}-images"
if ! gcloud artifacts repositories describe "$AR_REPO" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION" \
    --description="xgcpx gateway images" --project="$PROJECT_ID" --quiet
fi
DEPLOY_TAG="$(date -u +%Y%m%d%H%M%S)"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${GATEWAY}-${DEPLOY_TAG}"
BACKEND_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:backend-${DEPLOY_TAG}"
PROTOCOL_IMAGE_TAG="protocol-${DEPLOY_TAG}"
PROTOCOL_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${PROTOCOL_IMAGE_TAG}"
PROTOCOL_SECRET_NAME="${SERVICE_NAME}-protocol-config"
OPENVPN_IMAGE=""
OPENVPN_SECRET_NAME=""
OPENVPN_SECRET_VERSION=""
OPENVPN_STARTUP_COMMAND=":"
if [[ "$ENABLE_OPENVPN" == "true" ]]; then
  OPENVPN_IMAGE_TAG="openvpn-${DEPLOY_TAG}"
  OPENVPN_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${OPENVPN_IMAGE_TAG}"
  OPENVPN_SECRET_NAME="${SERVICE_NAME}-openvpn-config"
  OPENVPN_STARTUP_COMMAND='docker rm --force xgcpx-openvpn >/dev/null 2>&1 || true
docker run --detach --name xgcpx-openvpn --restart always \
  --publish 1194:1194/udp \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --env PROJECT_ID="__PROJECT_ID__" \
  --env OPENVPN_SECRET_NAME="__OPENVPN_SECRET_NAME__" \
  "__OPENVPN_IMAGE__"'
  OPENVPN_STARTUP_COMMAND="${OPENVPN_STARTUP_COMMAND//__PROJECT_ID__/$PROJECT_ID}"
  OPENVPN_STARTUP_COMMAND="${OPENVPN_STARTUP_COMMAND//__OPENVPN_SECRET_NAME__/$OPENVPN_SECRET_NAME}"
  OPENVPN_STARTUP_COMMAND="${OPENVPN_STARTUP_COMMAND//__OPENVPN_IMAGE__/$OPENVPN_IMAGE}"
fi
PROTOCOL_STARTUP_SCRIPT="$(cat <<'PROTOCOL_STARTUP_EOF'
#!/bin/bash
set -Eeuo pipefail

metadata="http://metadata.google.internal/computeMetadata/v1"
daemon_attempt=0
until docker info >/dev/null 2>&1; do
  daemon_attempt=$((daemon_attempt + 1))
  if [ "$daemon_attempt" -ge 60 ]; then
    printf '%s\n' "Docker did not become ready before the startup timeout." >&2
    exit 1
  fi
  sleep 2
done

DOCKER_CONFIG=/run/xgcpx-docker-auth
mkdir -p "$DOCKER_CONFIG"
chmod 0700 "$DOCKER_CONFIG"
trap 'rm -f -- "$DOCKER_CONFIG/config.json"; rmdir "$DOCKER_CONFIG" 2>/dev/null || true' EXIT
pulled=false
attempt=0
while [ "$attempt" -lt 12 ]; do
  if ! token_json="$(curl --fail --silent --show-error --retry 3 --retry-connrefused \
    --connect-timeout 3 --max-time 15 \
    --header 'Metadata-Flavor: Google' \
    "$metadata/instance/service-accounts/default/token")"; then
    attempt=$((attempt + 1))
    sleep 10
    continue
  fi
  access_token="$(printf '%s' "$token_json" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  if [ -n "$access_token" ] \
    && printf '%s' "$access_token" | DOCKER_CONFIG="$DOCKER_CONFIG" docker login \
      --username oauth2accesstoken --password-stdin "https://__REGION__-docker.pkg.dev" \
    && DOCKER_CONFIG="$DOCKER_CONFIG" docker pull "__PROTOCOL_IMAGE__" \
    && { [ -z "__OPENVPN_IMAGE__" ] || DOCKER_CONFIG="$DOCKER_CONFIG" docker pull "__OPENVPN_IMAGE__"; }; then
    pulled=true
    break
  fi
  unset token_json access_token
  attempt=$((attempt + 1))
  sleep 10
done
unset token_json access_token
test "$pulled" = true
DOCKER_CONFIG="$DOCKER_CONFIG" docker logout "https://__REGION__-docker.pkg.dev"
rm -f -- "$DOCKER_CONFIG/config.json"
rmdir "$DOCKER_CONFIG"
trap - EXIT

mkdir -p /var/lib/xgcpx/caddy-data /var/lib/xgcpx/caddy-config
chown 10001:10001 /var/lib/xgcpx/caddy-data /var/lib/xgcpx/caddy-config
chmod 0750 /var/lib/xgcpx/caddy-data /var/lib/xgcpx/caddy-config
docker rm --force xgcpx-protocols >/dev/null 2>&1 || true
docker run --detach --name xgcpx-protocols --restart always \
  --publish 80:8080/tcp \
  --publish 443:8443/tcp \
  --publish 8080:8081/tcp \
  --publish 50051:50052/tcp \
  --publish 8388:8388/tcp \
  --publish 8388:8388/udp \
  --volume /var/lib/xgcpx/caddy-data:/data \
  --volume /var/lib/xgcpx/caddy-config:/config \
  --env PROJECT_ID="__PROJECT_ID__" \
  --env PROTOCOL_SECRET_NAME="__PROTOCOL_SECRET_NAME__" \
  --env RELAY_DOMAIN="__PROTOCOL_DOMAIN__" \
  "__PROTOCOL_IMAGE__"
__OPENVPN_STARTUP_COMMAND__
PROTOCOL_STARTUP_EOF
)"
PROTOCOL_STARTUP_SCRIPT="${PROTOCOL_STARTUP_SCRIPT//__REGION__/$REGION}"
PROTOCOL_STARTUP_SCRIPT="${PROTOCOL_STARTUP_SCRIPT//__PROTOCOL_IMAGE__/$PROTOCOL_IMAGE}"
PROTOCOL_STARTUP_SCRIPT="${PROTOCOL_STARTUP_SCRIPT//__PROJECT_ID__/$PROJECT_ID}"
PROTOCOL_STARTUP_SCRIPT="${PROTOCOL_STARTUP_SCRIPT//__PROTOCOL_SECRET_NAME__/$PROTOCOL_SECRET_NAME}"
PROTOCOL_STARTUP_SCRIPT="${PROTOCOL_STARTUP_SCRIPT//__PROTOCOL_DOMAIN__/$RELAY_DOMAIN}"
PROTOCOL_STARTUP_SCRIPT="${PROTOCOL_STARTUP_SCRIPT//__OPENVPN_IMAGE__/$OPENVPN_IMAGE}"
PROTOCOL_STARTUP_SCRIPT="${PROTOCOL_STARTUP_SCRIPT//__OPENVPN_STARTUP_COMMAND__/$OPENVPN_STARTUP_COMMAND}"
run_with_spinner "Configuring Artifact Registry authentication" gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
run_with_spinner "Building ${GATEWAY} gateway image" docker build --platform linux/amd64 --file "$DOCKERFILE" --tag "$IMAGE" .
run_with_spinner "Pushing ${GATEWAY} gateway image" docker push "$IMAGE"

run_with_spinner "Building the built-in Cloud Run API backend" docker build --platform linux/amd64 \
  --file backend/Dockerfile --tag "$BACKEND_IMAGE" backend
run_with_spinner "Pushing the built-in Cloud Run API backend" docker push "$BACKEND_IMAGE"

run_with_spinner "Building the authenticated protocol VM image" docker build --platform linux/amd64 --file proxies/xray/Dockerfile --tag "$PROTOCOL_IMAGE" .
run_with_spinner "Pushing the authenticated protocol VM image" docker push "$PROTOCOL_IMAGE"
if [[ "$ENABLE_OPENVPN" == "true" ]]; then
  run_with_spinner "Building the OpenVPN VM image" docker build --platform linux/amd64 --file proxies/openvpn/Dockerfile --tag "$OPENVPN_IMAGE" .
  run_with_spinner "Pushing the OpenVPN VM image" docker push "$OPENVPN_IMAGE"
fi

PROTOCOL_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
SHADOWSOCKS_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
PROTOCOL_CONFIG_FILE="$(mktemp)"
chmod 0600 "$PROTOCOL_CONFIG_FILE"
PROTOCOL_TAGS_JSON="$(json_array "${PROTOCOL_TAGS[@]}")"
python3 - "$PROTOCOL_TAGS_JSON" "$PROTOCOL_UUID" "$SHADOWSOCKS_PASSWORD" \
  "$PROTOCOL_CONFIG_FILE" proxies/xray/config.json <<'PY'
import json
import sys

enabled_tags = set(json.loads(sys.argv[1]))
vless_uuid, shadowsocks_password, output_path, template_path = sys.argv[2:]
with open(template_path, encoding="utf-8") as source:
    config = json.load(source)
config["inbounds"] = [
    inbound for inbound in config["inbounds"]
    if inbound["tag"] in enabled_tags
]
for inbound in config["inbounds"]:
    settings = inbound["settings"]
    if inbound["protocol"] == "vless":
        for client in settings["clients"]:
            client["id"] = vless_uuid
    elif inbound["protocol"] == "shadowsocks":
        settings["password"] = shadowsocks_password
with open(output_path, "w", encoding="utf-8") as destination:
    json.dump(config, destination, indent=2)
    destination.write("\n")
PY

if ! gcloud secrets describe "$PROTOCOL_SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud secrets create "$PROTOCOL_SECRET_NAME" --replication-policy=automatic --project="$PROJECT_ID"
fi
PROTOCOL_SECRET_VERSION="$(gcloud secrets versions add "$PROTOCOL_SECRET_NAME" \
  --data-file="$PROTOCOL_CONFIG_FILE" --project="$PROJECT_ID" --format='value(name)')"
rm -f -- "$PROTOCOL_CONFIG_FILE"
PROTOCOL_CONFIG_FILE=""

if [[ "$ENABLE_OPENVPN" == "true" ]]; then
  OPENVPN_PKI_DIR="$(mktemp -d)"
  chmod 0700 "$OPENVPN_PKI_DIR"
  openssl genrsa -out "$OPENVPN_PKI_DIR/ca.key" 4096
  openssl req -x509 -new -sha256 -days 3650 -key "$OPENVPN_PKI_DIR/ca.key" \
    -subj "/CN=xgcpx-openvpn-ca" -out "$OPENVPN_PKI_DIR/ca.crt"
  openssl genrsa -out "$OPENVPN_PKI_DIR/server.key" 2048
  openssl req -new -key "$OPENVPN_PKI_DIR/server.key" -subj "/CN=xgcpx-openvpn-server" \
    -out "$OPENVPN_PKI_DIR/server.csr"
  printf '%s\n' 'basicConstraints=CA:FALSE' 'keyUsage=digitalSignature,keyEncipherment' \
    'extendedKeyUsage=serverAuth' >"$OPENVPN_PKI_DIR/server.ext"
  openssl x509 -req -in "$OPENVPN_PKI_DIR/server.csr" -CA "$OPENVPN_PKI_DIR/ca.crt" \
    -CAkey "$OPENVPN_PKI_DIR/ca.key" -CAcreateserial -days 825 -sha256 \
    -extfile "$OPENVPN_PKI_DIR/server.ext" -out "$OPENVPN_PKI_DIR/server.crt"
  openssl genrsa -out "$OPENVPN_PKI_DIR/client.key" 2048
  openssl req -new -key "$OPENVPN_PKI_DIR/client.key" -subj "/CN=xgcpx-openvpn-client" \
    -out "$OPENVPN_PKI_DIR/client.csr"
  printf '%s\n' 'basicConstraints=CA:FALSE' 'keyUsage=digitalSignature,keyEncipherment' \
    'extendedKeyUsage=clientAuth' >"$OPENVPN_PKI_DIR/client.ext"
  openssl x509 -req -in "$OPENVPN_PKI_DIR/client.csr" -CA "$OPENVPN_PKI_DIR/ca.crt" \
    -CAkey "$OPENVPN_PKI_DIR/ca.key" -CAcreateserial -days 825 -sha256 \
    -extfile "$OPENVPN_PKI_DIR/client.ext" -out "$OPENVPN_PKI_DIR/client.crt"
  python3 - "$OPENVPN_PKI_DIR" <<'PY'
import json
import secrets
import sys
from pathlib import Path

directory = Path(sys.argv[1])
key = secrets.token_hex(256)
tls_crypt = (
    "#\n# 2048 bit OpenVPN static key\n#\n"
    "-----BEGIN OpenVPN Static key V1-----\n"
    + "\n".join(key[index:index + 32] for index in range(0, len(key), 32))
    + "\n-----END OpenVPN Static key V1-----\n"
)
payload = {
    "ca": (directory / "ca.crt").read_text(encoding="ascii"),
    "server_cert": (directory / "server.crt").read_text(encoding="ascii"),
    "server_key": (directory / "server.key").read_text(encoding="ascii"),
    "tls_crypt": tls_crypt,
}
(directory / "tls-crypt.key").write_text(tls_crypt, encoding="ascii")
(directory / "openvpn-secret.json").write_text(json.dumps(payload), encoding="utf-8")
PY
  OPENVPN_SECRET_FILE="$OPENVPN_PKI_DIR/openvpn-secret.json"
  if ! gcloud secrets describe "$OPENVPN_SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud secrets create "$OPENVPN_SECRET_NAME" --replication-policy=automatic --project="$PROJECT_ID"
  fi
  OPENVPN_SECRET_VERSION="$(gcloud secrets versions add "$OPENVPN_SECRET_NAME" \
    --data-file="$OPENVPN_SECRET_FILE" --project="$PROJECT_ID" --format='value(name)')"
fi

export TF_VAR_project_id="$PROJECT_ID"
export TF_VAR_region="$REGION"
export TF_VAR_service_name="$SERVICE_NAME"
export TF_VAR_image="$IMAGE"
export TF_VAR_backend_image="$BACKEND_IMAGE"
export TF_VAR_machine_type="$MACHINE_TYPE"
export TF_VAR_domain="$DOMAIN"
export TF_VAR_upstream_primary="$UPSTREAM_PRIMARY"
export TF_VAR_upstream_fallback="$UPSTREAM_FALLBACK"
export TF_VAR_blocked_cidrs="$(json_array "${BLOCKED_CIDRS[@]}")"
export TF_VAR_allowed_cidrs="$(json_array "${ALLOWED_CIDRS[@]}")"
export TF_VAR_tcp_upstream_host="$TCP_UPSTREAM_HOST"
export TF_VAR_tls_upstream_host="$TLS_UPSTREAM_HOST"
export TF_VAR_enable_protocol_gateway=true
export TF_VAR_protocol_image="$PROTOCOL_IMAGE"
export TF_VAR_protocol_domain="$RELAY_DOMAIN"
export TF_VAR_protocol_secret_name="$PROTOCOL_SECRET_NAME"
export TF_VAR_protocol_secret_version="$PROTOCOL_SECRET_VERSION"
export TF_VAR_protocol_image_revision="$PROTOCOL_IMAGE_TAG"
export TF_VAR_protocol_startup_script="$PROTOCOL_STARTUP_SCRIPT"
export TF_VAR_protocol_tcp_ports="$(json_array "${PROTOCOL_TCP_PORTS[@]}")"
export TF_VAR_protocol_udp_ports="$(json_array "${PROTOCOL_UDP_PORTS[@]}")"
export TF_VAR_enable_openvpn="$ENABLE_OPENVPN"
export TF_VAR_openvpn_image="$OPENVPN_IMAGE"
export TF_VAR_openvpn_secret_name="$OPENVPN_SECRET_NAME"
export TF_VAR_openvpn_secret_version="$OPENVPN_SECRET_VERSION"
ENABLE_TCP_PROXY=false
if [[ "$GATEWAY" == "envoy" && ${#TCP_RANGES[@]} -gt 0 ]]; then ENABLE_TCP_PROXY=true; fi
export TF_VAR_enable_tcp_proxy="$ENABLE_TCP_PROXY"
TCP_JSON="["
for cidr in "${TCP_RANGES[@]}"; do TCP_JSON+="\"${cidr}\","; done
TCP_JSON="${TCP_JSON%,}]"
export TF_VAR_tcp_source_ranges="$TCP_JSON"

if ! run_with_spinner "Initializing Terraform state and provider" terraform -chdir=terraform init -input=false \
  -backend-config="bucket=${STATE_BUCKET}" -backend-config="prefix=${APP_NAME}/terraform"; then
  fail "Terraform init failed. Ensure its ADC principal can read and write gs://${STATE_BUCKET}, and verify provider/network access."
fi
TERRAFORM_PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/xgcpx-terraform-plan.XXXXXX")"
if ! run_with_spinner "Checking Terraform credentials, permissions, quotas, and planned changes" \
  terraform -chdir=terraform plan -input=false -out="$TERRAFORM_PLAN_FILE"; then
  fail "Terraform plan failed; no Terraform infrastructure changes were applied. Check the ADC principal, project IAM roles, quota, billing, and organization policies shown above."
fi
if ! run_with_spinner "Applying the verified Terraform plan" \
  terraform -chdir=terraform apply -input=false "$TERRAFORM_PLAN_FILE"; then
  fail "Terraform apply failed. Review the provider error above; GCP may have accepted only part of the deployment."
fi
rm -f -- "$TERRAFORM_PLAN_FILE"
TERRAFORM_PLAN_FILE=""

LB_IP="$(terraform -chdir=terraform output -raw load_balancer_ip)"
section "COMPLETE  |  Deployment outputs"
printf '%s\n' "Service: $SERVICE_NAME" "Region: $REGION ($(region_flag "$REGION" "$REGION"))" "Gateway: $GATEWAY" \
  "HTTPS URL: https://${DOMAIN}" "Global load balancer IP: ${LB_IP}" \
  "DNS: create an A record for ${DOMAIN} pointing to ${LB_IP}; certificate provisioning starts after DNS resolves."
printf 'Selected gateway image source: %s (only this gateway Dockerfile was built).\n' "$DOCKERFILE"
printf '%s\n' \
  "Cloud Run application routes:" \
  "  HTTPS/TLS: https://${DOMAIN} (TLS terminates at the external HTTPS load balancer)" \
  "  Health: /healthz | API: /api/* (built-in sidecar unless an external upstream is supplied)" \
  "  WebSocket/gRPC: requires a compatible application upstream; Cloud Run carries these over HTTP(S)" \
  "  Persistent streaming: /persistent/* | Assets: /assets/*" \
  "  These HTTP routes do not provide SSH or OpenVPN transport."
if [[ "$ENABLE_TCP_PROXY" == "true" ]]; then
  printf 'Envoy TCP endpoint: %s:9000\nEnvoy TLS passthrough endpoint: %s:9443\n' \
    "$(terraform -chdir=terraform output -raw tcp_proxy_ip)" \
    "$(terraform -chdir=terraform output -raw tls_proxy_ip)"
fi

PROTOCOL_IP="$(terraform -chdir=terraform output -raw protocol_gateway_ip)"
printf '\n%s\n' \
  "Protocol VM public IP: ${PROTOCOL_IP}" \
  "Protocol hostname: ${RELAY_DOMAIN} (create its A record directly to ${PROTOCOL_IP})" \
  "The protocol VM firewall is public; VLESS/Shadowsocks require credentials and OpenVPN requires the generated client certificate."
printf '%s\n' "Enabled protocol endpoints and credentials:"
if [[ " ${PROTOCOL_OPTIONS[*]} " == *" 1 "* || " ${PROTOCOL_OPTIONS[*]} " == *" 2 "* || " ${PROTOCOL_OPTIONS[*]} " == *" 3 "* ]]; then
  printf '  VLESS client ID (UUID): %s\n' "$PROTOCOL_UUID"
  printf '  VLESS TLS server name: %s\n' "$RELAY_DOMAIN"
fi
if [[ " ${PROTOCOL_OPTIONS[*]} " == *" 1 "* ]]; then
  printf '  VLESS over TLS/WebSocket: %s:443, path /vless-ws\n' "$RELAY_DOMAIN"
  printf '  VLESS over TLS/HTTPUpgrade: %s:443, path /vless-httpupgrade\n' "$RELAY_DOMAIN"
fi
if [[ " ${PROTOCOL_OPTIONS[*]} " == *" 2 "* ]]; then
  printf '  VLESS over TLS/gRPC: %s:443 (or :50051), service name vless-grpc\n' "$RELAY_DOMAIN"
fi
if [[ " ${PROTOCOL_OPTIONS[*]} " == *" 3 "* ]]; then
  printf '  VLESS xHTTP/TLS packet-up: %s:443 or :8080, path /xhttp-packet\n' "$RELAY_DOMAIN"
  printf '  VLESS xHTTP/TLS stream-up: %s:443 or :8080, path /xhttp-chunked\n' "$RELAY_DOMAIN"
  printf '  VLESS xHTTP/TLS stream-one: %s:443 or :8080, path /xhttp-request-response\n' "$RELAY_DOMAIN"
fi
if [[ " ${PROTOCOL_OPTIONS[*]} " == *" 4 "* ]]; then
  printf '  Shadowsocks: %s:8388 (TCP and UDP), method chacha20-ietf-poly1305\n  Shadowsocks password: %s\n' \
    "$RELAY_DOMAIN" "$SHADOWSOCKS_PASSWORD"
fi
if [[ "$ENABLE_OPENVPN" == "true" ]]; then
  OPENVPN_CLIENT_CONFIG="${PWD}/openvpn-client-${DEPLOY_TAG}.ovpn"
  {
    printf '%s\n' 'client' 'dev tun' 'proto udp' "remote ${PROTOCOL_IP} 1194" \
      'resolv-retry infinite' 'nobind' 'persist-key' 'persist-tun' 'remote-cert-tls server' \
      'verify-x509-name xgcpx-openvpn-server name' 'auth SHA256' \
      'data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305' 'verb 3' '<ca>'
    cat "$OPENVPN_PKI_DIR/ca.crt"
    printf '%s\n' '</ca>' '<cert>'
    cat "$OPENVPN_PKI_DIR/client.crt"
    printf '%s\n' '</cert>' '<key>'
    cat "$OPENVPN_PKI_DIR/client.key"
    printf '%s\n' '</key>' '<tls-crypt>'
    cat "$OPENVPN_PKI_DIR/tls-crypt.key"
    printf '%s\n' '</tls-crypt>'
  } >"$OPENVPN_CLIENT_CONFIG"
  chmod 0600 "$OPENVPN_CLIENT_CONFIG"
  printf '  OpenVPN: %s:1194/udp (certificate-authenticated; connect using the client profile)\n' "$PROTOCOL_IP"
  printf '  OpenVPN client profile: %s (private file, mode 0600)\n' "$OPENVPN_CLIENT_CONFIG"
fi
printf 'Selected protocols: %s\n' "${PROTOCOL_OPTIONS[*]}"
warn "Store printed credentials and the OpenVPN profile securely. No public SSH/password or SSH-over-WebSocket service is configured."
warn "The protocol VM IP is a separate endpoint, not the Cloud Run load-balancer IP. Cloud Run cannot relay raw OpenVPN UDP."

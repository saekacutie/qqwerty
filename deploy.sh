#!/usr/bin/env bash
# xgcpx - Cloud Run gateway + optional protocol VM (Xray services, optional OpenVPN) on Google Cloud.
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive TF_IN_AUTOMATION=true

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  printf 'ERROR: bash 4.4 or newer is required (found %s). On macOS run: brew install bash\n' "$BASH_VERSION" >&2
  exit 1
fi
# Bash 5.2 treats "&" in ${var//pat/repl} replacements specially; keep substitutions literal.
shopt -u patsub_replacement 2>/dev/null || true

# Always run from the repository root (the directory that holds this script).
cd "$(dirname "${BASH_SOURCE[0]}")"

readonly APP_NAME="xgcpx"
readonly DEFAULT_SERVICE="api-gateway-404"
readonly TOTAL_STEPS=11
STEP=0

# ---------------------------------------------------------------------------------------------
# Terminal UI
# ---------------------------------------------------------------------------------------------
if [[ -t 1 && "${TERM:-}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
  readonly RED=$'\033[0;31m' GREEN=$'\033[0;32m' CYAN=$'\033[0;36m' YELLOW=$'\033[0;33m'
  readonly BLUE=$'\033[0;34m' BOLD=$'\033[1m' DIM=$'\033[2m' RESET=$'\033[0m'
else
  readonly RED="" GREEN="" CYAN="" YELLOW="" BLUE="" BOLD="" DIM="" RESET=""
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*)
    SYM_OK="✔"; SYM_ERR="✖"; SYM_INFO="➜"; SYM_WARN="▲"; SYM_RULE="─"
    SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    ;;
  *)
    SYM_OK="+"; SYM_ERR="x"; SYM_INFO=">"; SYM_WARN="!"; SYM_RULE="-"
    SPIN_FRAMES=('|' '/' '-' '\')
    ;;
esac

PROTOCOL_CONFIG_FILE=""
CLIENT_PROFILE_REPORT=""
OPENVPN_SECRET_FILE=""
OPENVPN_PKI_DIR=""
TERRAFORM_PLAN_FILE=""
RUN_REGION_JSON_FILE=""
COMPUTE_REGION_JSON_FILE=""
MACHINE_TYPE_JSON_FILE=""

info() { printf '%s%s%s %s\n' "$CYAN" "$SYM_INFO" "$RESET" "$*"; }
success() { printf '%s%s%s %s\n' "$GREEN" "$SYM_OK" "$RESET" "$*"; }
warn() { printf '%s%s%s %s\n' "$YELLOW" "$SYM_WARN" "$RESET" "$*"; }
fail() { printf '%s%s ERROR%s %s\n' "$RED" "$SYM_ERR" "$RESET" "$*" >&2; exit 1; }
hr() {
  local i line=""
  for ((i = 0; i < 64; i++)); do line+="$SYM_RULE"; done
  printf '%s%s%s\n' "$BLUE" "$line" "$RESET"
}
section() {
  STEP=$((STEP + 1))
  printf '\n'
  hr
  printf '%s%s [%d/%d] %s%s\n' "$BOLD" "$BLUE" "$STEP" "$TOTAL_STEPS" "$*" "$RESET"
  hr
}
kv() { printf '  %s%-18s%s %s\n' "$BOLD" "$1" "$RESET" "$2"; }
menu_item() { printf '  %s%2s)%s %-38s %s%s%s\n' "$BOLD" "$1" "$RESET" "$2" "$DIM" "${3:-}" "$RESET"; }

# Answer a prompt from an environment variable, an interactive read, or (no terminal) an empty value.
prompt_value() {
  local __var="$1" __env="$2" __prompt="$3" __val=""
  if [[ -n "$__env" ]]; then
    __val="$__env"
    info "${__prompt%%[:\[]*}: ${__val} (from environment)"
  elif [[ -t 0 ]]; then
    read -r -p "$__prompt" __val || __val=""
  fi
  printf -v "$__var" '%s' "$__val"
}

# pick VAR ENV_VALUE LABEL PROMPT DEFAULT MAX -> numeric menu answer; re-asks on typos when interactive.
pick() {
  local __var="$1" __env="$2" __label="$3" __prompt="$4" __def="$5" __max="$6" __val=""
  if [[ -n "$__env" ]]; then
    __val="$__env"
    [[ "$__val" =~ ^[0-9]+$ ]] && ((__val >= 1 && __val <= __max)) || fail "Invalid ${__label} '${__val}'; choose 1-${__max}."
    info "${__label}: option ${__val} (from environment)"
  elif [[ -t 0 ]]; then
    while :; do
      read -r -p "$__prompt" __val || __val=""
      __val="${__val:-$__def}"
      if [[ "$__val" =~ ^[0-9]+$ ]] && ((__val >= 1 && __val <= __max)); then break; fi
      warn "Enter a number from 1 to ${__max}."
    done
  else
    __val="$__def"
  fi
  printf -v "$__var" '%s' "$__val"
}

# Animate long steps only in interactive terminals, and preserve command output.
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
      printf '%s%s ERROR%s %s failed (exit %s).\n' "$RED" "$SYM_ERR" "$RESET" "$label" "$status" >&2
      return "$status"
    fi
  fi

  output_file="$(mktemp)"
  "$@" >"$output_file" 2>&1 &
  local command_pid=$!
  while kill -0 "$command_pid" 2>/dev/null; do
    printf '\r%s%s%s %s' "$CYAN" "${SPIN_FRAMES[$frame]}" "$RESET" "$label"
    frame=$(((frame + 1) % ${#SPIN_FRAMES[@]}))
    sleep 0.1
  done
  wait "$command_pid" || status=$?
  printf '\r\033[K'
  if ((status == 0)); then
    success "$label"
    tail -n 6 "$output_file" | sed 's/^/    /'
  else
    printf '%s%s ERROR%s %s failed:\n' "$RED" "$SYM_ERR" "$RESET" "$label" >&2
    cat "$output_file" >&2
  fi
  rm -f -- "$output_file"
  return "$status"
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
url_hostname() {
  python3 -c 'import sys; from urllib.parse import urlsplit; print(urlsplit(sys.argv[1]).hostname or "")' "$1"
}
# Accept "https://Host.Example/path" typed by mistake and reduce it to the bare lowercase hostname.
normalize_host() {
  local host="${1//[[:space:]]/}"
  host="${host#http://}"
  host="${host#https://}"
  host="${host%%/*}"
  printf '%s' "${host,,}"
}

# Include the failing source line and command when strict-mode execution aborts.
on_error() { printf '%s%s ERROR%s deploy failed at line %s (command: %s)\n' "$RED" "$SYM_ERR" "$RESET" "$1" "$2" >&2; }
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap 'printf "\n%s Interrupted; cleaning up.\n" "$SYM_WARN" >&2; exit 130' INT TERM
cleanup() {
  if [[ -n "$PROTOCOL_CONFIG_FILE" ]]; then rm -f -- "$PROTOCOL_CONFIG_FILE"; fi
  if [[ -n "$OPENVPN_SECRET_FILE" ]]; then rm -f -- "$OPENVPN_SECRET_FILE"; fi
  if [[ -n "$OPENVPN_PKI_DIR" ]]; then rm -rf -- "$OPENVPN_PKI_DIR"; fi
  if [[ -n "$TERRAFORM_PLAN_FILE" ]]; then rm -f -- "$TERRAFORM_PLAN_FILE"; fi
  if [[ -n "$RUN_REGION_JSON_FILE" ]]; then rm -f -- "$RUN_REGION_JSON_FILE"; fi
  if [[ -n "$COMPUTE_REGION_JSON_FILE" ]]; then rm -f -- "$COMPUTE_REGION_JSON_FILE"; fi
  if [[ -n "$MACHINE_TYPE_JSON_FILE" ]]; then rm -f -- "$MACHINE_TYPE_JSON_FILE"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------------------------
REGION_HINT="${XGCPX_REGION:-${CLOUDSDK_COMPUTE_REGION:-}}"
REGION_HINT_SOURCE="environment"
CLI_REGION=""
CLI_PROJECT=""
WANT_OPENVPN="${XGCPX_OPENVPN:-false}"
ASSUME_YES="${XGCPX_ASSUME_YES:-false}"
while (($# > 0)); do
  case "$1" in
    --project)
      (($# >= 2)) || fail "--project requires a project ID."
      CLI_PROJECT="$2"
      shift 2
      ;;
    --project=*)
      CLI_PROJECT="${1#--project=}"
      [[ -n "$CLI_PROJECT" ]] || fail "--project requires a project ID."
      shift
      ;;
    --domain)
      (($# >= 2)) || fail "--domain requires a hostname (or 'auto')."
      XGCPX_DOMAIN="$2"
      shift 2
      ;;
    --domain=*)
      XGCPX_DOMAIN="${1#--domain=}"
      shift
      ;;
    --openvpn)
      WANT_OPENVPN=true
      shift
      ;;
    --yes | -y)
      ASSUME_YES=true
      shift
      ;;
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
    --help | -h)
      printf 'Usage: %s [--project PROJECT_ID] [--region REGION] [--domain HOST|auto] [--openvpn] [--yes]\n' "$0"
      printf 'Project precedence: --project, XGCPX_PROJECT, STUDENT_PROJECT_ID, gcloud core/project.\n'
      printf 'Refuses to run in MAIN_PROJECT_ID or XGCPX_FORBIDDEN_PROJECT.\n'
      printf 'Region precedence: --region, XGCPX_REGION, CLOUDSDK_COMPUTE_REGION, gcloud compute/region.\n'
      printf 'Public host: blank/auto (default) uses the automatic Google Cloud Run URL (*.run.app); a custom domain adds a\n'
      printf '  global load balancer, managed certificate and Cloud Armor.\n'
      printf 'Protocols: "all" (or 9) means every Xray service. OpenVPN is never implied; add 5, --openvpn or XGCPX_OPENVPN=true.\n'
      printf 'Non-interactive answers (environment variables):\n'
      printf '  XGCPX_GATEWAY (envoy|nginx|caddy|traefik|unified or 1-5), XGCPX_PROTOCOL_RUNTIME (vm|cloud-run),\n'
      printf '  XGCPX_PROTOCOLS (1-8, comma list, or all), XGCPX_OPENVPN (true|false), XGCPX_SERVICE,\n'
      printf '  XGCPX_TIER (machine type or 1-5), XGCPX_DOMAIN (blank or auto = automatic Cloud Run host),\n'
      printf '  XGCPX_RELAY_DOMAIN (protocol VM hostname; blank/auto = relay.<domain>, or <ip>.sslip.io without a domain),\n'
      printf '  XGCPX_UPSTREAM, XGCPX_UPSTREAM_FALLBACK, XGCPX_BLOCKED_CIDRS, XGCPX_ALLOWED_CIDRS,\n'
      printf '  XGCPX_TCP_UPSTREAM, XGCPX_TLS_UPSTREAM, XGCPX_TCP_SOURCE_RANGES, XGCPX_ASSUME_YES=true.\n'
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
WANT_OPENVPN="${WANT_OPENVPN,,}"

for tool in gcloud docker terraform python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done
for required in terraform/main.tf terraform/variables.tf backend/Dockerfile proxies/xray/Dockerfile proxies/xray/config.json; do
  [[ -f "$required" ]] || fail "Missing ${required}; run this script from the xgcpx repository root."
done
docker info >/dev/null 2>&1 || fail "The Docker daemon is not reachable. Start Docker (or Cloud Shell's Docker) and retry."

# ---------------------------------------------------------------------------------------------
# Project selection
# ---------------------------------------------------------------------------------------------
PROJECT_ID=""
PROJECT_SOURCE=""
if [[ -n "$CLI_PROJECT" ]]; then
  PROJECT_ID="$CLI_PROJECT"; PROJECT_SOURCE="--project"
elif [[ -n "${XGCPX_PROJECT:-}" ]]; then
  PROJECT_ID="$XGCPX_PROJECT"; PROJECT_SOURCE="XGCPX_PROJECT"
elif [[ -n "${STUDENT_PROJECT_ID:-}" ]]; then
  PROJECT_ID="$STUDENT_PROJECT_ID"; PROJECT_SOURCE="STUDENT_PROJECT_ID"
else
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')"; PROJECT_SOURCE="gcloud config"
fi
PROJECT_ID="${PROJECT_ID//[[:space:]]/}"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] \
  || fail "No project selected. Use --project, XGCPX_PROJECT, STUDENT_PROJECT_ID, or 'gcloud config set project PROJECT_ID'."
[[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || fail "Invalid project ID: ${PROJECT_ID}"
for forbidden in "${MAIN_PROJECT_ID:-}" "${XGCPX_FORBIDDEN_PROJECT:-}"; do
  if [[ -n "$forbidden" && "$PROJECT_ID" == "$forbidden" ]]; then
    fail "Refusing to deploy into protected project ${PROJECT_ID} (selected via ${PROJECT_SOURCE}). Pick another with --project."
  fi
done
# Pin every tool to this one project for this run only; the user's gcloud config is not modified.
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID" GOOGLE_CLOUD_PROJECT="$PROJECT_ID" GOOGLE_PROJECT="$PROJECT_ID" \
  GOOGLE_CLOUD_QUOTA_PROJECT="$PROJECT_ID" GOOGLE_BILLING_PROJECT="$PROJECT_ID"
ACTIVE_ACCOUNT="$(gcloud config get-value account 2>/dev/null | tr -d '[:space:]')"
[[ -n "$ACTIVE_ACCOUNT" && "$ACTIVE_ACCOUNT" != "(unset)" ]] || fail "No active gcloud account. Authenticate with gcloud."
if ! gcloud auth print-access-token --account="$ACTIVE_ACCOUNT" >/dev/null 2>&1; then
  fail "The active gcloud account cannot obtain an access token. Re-authenticate with 'gcloud auth login' and confirm this account has access to project ${PROJECT_ID}."
fi

printf '\n%s%s xgcpx %s%s| GCP gateway deployment%s\n' "$BOLD" "$CYAN" "$RESET" "$DIM" "$RESET"
kv "Project" "${PROJECT_ID} (from ${PROJECT_SOURCE})"
kv "Account" "$ACTIVE_ACCOUNT"
if [[ "${ASSUME_YES,,}" != "true" ]]; then
  [[ -t 0 ]] || fail "Not a terminal; pass --yes (or XGCPX_ASSUME_YES=true) to confirm deployment into ${PROJECT_ID}."
  printf '\n'
  read -r -p "Deploy into project ${PROJECT_ID}? [y/N]: " CONFIRM_PROJECT || CONFIRM_PROJECT=""
  [[ "${CONFIRM_PROJECT,,}" == "y" || "${CONFIRM_PROJECT,,}" == "yes" ]] || fail "Cancelled; nothing was changed."
fi

# ---------------------------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------------------------
section "PREFLIGHT  |  APIs, credentials, billing"
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
success "Credentials are usable by gcloud and Terraform."

PROJECT_STATUS="$(gcloud projects describe "$PROJECT_ID" --format='value(lifecycleState)' 2>/dev/null)" \
  || fail "Cannot read project ${PROJECT_ID}. Check the project ID, gcloud account, and resourcemanager.projects.get permission."
[[ "$PROJECT_STATUS" == "ACTIVE" ]] || fail "Project ${PROJECT_ID} is not ACTIVE (state: ${PROJECT_STATUS:-unknown})."

if ! BILLING_STATUS="$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null)"; then
  fail "Cannot verify billing for ${PROJECT_ID}. Ensure Cloud Billing API is enabled and this account has billing.resourceAssociations.get permission."
fi
[[ "$BILLING_STATUS" == "True" || "$BILLING_STATUS" == "true" ]] \
  || fail "Billing is not enabled for ${PROJECT_ID}. Link an active billing account before deploying Cloud Run, Compute Engine, load balancing, or Cloud Armor."
success "Project is ACTIVE and billing is enabled."

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null)" \
  || fail "Cannot read the project number for ${PROJECT_ID}."
[[ "$PROJECT_NUMBER" =~ ^[0-9]+$ ]] || fail "Unexpected project number: ${PROJECT_NUMBER}"

if [[ -z "$REGION_HINT" ]]; then
  configured_region="$(gcloud config get-value compute/region 2>/dev/null || true)"
  if [[ -n "$configured_region" && "$configured_region" != "(unset)" ]]; then
    REGION_HINT="$configured_region"
    REGION_HINT_SOURCE="gcloud config"
  fi
fi

# ---------------------------------------------------------------------------------------------
# 2. Gateway
# ---------------------------------------------------------------------------------------------
section "GATEWAY  |  Select the Cloud Run HTTP proxy"
menu_item 1 "Envoy" "raw TCP/TLS passthrough option"
menu_item 2 "Nginx"
menu_item 3 "Caddy"
menu_item 4 "Traefik"
menu_item 5 "Unified Gateway (Caddy)" "default"
gateway_env="${XGCPX_GATEWAY:-}"
case "${gateway_env,,}" in envoy) gateway_env=1 ;; nginx) gateway_env=2 ;; caddy) gateway_env=3 ;; traefik) gateway_env=4 ;; unified) gateway_env=5 ;; esac
pick GATEWAY_CHOICE "$gateway_env" "Gateway" "Gateway [1-5, default 5]: " 5 5
case "$GATEWAY_CHOICE" in
  1) GATEWAY="envoy"; DOCKERFILE="proxies/envoy/Dockerfile" ;;
  2) GATEWAY="nginx"; DOCKERFILE="proxies/nginx/Dockerfile" ;;
  3) GATEWAY="caddy"; DOCKERFILE="proxies/caddy/Dockerfile" ;;
  4) GATEWAY="traefik"; DOCKERFILE="proxies/traefik/Dockerfile" ;;
  *) GATEWAY="unified"; DOCKERFILE="Dockerfile" ;;
esac
[[ -f "$DOCKERFILE" ]] || fail "The ${GATEWAY} gateway needs ${DOCKERFILE}, which does not exist in this repository."
success "Gateway: ${GATEWAY} (image built from ${DOCKERFILE})."

TCP_RANGES=()
TCP_UPSTREAM_HOST="tcp.example.com:9000"
TLS_UPSTREAM_HOST="tls.example.com:9443"
if [[ "$GATEWAY" == "envoy" ]]; then
  printf '\n'
  prompt_value TCP_UPSTREAM_HOST_INPUT "${XGCPX_TCP_UPSTREAM:-}" "Envoy TCP upstream host:port [${TCP_UPSTREAM_HOST}]: "
  TCP_UPSTREAM_HOST="${TCP_UPSTREAM_HOST_INPUT:-$TCP_UPSTREAM_HOST}"
  prompt_value TLS_UPSTREAM_HOST_INPUT "${XGCPX_TLS_UPSTREAM:-}" "Envoy TLS passthrough upstream host:port [${TLS_UPSTREAM_HOST}]: "
  TLS_UPSTREAM_HOST="${TLS_UPSTREAM_HOST_INPUT:-$TLS_UPSTREAM_HOST}"
  [[ "$TCP_UPSTREAM_HOST" =~ ^([A-Za-z0-9.-]+):[0-9]{1,5}$ ]] || fail "Use a valid TCP upstream host:port."
  [[ "$TLS_UPSTREAM_HOST" =~ ^([A-Za-z0-9.-]+):[0-9]{1,5}$ ]] || fail "Use a valid TLS upstream host:port."
  prompt_value TCP_SOURCE_RANGES "${XGCPX_TCP_SOURCE_RANGES:-}" "Optional CIDRs for Envoy VM TCP/TLS ports 9000/9443 (comma-separated, blank disables): "
  if [[ -n "$TCP_SOURCE_RANGES" ]]; then
    IFS=',' read -r -a TCP_RANGES <<<"$TCP_SOURCE_RANGES"
    for index in "${!TCP_RANGES[@]}"; do TCP_RANGES[index]="${TCP_RANGES[index]//[[:space:]]/}"; done
    for cidr in "${TCP_RANGES[@]}"; do
      [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || fail "Invalid IPv4 CIDR in TCP source list: $cidr"
    done
  fi
fi
ENABLE_TCP_PROXY=false
if [[ "$GATEWAY" == "envoy" && ${#TCP_RANGES[@]} -gt 0 ]]; then ENABLE_TCP_PROXY=true; fi

# ---------------------------------------------------------------------------------------------
# 3. Protocol runtime and services
# ---------------------------------------------------------------------------------------------
section "PROTOCOLS  |  Where services run and which ones to deploy"
menu_item 1 "Hybrid" "default: Xray services on a protocol VM"
menu_item 2 "Cloud Run" "HTTP transports in a sidecar; no VM needed"
runtime_env="${XGCPX_PROTOCOL_RUNTIME:-}"
case "${runtime_env,,}" in hybrid | vm) runtime_env=1 ;; cloud-run | cloudrun) runtime_env=2 ;; "" | 1 | 2) ;; *) fail "Set XGCPX_PROTOCOL_RUNTIME to vm or cloud-run." ;; esac
pick RUNTIME_CHOICE "$runtime_env" "Protocol runtime" "Protocol runtime [1/2, default 1]: " 1 2
if [[ "$RUNTIME_CHOICE" == "2" ]]; then PROTOCOL_RUNTIME="cloud-run"; else PROTOCOL_RUNTIME="vm"; fi
success "Protocol runtime: ${PROTOCOL_RUNTIME}."

# Raw TCP/UDP services stay on a static-IP VM; HTTP-compatible Xray transports can run in Cloud Run.
# Xray mux is client-side outbound behavior and does not create a separate server inbound or port.
printf '\n%sProtocol services%s %s(HTTP transports use the selected runtime)%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
menu_item 1 "VLESS WebSocket + HTTPUpgrade" "TLS on 443"
menu_item 2 "VLESS gRPC over HTTP/2" "443 and 50051"
menu_item 3 "VLESS xHTTP (packet/stream-up/one)" "443 and 8080"
if [[ "$PROTOCOL_RUNTIME" == "cloud-run" ]]; then
  menu_item 4 "Shadowsocks TCP/UDP" "VM-only; unavailable in Cloud Run mode"
else
  menu_item 4 "Shadowsocks TCP/UDP" "8388; mux is client-configured"
fi
menu_item 5 "OpenVPN over UDP (OPTIONAL)" "1194; VM only; never added by 'all'"
menu_item 6 "Trojan over TLS WS/HTTPUpgrade" "443"
menu_item 7 "VMess over TLS WebSocket" "443"
menu_item 8 "SSH over WebSocket" "generated password"
menu_item 9 "All Xray services" "default; OpenVPN NOT included (e.g. 9,5)"

declare -A OPTION_SEEN=()
PROTOCOL_OPTIONS=()
PARSE_ERROR=""
add_option() {
  if [[ -z "${OPTION_SEEN[$1]:-}" ]]; then
    OPTION_SEEN[$1]=1
    PROTOCOL_OPTIONS+=("$1")
  fi
}
parse_protocol_selection() {
  local selection="${1,,}" token option
  local -a tokens=() all_xray=()
  PARSE_ERROR=""
  PROTOCOL_OPTIONS=()
  OPTION_SEEN=()
  if [[ "$PROTOCOL_RUNTIME" == "cloud-run" ]]; then all_xray=(1 2 3 6 7 8); else all_xray=(1 2 3 4 6 7 8); fi
  selection="${selection//[[:space:]]/}"
  IFS=',' read -r -a tokens <<<"$selection"
  for token in "${tokens[@]}"; do
    case "$token" in
      all | 9) for option in "${all_xray[@]}"; do add_option "$option"; done ;;
      4)
        if [[ "$PROTOCOL_RUNTIME" == "cloud-run" ]]; then
          PARSE_ERROR="Shadowsocks needs raw TCP/UDP; choose the hybrid (VM) runtime or omit option 4."
          return 1
        fi
        add_option 4
        ;;
      [1-8]) add_option "$token" ;;
      "") ;;
      *)
        PARSE_ERROR="'${token}' is not valid. Use 1-8, 9/all, or a comma-separated list such as 1,3,6."
        return 1
        ;;
    esac
  done
  if ((${#PROTOCOL_OPTIONS[@]} == 0)); then
    PARSE_ERROR="Select at least one protocol service."
    return 1
  fi
}

PROTOCOL_SELECTION="${XGCPX_PROTOCOLS:-}"
if [[ -n "$PROTOCOL_SELECTION" ]]; then
  parse_protocol_selection "$PROTOCOL_SELECTION" || fail "$PARSE_ERROR"
elif [[ -t 0 ]]; then
  while :; do
    read -r -p "Protocols [1-8, 9/all, or comma-separated; default all]: " PROTOCOL_SELECTION || PROTOCOL_SELECTION=""
    PROTOCOL_SELECTION="${PROTOCOL_SELECTION:-all}"
    if parse_protocol_selection "$PROTOCOL_SELECTION"; then break; fi
    warn "$PARSE_ERROR"
  done
else
  parse_protocol_selection all
fi
# OpenVPN is only ever deployed when asked for explicitly (option 5, --openvpn, or XGCPX_OPENVPN=true).
if [[ "$WANT_OPENVPN" == "true" || "$WANT_OPENVPN" == "yes" || "$WANT_OPENVPN" == "1" ]]; then add_option 5; fi
has_option() { [[ " ${PROTOCOL_OPTIONS[*]} " == *" $1 "* ]]; }

PROTOCOL_TCP_PORTS=()
PROTOCOL_UDP_PORTS=()
if [[ "$PROTOCOL_RUNTIME" == "vm" ]]; then PROTOCOL_TCP_PORTS=(80 443); fi
PROTOCOL_TAGS=()
ENABLE_OPENVPN=false
ENABLE_PROTOCOL_VM=false
ENABLE_CLOUDRUN_PROTOCOLS=false
# Tags select transport-specific Xray inbounds; Shadowsocks mux is a compatible-client behavior, not a separate listener.
for protocol in "${PROTOCOL_OPTIONS[@]}"; do
  case "$protocol" in
    1) PROTOCOL_TAGS+=(vless-ws vless-httpupgrade) ;;
    2)
      PROTOCOL_TAGS+=(vless-grpc)
      if [[ "$PROTOCOL_RUNTIME" == "vm" ]]; then PROTOCOL_TCP_PORTS+=(50051); fi
      ;;
    3)
      PROTOCOL_TAGS+=(xhttp-packet xhttp-chunked xhttp-request-response)
      if [[ "$PROTOCOL_RUNTIME" == "vm" ]]; then PROTOCOL_TCP_PORTS+=(8080); fi
      ;;
    4)
      PROTOCOL_TAGS+=(shadowsocks)
      PROTOCOL_TCP_PORTS+=(8388)
      PROTOCOL_UDP_PORTS+=(8388)
      ;;
    5) ENABLE_OPENVPN=true; PROTOCOL_UDP_PORTS+=(1194) ;;
    6) PROTOCOL_TAGS+=(trojan-ws trojan-httpupgrade) ;;
    7) PROTOCOL_TAGS+=(vmess-ws) ;;
    8) PROTOCOL_TAGS+=(ssh-ws) ;;
  esac
done
if [[ "$PROTOCOL_RUNTIME" == "vm" && ${#PROTOCOL_TAGS[@]} -eq 0 && "$ENABLE_OPENVPN" == "true" ]]; then
  info "Only OpenVPN was selected; using the OpenVPN-only VM layout (no Xray container, no relay hostname needed)."
  PROTOCOL_RUNTIME="cloud-run"
  PROTOCOL_TCP_PORTS=()
fi
if [[ "$PROTOCOL_RUNTIME" == "vm" ]]; then
  ENABLE_PROTOCOL_VM=true
else
  ENABLE_PROTOCOL_VM="$ENABLE_OPENVPN"
  if ((${#PROTOCOL_TAGS[@]} > 0)); then ENABLE_CLOUDRUN_PROTOCOLS=true; fi
fi
if [[ "$ENABLE_OPENVPN" == "true" ]]; then
  command -v openssl >/dev/null 2>&1 || fail "OpenVPN certificate generation requires openssl."
  [[ -f proxies/openvpn/Dockerfile ]] || fail "OpenVPN was selected but proxies/openvpn/Dockerfile does not exist."
  warn "OpenVPN listens on UDP 1194 on the protocol VM's public IP; Cloud Run cannot relay UDP."
else
  success "OpenVPN: not selected, so no OpenVPN image, secret, certificate or UDP port is created."
fi
success "Selected services: ${PROTOCOL_OPTIONS[*]}"

prompt_value SERVICE_NAME "${XGCPX_SERVICE:-}" "Service name [${DEFAULT_SERVICE}]: "
SERVICE_NAME="${SERVICE_NAME:-$DEFAULT_SERVICE}"
[[ "$SERVICE_NAME" =~ ^[a-z]([-a-z0-9]{1,47}[a-z0-9])$ ]] || fail "Invalid Cloud Run service name (3-49 chars, lowercase letters, digits, hyphens): $SERVICE_NAME"

# ---------------------------------------------------------------------------------------------
# 4. Public hostname
# ---------------------------------------------------------------------------------------------
section "HOSTNAME  |  Automatic Google Cloud URL or a custom domain"
DNS_NAME_RE='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
menu_item "auto" "Automatic Cloud Run URL (*.run.app)" "default: no DNS, Google-managed TLS"
menu_item "host" "Custom domain" "adds load balancer, certificate, Cloud Armor"
DOMAIN=""
if [[ -n "${XGCPX_DOMAIN+x}" ]]; then
  DOMAIN="$(normalize_host "$XGCPX_DOMAIN")"
  if [[ "$DOMAIN" == "auto" ]]; then DOMAIN=""; fi
  if [[ -n "$DOMAIN" && "$DOMAIN" != *.run.app ]]; then
    [[ "$DOMAIN" =~ $DNS_NAME_RE ]] || fail "'${DOMAIN}' is not a valid DNS hostname. Leave it blank/auto for the automatic Cloud Run URL."
  fi
elif [[ -t 0 ]]; then
  while :; do
    read -r -p "Custom domain [Enter = automatic Google Cloud Run URL]: " DOMAIN_INPUT || DOMAIN_INPUT=""
    DOMAIN="$(normalize_host "$DOMAIN_INPUT")"
    if [[ -z "$DOMAIN" || "$DOMAIN" == "auto" ]]; then DOMAIN=""; break; fi
    if [[ "$DOMAIN" == *.run.app ]]; then break; fi
    if [[ "$DOMAIN" =~ $DNS_NAME_RE ]]; then break; fi
    warn "'${DOMAIN}' is not a valid DNS hostname; try again, or press Enter for the automatic URL."
  done
fi
if [[ "$DOMAIN" == *.run.app ]]; then
  warn "${DOMAIN} is a Cloud Run host, not a custom domain; using the automatic Cloud Run URL instead."
  DOMAIN=""
fi
USE_CLOUD_RUN_HOST=false
if [[ -z "$DOMAIN" ]]; then USE_CLOUD_RUN_HOST=true; fi
if [[ "$USE_CLOUD_RUN_HOST" == "true" ]]; then
  success "Public host: automatic Google Cloud Run URL (resolved after deploy)."
  info "No load balancer, certificate, DNS record, or Cloud Armor rule is created in this mode."
else
  success "Public host: ${DOMAIN} (global HTTPS load balancer + managed certificate)."
fi

NEED_VM=false
if [[ "$USE_CLOUD_RUN_HOST" != "true" || "$ENABLE_PROTOCOL_VM" == "true" || "$ENABLE_TCP_PROXY" == "true" ]]; then NEED_VM=true; fi

# ---------------------------------------------------------------------------------------------
# 5. Compute tier
# ---------------------------------------------------------------------------------------------
section "COMPUTE  |  VM tier"
MACHINE_TYPE="e2-small"
if [[ "$NEED_VM" != "true" ]]; then
  success "No Compute Engine VM is needed (automatic Cloud Run host, no protocol VM, no Envoy TCP proxy); skipping VM sizing."
else
  info "VMs: protocol VM = ${ENABLE_PROTOCOL_VM}; gateway VM = $([[ "$USE_CLOUD_RUN_HOST" != "true" || "$ENABLE_TCP_PROXY" == "true" ]] && echo true || echo false) (custom domain or Envoy TCP/TLS)."
  menu_item 1 "e2-micro" "2 shared vCPU, 1 GiB; maybe Always Free"
  menu_item 2 "e2-small" "default"
  menu_item 3 "e2-medium"
  menu_item 4 "c2-standard-4"
  menu_item 5 "c2d-highcpu-8"
  tier_env="${XGCPX_TIER:-}"
  case "${tier_env,,}" in e2-micro) tier_env=1 ;; e2-small) tier_env=2 ;; e2-medium) tier_env=3 ;; c2-standard-4) tier_env=4 ;; c2d-highcpu-8) tier_env=5 ;; esac
  pick TIER_CHOICE "$tier_env" "Compute tier" "Machine type [1-5, default 2]: " 2 5
  case "$TIER_CHOICE" in
    1) MACHINE_TYPE="e2-micro" ;;
    2) MACHINE_TYPE="e2-small" ;;
    3) MACHINE_TYPE="e2-medium" ;;
    4) MACHINE_TYPE="c2-standard-4" ;;
    *) MACHINE_TYPE="c2d-highcpu-8" ;;
  esac
  success "VM machine type: ${MACHINE_TYPE}."
  if [[ "$MACHINE_TYPE" == "e2-micro" ]]; then
    info "Each e2-micro VM uses a 15 GB pd-standard disk; gateway replicas are capped at one on e2-micro."
  else
    warn "${MACHINE_TYPE} is not an Always Free VM tier; check current GCP pricing and quotas."
  fi
fi
case "$MACHINE_TYPE" in
  e2-*) VCPU_COUNT=2; FAMILY_CPU_QUOTA="E2_CPUS" ;;
  c2-standard-4) VCPU_COUNT=4; FAMILY_CPU_QUOTA="C2_CPUS" ;;
  *) VCPU_COUNT=8; FAMILY_CPU_QUOTA="C2D_CPUS" ;;
esac

# ---------------------------------------------------------------------------------------------
# 6. Region
# ---------------------------------------------------------------------------------------------
section "LOCATION  |  Region"
if [[ "$NEED_VM" == "true" ]]; then
  info "Checking Cloud Run support, active Compute Engine regions, and ${MACHINE_TYPE} availability for ${PROJECT_ID}"
else
  info "Checking Cloud Run support and active Compute Engine regions for ${PROJECT_ID}"
fi
RUN_REGION_JSON_FILE="$(mktemp "${TMPDIR:-/tmp}/xgcpx-run-regions.XXXXXX")"
COMPUTE_REGION_JSON_FILE="$(mktemp "${TMPDIR:-/tmp}/xgcpx-compute-regions.XXXXXX")"
MACHINE_TYPE_JSON_FILE="$(mktemp "${TMPDIR:-/tmp}/xgcpx-machine-types.XXXXXX")"
if ! gcloud run regions list --project="$PROJECT_ID" --format=json >"$RUN_REGION_JSON_FILE"; then
  fail "Cannot query Cloud Run region support. Check run.locations.list permission, the Cloud Run API, and gcloud SDK version."
fi
if ! gcloud compute regions list --project="$PROJECT_ID" --filter='status=UP' --format=json >"$COMPUTE_REGION_JSON_FILE"; then
  fail "Cannot query active Compute Engine regions. Check compute.regions.list permission and the Compute Engine API."
fi
if [[ "$NEED_VM" == "true" ]]; then
  if ! gcloud compute machine-types list --project="$PROJECT_ID" --filter="name=${MACHINE_TYPE}" --format=json >"$MACHINE_TYPE_JSON_FILE"; then
    fail "Cannot query ${MACHINE_TYPE} availability. Check compute.machineTypes.list permission and the Compute Engine API."
  fi
else
  printf '[]' >"$MACHINE_TYPE_JSON_FILE"
fi
if ! REGION_ROWS="$(python3 - "$RUN_REGION_JSON_FILE" "$COMPUTE_REGION_JSON_FILE" "$MACHINE_TYPE_JSON_FILE" "$NEED_VM" <<'PY'
import json
import re
import sys

def load_json(path):
    with open(path, encoding="utf-8") as source:
        return json.load(source)

run_regions, compute_regions, machine_types = map(load_json, sys.argv[1:4])
need_vm = sys.argv[4] == "true"

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
names = run_names & compute_by_name.keys()
if need_vm:
    machine_regions = set()
    for item in machine_types:
        zone = item.get("zone") or item.get("selfLink", "")
        match = re.search(r"/zones/([^/]+)", zone)
        if match:
            zone = match.group(1)
        if zone:
            machine_regions.add(zone.rsplit("-", 1)[0])
    names &= machine_regions
for name in sorted(names):
    region = compute_by_name[name]
    description = region.get("description") or name
    print(name + "\t" + description)
PY
)"; then
  fail "Unable to parse live Cloud Run, Compute Engine, or machine-type region responses."
fi
# Honor the organization policy constraints/gcp.resourceLocations (common in lab and enterprise projects):
# drop regions where Cloud Run, Artifact Registry or the state bucket could not be created.
POLICY_JSON_FILE="$(mktemp "${TMPDIR:-/tmp}/xgcpx-location-policy.XXXXXX")"
{
  gcloud org-policies describe gcp.resourceLocations --effective --project="$PROJECT_ID" --format=json 2>/dev/null \
    || gcloud resource-manager org-policies describe gcp.resourceLocations --effective --project="$PROJECT_ID" --format=json 2>/dev/null \
    || printf '{}'
} >"$POLICY_JSON_FILE"
if ! POLICY_FILTERED="$(python3 - "$POLICY_JSON_FILE" "$REGION_ROWS" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        policy = json.load(source)
except ValueError:
    policy = {}
rows = [row for row in sys.argv[2].split("\n") if row]
allowed, denied = set(), set()

def collect(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "allowedValues":
                allowed.update(value)
            elif key == "deniedValues":
                denied.update(value)
            else:
                collect(value)
    elif isinstance(node, list):
        for item in node:
            collect(item)

collect(policy)

def matches(region, values):
    for value in values:
        value = value.strip()
        if value.startswith("in:"):
            value = value[3:]
        if value.endswith("-locations"):
            group = value[: -len("-locations")]
            group = "europe" if group == "eu" else group
            if region == group or region.startswith(group + "-"):
                return True
        elif value == region:
            return True
    return False

kept = []
for row in rows:
    name = row.split("\t", 1)[0]
    if allowed and not matches(name, allowed):
        continue
    if matches(name, denied):
        continue
    kept.append(row)
print("\n".join(kept))
if len(kept) != len(rows):
    print("REMOVED=%d" % (len(rows) - len(kept)), file=sys.stderr)
PY
)"; then
  POLICY_FILTERED="$REGION_ROWS"
fi
rm -f -- "$POLICY_JSON_FILE"
if [[ "$POLICY_FILTERED" != "$REGION_ROWS" ]]; then
  warn "An organization location policy (constraints/gcp.resourceLocations) applies; regions it forbids were removed from the list."
  REGION_ROWS="$POLICY_FILTERED"
fi
REGIONS=()
if [[ -n "$REGION_ROWS" ]]; then mapfile -t REGIONS <<<"$REGION_ROWS"; fi
((${#REGIONS[@]} > 0)) || fail "No region currently satisfies the availability checks (Cloud Run, Compute Engine UP, and ${MACHINE_TYPE} when a VM is needed) for this project."
# Exact region names only: a trailing glob would match europe-west10/12 against europe-west1.
region_flag() {
  case "$1" in
    us-central1) printf 'Iowa, USA' ;;
    us-east1) printf 'South Carolina, USA' ;;
    us-east4) printf 'Northern Virginia, USA' ;;
    us-east5) printf 'Columbus, USA' ;;
    us-south1) printf 'Dallas, USA' ;;
    us-west1) printf 'Oregon, USA' ;;
    us-west2) printf 'Los Angeles, USA' ;;
    us-west3) printf 'Salt Lake City, USA' ;;
    us-west4) printf 'Las Vegas, USA' ;;
    northamerica-northeast1) printf 'Montreal, Canada' ;;
    northamerica-northeast2) printf 'Toronto, Canada' ;;
    northamerica-south1) printf 'Mexico' ;;
    southamerica-east1) printf 'Sao Paulo, Brazil' ;;
    southamerica-west1) printf 'Santiago, Chile' ;;
    europe-west1) printf 'Belgium' ;;
    europe-west2) printf 'London, UK' ;;
    europe-west3) printf 'Frankfurt, Germany' ;;
    europe-west4) printf 'Netherlands' ;;
    europe-west6) printf 'Zurich, Switzerland' ;;
    europe-west8) printf 'Milan, Italy' ;;
    europe-west9) printf 'Paris, France' ;;
    europe-west10) printf 'Berlin, Germany' ;;
    europe-west12) printf 'Turin, Italy' ;;
    europe-north1) printf 'Finland' ;;
    europe-north2) printf 'Stockholm, Sweden' ;;
    europe-central2) printf 'Warsaw, Poland' ;;
    europe-southwest1) printf 'Madrid, Spain' ;;
    asia-east1) printf 'Taiwan' ;;
    asia-east2) printf 'Hong Kong' ;;
    asia-northeast1) printf 'Tokyo, Japan' ;;
    asia-northeast2) printf 'Osaka, Japan' ;;
    asia-northeast3) printf 'Seoul, South Korea' ;;
    asia-south1) printf 'Mumbai, India' ;;
    asia-south2) printf 'Delhi, India' ;;
    asia-south3) printf 'India' ;;
    asia-southeast1) printf 'Singapore' ;;
    asia-southeast2) printf 'Jakarta, Indonesia' ;;
    asia-southeast3) printf 'Bangkok, Thailand' ;;
    australia-southeast1) printf 'Sydney, Australia' ;;
    australia-southeast2) printf 'Melbourne, Australia' ;;
    me-central1) printf 'Doha, Qatar' ;;
    me-central2) printf 'Dammam, Saudi Arabia' ;;
    me-west1) printf 'Tel Aviv, Israel' ;;
    africa-south1) printf 'Johannesburg, South Africa' ;;
    *) printf '%s' "$2" ;;
  esac
}
region_name() { printf '%s' "${1%%$'\t'*}"; }
region_description() { printf '%s' "${1#*$'\t'}"; }

REGION=""
if [[ -n "$REGION_HINT" ]]; then
  for row in "${REGIONS[@]}"; do
    if [[ "$(region_name "$row")" == "$REGION_HINT" ]]; then REGION="$REGION_HINT"; break; fi
  done
  if [[ -n "$REGION" ]]; then
    info "Auto-selected ${REGION} from ${REGION_HINT_SOURCE} ($(region_flag "$REGION" "$REGION"))."
  elif [[ "$REGION_HINT_SOURCE" == "--region" || "$REGION_HINT_SOURCE" == "environment" ]]; then
    fail "Configured region '${REGION_HINT}' is not in the live availability set for project ${PROJECT_ID}."
  else
    warn "Configured gcloud region '${REGION_HINT}' is not available here; choose one below."
  fi
fi
if [[ -z "$REGION" ]]; then
  REGION_DEFAULT_INDEX=-1
  for index in "${!REGIONS[@]}"; do
    if [[ "$(region_name "${REGIONS[index]}")" == "us-central1" ]]; then REGION_DEFAULT_INDEX="$index"; break; fi
  done
  if [[ -t 0 ]]; then
    if ((REGION_DEFAULT_INDEX < 0)); then REGION_DEFAULT_INDEX=0; fi
    for index in "${!REGIONS[@]}"; do
      region="$(region_name "${REGIONS[index]}")"
      description="$(region_description "${REGIONS[index]}")"
      suffix=""
      if ((index == REGION_DEFAULT_INDEX)); then suffix=" (default)"; fi
      printf '  %s%2d)%s %-26s %s%s%s\n' "$BOLD" "$((index + 1))" "$RESET" "$region" "$DIM" "$(region_flag "$region" "$description")${suffix}" "$RESET"
    done
    pick REGION_CHOICE "" "Region" "Region [1-${#REGIONS[@]}, default $((REGION_DEFAULT_INDEX + 1))]: " "$((REGION_DEFAULT_INDEX + 1))" "${#REGIONS[@]}"
    REGION="$(region_name "${REGIONS[$((REGION_CHOICE - 1))]}")"
  elif ((REGION_DEFAULT_INDEX >= 0)); then
    REGION="us-central1"
    warn "No region is configured; using us-central1. Set XGCPX_REGION or pass --region to choose another location."
  else
    fail "No region is configured and us-central1 is unavailable. Set XGCPX_REGION, CLOUDSDK_COMPUTE_REGION, or pass --region."
  fi
fi
success "Region: ${REGION} ($(region_flag "$REGION" "$REGION"))."
if [[ "$NEED_VM" == "true" && "$MACHINE_TYPE" == "e2-micro" ]]; then
  case "$REGION" in
    us-central1 | us-west1 | us-east1)
      info "e2-micro in ${REGION} may qualify for Always Free within current monthly limits; the protocol VM is additional to any gateway VM."
      ;;
    *)
      warn "e2-micro is billed normally in ${REGION}; Always Free applies only in us-central1, us-west1 and us-east1."
      ;;
  esac
  warn "Disks, load balancers, Cloud Armor, Cloud Run, static IPs and network egress may also incur charges."
fi

# Pin the protocol VM to a zone that actually lists the machine type.
PROTOCOL_ZONE=""
if [[ "$ENABLE_PROTOCOL_VM" == "true" ]]; then
  PROTOCOL_ZONE="$(python3 - "$MACHINE_TYPE_JSON_FILE" "$REGION" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    machine_types = json.load(source)
region = sys.argv[2]
zones = set()
for item in machine_types:
    zone = item.get("zone") or item.get("selfLink", "")
    match = re.search(r"/zones/([^/]+)", zone)
    if match:
        zone = match.group(1)
    if zone and zone.rsplit("-", 1)[0] == region:
        zones.add(zone)
print(sorted(zones)[0] if zones else "")
PY
)"
  [[ -n "$PROTOCOL_ZONE" ]] || fail "No ${REGION} zone lists ${MACHINE_TYPE}; choose another region or tier."
fi

if [[ "$USE_CLOUD_RUN_HOST" == "true" ]]; then
  DOMAIN="${SERVICE_NAME}-${PROJECT_NUMBER}.${REGION}.run.app"
  info "Predicted automatic host: ${DOMAIN} (the real URL is read back after deploy)."
fi

# ---------------------------------------------------------------------------------------------
# 7. Upstream, relay hostname, security
# ---------------------------------------------------------------------------------------------
section "NETWORK  |  Relay hostname, upstream, access rules"
RELAY_DOMAIN=""
RELAY_AUTO=false
if [[ "$PROTOCOL_RUNTIME" == "vm" ]]; then
  if [[ "$USE_CLOUD_RUN_HOST" == "true" ]]; then
    relay_hint="automatic <vm-ip>.sslip.io, no DNS needed"
  else
    relay_hint="relay.${DOMAIN}; type 'auto' for <vm-ip>.sslip.io"
  fi
  prompt_value RELAY_INPUT "${XGCPX_RELAY_DOMAIN:-}" "Protocol VM hostname for Caddy TLS [blank = ${relay_hint}]: "
  RELAY_INPUT="$(normalize_host "$RELAY_INPUT")"
  if [[ "$RELAY_INPUT" == "auto" ]]; then
    RELAY_AUTO=true
  elif [[ -n "$RELAY_INPUT" ]]; then
    RELAY_DOMAIN="$RELAY_INPUT"
  elif [[ "$USE_CLOUD_RUN_HOST" == "true" ]]; then
    RELAY_AUTO=true
  else
    RELAY_DOMAIN="relay.${DOMAIN}"
  fi
  if [[ -n "$RELAY_DOMAIN" ]]; then
    [[ "$RELAY_DOMAIN" =~ $DNS_NAME_RE ]] || fail "The protocol VM hostname is not a valid DNS hostname."
    ((${#RELAY_DOMAIN} <= 253)) || fail "The protocol hostname exceeds the DNS name length limit."
    success "Protocol VM hostname: ${RELAY_DOMAIN} (create an A record to the VM IP printed after deploy; Caddy retries until it resolves)."
  else
    success "Protocol VM hostname: automatic <vm-ip>.sslip.io (Let's Encrypt over port 80; the certificate issues a minute or two after boot)."
  fi
fi

prompt_value UPSTREAM_PRIMARY_INPUT "${XGCPX_UPSTREAM:-}" "Optional HTTPS application upstream [blank uses the built-in Cloud Run API]: "
if [[ -z "$UPSTREAM_PRIMARY_INPUT" ]]; then
  UPSTREAM_PRIMARY="http://127.0.0.1:8081"
  UPSTREAM_FALLBACK="$UPSTREAM_PRIMARY"
  success "Upstream: built-in Cloud Run API sidecar (no self-referential domain upstream)."
else
  UPSTREAM_PRIMARY="$UPSTREAM_PRIMARY_INPUT"
  [[ "$UPSTREAM_PRIMARY" == https://* ]] || fail "Use an HTTPS URL, or leave this blank for the built-in Cloud Run API."
  case "$UPSTREAM_PRIMARY" in *[[:space:]]* | *\"* | *\\*) fail "Upstream URL contains unsupported whitespace or quoting." ;; esac
  validate_https_upstream "$UPSTREAM_PRIMARY" || fail "Enter a valid HTTPS upstream URL without credentials, query, or fragment."
  upstream_host="$(url_hostname "$UPSTREAM_PRIMARY")"
  [[ "${upstream_host,,}" != "${DOMAIN,,}" && (-z "$RELAY_DOMAIN" || "${upstream_host,,}" != "${RELAY_DOMAIN,,}") ]] \
    || fail "The upstream cannot use the gateway or relay hostname; that would proxy back into this deployment."
  prompt_value UPSTREAM_FALLBACK "${XGCPX_UPSTREAM_FALLBACK:-}" "Fallback HTTPS application upstream URL [same as primary]: "
  UPSTREAM_FALLBACK="${UPSTREAM_FALLBACK:-$UPSTREAM_PRIMARY}"
  [[ "$UPSTREAM_FALLBACK" == https://* ]] || fail "Use an HTTPS fallback URL."
  case "$UPSTREAM_FALLBACK" in *[[:space:]]* | *\"* | *\\*) fail "Fallback URL contains unsupported whitespace or quoting." ;; esac
  validate_https_upstream "$UPSTREAM_FALLBACK" || fail "Enter a valid HTTPS fallback URL without credentials, query, or fragment."
  fallback_host="$(url_hostname "$UPSTREAM_FALLBACK")"
  [[ "${fallback_host,,}" != "${DOMAIN,,}" && (-z "$RELAY_DOMAIN" || "${fallback_host,,}" != "${RELAY_DOMAIN,,}") ]] \
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

BLOCKED_CIDRS=()
ALLOWED_CIDRS=()
if [[ "$USE_CLOUD_RUN_HOST" == "true" ]]; then
  info "Cloud Armor rules skipped: they need the load balancer, which only exists with a custom domain."
else
  prompt_value BLOCKED_CIDR_INPUT "${XGCPX_BLOCKED_CIDRS:-}" "Cloud Armor deny CIDRs (comma-separated, blank for none): "
  prompt_value ALLOWED_CIDR_INPUT "${XGCPX_ALLOWED_CIDRS:-}" "Cloud Armor allow CIDRs (comma-separated, blank for unrestricted): "
  if [[ -n "$BLOCKED_CIDR_INPUT" ]]; then IFS=',' read -r -a BLOCKED_CIDRS <<<"$BLOCKED_CIDR_INPUT"; fi
  if [[ -n "$ALLOWED_CIDR_INPUT" ]]; then IFS=',' read -r -a ALLOWED_CIDRS <<<"$ALLOWED_CIDR_INPUT"; fi
  for index in "${!BLOCKED_CIDRS[@]}"; do BLOCKED_CIDRS[index]="${BLOCKED_CIDRS[index]//[[:space:]]/}"; done
  for index in "${!ALLOWED_CIDRS[@]}"; do ALLOWED_CIDRS[index]="${ALLOWED_CIDRS[index]//[[:space:]]/}"; done
  for cidr in "${BLOCKED_CIDRS[@]}" "${ALLOWED_CIDRS[@]}"; do
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || fail "Invalid IPv4 CIDR: $cidr"
  done
  if ((${#ALLOWED_CIDRS[@]} > 0)); then
    warn "Cloud Armor will deny every client IP not present in the allowlist."
  fi
fi

# Quota is checked last because the gateway VM only exists with a load balancer or the Envoy TCP proxy.
check_regional_quota() {
  local gateway_vms=1 total_vms recommended_vms report="" quota_status=0 minimum recommended region_json
  if [[ "$USE_CLOUD_RUN_HOST" == "true" && "$ENABLE_TCP_PROXY" != "true" ]]; then gateway_vms=0; fi
  total_vms="$gateway_vms"
  if [[ "$ENABLE_PROTOCOL_VM" == "true" ]]; then total_vms=$((total_vms + 1)); fi
  if ((total_vms == 0)); then
    success "No Compute Engine VM will be created, so no CPU quota check is needed."
    return 0
  fi
  recommended_vms="$total_vms"
  if ((gateway_vms > 0)) && [[ "$MACHINE_TYPE" != "e2-micro" ]]; then recommended_vms=$((recommended_vms + 2)); fi
  minimum=$((VCPU_COUNT * total_vms))
  recommended=$((VCPU_COUNT * recommended_vms))
  region_json="$(gcloud compute regions describe "$REGION" --project="$PROJECT_ID" --format=json)" \
    || fail "Cannot inspect regional quotas for ${REGION}. Check compute.regions.get permission."
  if report="$(python3 - "$region_json" "$FAMILY_CPU_QUOTA" "$minimum" "$recommended" <<'PY'
import json
import sys

region = json.loads(sys.argv[1])
family_metric = sys.argv[2]
minimum = float(sys.argv[3])
recommended = float(sys.argv[4])
quotas = {item["metric"]: item for item in region.get("quotas", [])}
metrics = [metric for metric in (family_metric, "CPUS") if metric in quotas]
if not metrics:
    print("UNKNOWN\t0\t0\t0")
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
  local metric available limit usage
  while IFS=$'\t' read -r metric available limit usage; do
    [[ -n "$metric" ]] || continue
    if [[ "$metric" == "UNKNOWN" ]]; then
      warn "Regional CPU quota was not returned by the API; the Terraform plan is still required to confirm eligibility."
    else
      info "Regional quota ${metric}: ${available} CPU(s) free of ${limit} (${usage} in use)."
    fi
  done <<<"$report"
  case "$quota_status" in
    0) ;;
    2) fail "Current ${REGION} CPU quota is below the ${minimum} vCPU minimum for ${total_vms} VM(s). Request quota in Cloud Console or choose a smaller tier." ;;
    3) warn "Quota covers the ${total_vms} initial VM(s) but not the ${recommended} vCPU recommended for gateway autoscaling." ;;
    *) fail "Unable to evaluate regional CPU quotas (status ${quota_status})." ;;
  esac
  success "Quota covers the ${total_vms} initial VM(s); it cannot guarantee future zonal capacity or organization-policy approval."
}
check_regional_quota

# ---------------------------------------------------------------------------------------------
# 8. Review
# ---------------------------------------------------------------------------------------------
protocol_label() {
  case "$1" in
    1) printf 'VLESS WS/HTTPUpgrade' ;;
    2) printf 'VLESS gRPC' ;;
    3) printf 'VLESS xHTTP' ;;
    4) printf 'Shadowsocks' ;;
    5) printf 'OpenVPN' ;;
    6) printf 'Trojan' ;;
    7) printf 'VMess' ;;
    8) printf 'SSH-WS' ;;
  esac
}
section "REVIEW  |  Deployment plan"
labels=""
for option in "${PROTOCOL_OPTIONS[@]}"; do labels+="$(protocol_label "$option"), "; done
kv "Project" "$PROJECT_ID"
kv "Service" "$SERVICE_NAME"
kv "Region" "${REGION} ($(region_flag "$REGION" "$REGION"))"
kv "Gateway" "$GATEWAY"
if [[ "$USE_CLOUD_RUN_HOST" == "true" ]]; then
  kv "Public host" "automatic Cloud Run URL"
else
  kv "Public host" "${DOMAIN} (load balancer + managed cert)"
fi
kv "Protocol runtime" "$PROTOCOL_RUNTIME"
kv "Services" "${labels%, }"
kv "OpenVPN" "$([[ "$ENABLE_OPENVPN" == "true" ]] && echo "yes (UDP 1194 on the protocol VM)" || echo "no")"
kv "VM tier" "$([[ "$NEED_VM" == "true" ]] && echo "$MACHINE_TYPE" || echo "none (no VM needed)")"
if [[ "${ASSUME_YES,,}" != "true" ]]; then
  printf '\n'
  read -r -p "Build and deploy this plan? [Y/n]: " CONFIRM_PLAN || CONFIRM_PLAN=""
  case "${CONFIRM_PLAN,,}" in "" | y | yes) ;; *) fail "Cancelled; no resources were created." ;; esac
fi

# Serialize Bash arguments as a JSON list for Terraform list(string) variables.
json_array() {
  local result="[" item
  for item in "$@"; do result+="\"${item}\","; done
  printf '%s]\n' "${result%,}"
}

# ---------------------------------------------------------------------------------------------
# 9. Build images and credentials
# ---------------------------------------------------------------------------------------------
section "BUILD  |  State bucket, images, protocol credentials"
STATE_BUCKET="${PROJECT_ID}-xgcpx-tfstate"
if BUCKET_JSON="$(gcloud storage buckets describe "gs://${STATE_BUCKET}" --format=json 2>/dev/null)"; then
  # gcloud storage reports project_number; older output used projectNumber. Accept either.
  BUCKET_PROJECT_NUMBER="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("project_number") or d.get("projectNumber") or "")' "$BUCKET_JSON")"
  if [[ -z "$BUCKET_PROJECT_NUMBER" ]]; then
    warn "Could not read the owner of gs://${STATE_BUCKET}; continuing because the bucket name is derived from this project ID."
  else
    [[ "$BUCKET_PROJECT_NUMBER" == "$PROJECT_NUMBER" ]] || fail "Terraform state bucket exists but is not owned by project ${PROJECT_ID}."
  fi
else
  info "Creating private Terraform state bucket gs://${STATE_BUCKET}"
  if ! gcloud storage buckets create "gs://${STATE_BUCKET}" --location="$REGION" --project="$PROJECT_ID" \
    --uniform-bucket-level-access --public-access-prevention; then
    fail "Could not create the state bucket in ${REGION}. If the error mentions constraints/gcp.resourceLocations, this project only allows certain locations: re-run with --region set to an allowed one (see the project's location policy, or your lab instructions)."
  fi
fi
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning --public-access-prevention \
  --uniform-bucket-level-access --project="$PROJECT_ID" >/dev/null

AR_REPO="${APP_NAME}-images"
if ! gcloud artifacts repositories describe "$AR_REPO" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION" \
    --description="xgcpx gateway images" --project="$PROJECT_ID" --quiet
fi
DEPLOY_TAG="$(date -u +%Y%m%d%H%M%S)"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${GATEWAY}-${DEPLOY_TAG}"
BACKEND_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:backend-${DEPLOY_TAG}"
PROTOCOL_IMAGE_TAG="protocol-${DEPLOY_TAG}"
PROTOCOL_IMAGE=""
PROTOCOL_SECRET_NAME=""
PROTOCOL_SECRET_VERSION=""
# The Xray image and secret are only needed when at least one Xray transport is selected.
if ((${#PROTOCOL_TAGS[@]} > 0)); then
  PROTOCOL_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${PROTOCOL_IMAGE_TAG}"
  PROTOCOL_SECRET_NAME="${SERVICE_NAME}-protocol-config"
fi
OPENVPN_IMAGE=""
OPENVPN_SECRET_NAME=""
OPENVPN_SECRET_VERSION=""
if [[ "$ENABLE_OPENVPN" == "true" ]]; then
  OPENVPN_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:openvpn-${DEPLOY_TAG}"
  OPENVPN_SECRET_NAME="${SERVICE_NAME}-openvpn-config"
fi
PROTOCOL_VM_IMAGE="$PROTOCOL_IMAGE"
if [[ "$PROTOCOL_RUNTIME" == "cloud-run" ]]; then PROTOCOL_VM_IMAGE=""; fi

# Build the VM bootstrap script from only the pieces that were selected (no OpenVPN code unless OpenVPN is on).
build_startup_script() {
  local images="" script="" xray_block="" ovpn_block=""
  if [[ -n "$PROTOCOL_VM_IMAGE" ]]; then images+="${PROTOCOL_VM_IMAGE} "; fi
  if [[ -n "$OPENVPN_IMAGE" ]]; then images+="${OPENVPN_IMAGE} "; fi
  read -r -d '' script <<'STARTUP_HEAD_EOF' || true
#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

metadata="http://metadata.google.internal/computeMetadata/v1"
registry="__REGION__-docker.pkg.dev"
images="__IMAGES__"

daemon_attempt=0
until docker info >/dev/null 2>&1; do
  daemon_attempt=$((daemon_attempt + 1))
  if [ "$daemon_attempt" -ge 60 ]; then
    printf '%s\n' "Docker did not become ready before the startup timeout." >&2
    exit 1
  fi
  sleep 2
done

export DOCKER_CONFIG=/run/xgcpx-docker-auth
mkdir -p "$DOCKER_CONFIG"
chmod 0700 "$DOCKER_CONFIG"
cleanup_auth() {
  docker logout "https://${registry}" >/dev/null 2>&1 || true
  rm -rf -- "$DOCKER_CONFIG"
}
trap cleanup_auth EXIT
pull_all() {
  local token_json access_token image
  token_json="$(curl --fail --silent --show-error --connect-timeout 3 --max-time 15 \
    --header 'Metadata-Flavor: Google' \
    "$metadata/instance/service-accounts/default/token")" || return 1
  access_token="$(printf '%s' "$token_json" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  [ -n "$access_token" ] || return 1
  printf '%s' "$access_token" | docker login --username oauth2accesstoken --password-stdin "https://${registry}" || return 1
  for image in $images; do
    docker pull "$image" || return 1
  done
}
attempt=0
until pull_all; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 12 ]; then
    printf '%s\n' "Could not pull the protocol images from Artifact Registry." >&2
    exit 1
  fi
  sleep 10
done
cleanup_auth
trap - EXIT
STARTUP_HEAD_EOF
  if [[ -n "$PROTOCOL_VM_IMAGE" ]]; then
    read -r -d '' xray_block <<'STARTUP_XRAY_EOF' || true

# Without a configured relay hostname, derive <static-ip>.sslip.io from the VM's own external IP.
relay_domain="__PROTOCOL_DOMAIN__"
if [ -z "$relay_domain" ]; then
  external_ip=""
  ip_attempt=0
  while [ -z "$external_ip" ] && [ "$ip_attempt" -lt 30 ]; do
    external_ip="$(curl --fail --silent --connect-timeout 3 --max-time 10 \
      --header 'Metadata-Flavor: Google' \
      "$metadata/instance/network-interfaces/0/access-configs/0/external-ip" || true)"
    if [ -z "$external_ip" ]; then
      ip_attempt=$((ip_attempt + 1))
      sleep 5
    fi
  done
  if [ -z "$external_ip" ]; then
    printf '%s\n' "Could not read the VM external IP to derive the relay hostname." >&2
    exit 1
  fi
  relay_domain="$(printf '%s' "$external_ip" | tr . -).sslip.io"
fi
mkdir -p /var/lib/xgcpx/caddy-data /var/lib/xgcpx/caddy-config
chown 10001:10001 /var/lib/xgcpx/caddy-data /var/lib/xgcpx/caddy-config
chmod 0750 /var/lib/xgcpx/caddy-data /var/lib/xgcpx/caddy-config
docker rm --force xgcpx-protocols >/dev/null 2>&1 || true
docker run --detach --name xgcpx-protocols --restart always \
  --ulimit nofile=1048576:1048576 \
  --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
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
  --env RELAY_DOMAIN="$relay_domain" \
  "__PROTOCOL_VM_IMAGE__"
STARTUP_XRAY_EOF
  fi
  if [[ -n "$OPENVPN_IMAGE" ]]; then
    read -r -d '' ovpn_block <<'STARTUP_OVPN_EOF' || true

docker rm --force xgcpx-openvpn >/dev/null 2>&1 || true
docker run --detach --name xgcpx-openvpn --restart always \
  --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
  --publish 1194:1194/udp \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --env PROJECT_ID="__PROJECT_ID__" \
  --env OPENVPN_SECRET_NAME="__OPENVPN_SECRET_NAME__" \
  "__OPENVPN_IMAGE__"
STARTUP_OVPN_EOF
  fi
  script+=$'\n'
  if [[ -n "$xray_block" ]]; then script+="${xray_block}"$'\n'; fi
  if [[ -n "$ovpn_block" ]]; then script+="${ovpn_block}"$'\n'; fi
  script="${script//__REGION__/$REGION}"
  script="${script//__IMAGES__/${images% }}"
  script="${script//__PROJECT_ID__/$PROJECT_ID}"
  script="${script//__PROTOCOL_VM_IMAGE__/$PROTOCOL_VM_IMAGE}"
  script="${script//__PROTOCOL_SECRET_NAME__/$PROTOCOL_SECRET_NAME}"
  script="${script//__PROTOCOL_DOMAIN__/$RELAY_DOMAIN}"
  script="${script//__OPENVPN_IMAGE__/$OPENVPN_IMAGE}"
  script="${script//__OPENVPN_SECRET_NAME__/$OPENVPN_SECRET_NAME}"
  printf '%s\n' "$script"
}
PROTOCOL_STARTUP_SCRIPT=""
if [[ "$ENABLE_PROTOCOL_VM" == "true" ]]; then PROTOCOL_STARTUP_SCRIPT="$(build_startup_script)"; fi

run_with_spinner "Configuring Artifact Registry authentication" gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
run_with_spinner "Building ${GATEWAY} gateway image" docker build --platform linux/amd64 --file "$DOCKERFILE" --tag "$IMAGE" .
run_with_spinner "Pushing ${GATEWAY} gateway image" docker push "$IMAGE"

run_with_spinner "Building the built-in Cloud Run API backend" docker build --platform linux/amd64 \
  --file backend/Dockerfile --tag "$BACKEND_IMAGE" backend
run_with_spinner "Pushing the built-in Cloud Run API backend" docker push "$BACKEND_IMAGE"

if [[ -n "$PROTOCOL_IMAGE" ]]; then
  run_with_spinner "Building the Xray protocol runtime image" docker build --platform linux/amd64 --file proxies/xray/Dockerfile --tag "$PROTOCOL_IMAGE" .
  run_with_spinner "Pushing the Xray protocol runtime image" docker push "$PROTOCOL_IMAGE"
fi
if [[ "$ENABLE_OPENVPN" == "true" ]]; then
  run_with_spinner "Building the OpenVPN VM image" docker build --platform linux/amd64 --file proxies/openvpn/Dockerfile --tag "$OPENVPN_IMAGE" .
  run_with_spinner "Pushing the OpenVPN VM image" docker push "$OPENVPN_IMAGE"
fi

# Private output directory for generated client profiles and credentials (git-ignored, mode 0700).
OUTPUT_DIR="${PWD}/xgcpx-output"
mkdir -p "$OUTPUT_DIR"
chmod 0700 "$OUTPUT_DIR"
printf '*\n' >"$OUTPUT_DIR/.gitignore"

PROTOCOL_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
VMESS_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
SHADOWSOCKS_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
TROJAN_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
SSH_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
if [[ -n "$PROTOCOL_IMAGE" ]]; then
  PROTOCOL_CONFIG_FILE="$(mktemp)"
  chmod 0600 "$PROTOCOL_CONFIG_FILE"
  PROTOCOL_TAGS_JSON="$(json_array "${PROTOCOL_TAGS[@]}")"
  SSH_CONFIG_PASSWORD=""
  if has_option 8; then SSH_CONFIG_PASSWORD="$SSH_PASSWORD"; fi
  PROTOCOL_TAGS_JSON="$PROTOCOL_TAGS_JSON" \
  VLESS_UUID="$PROTOCOL_UUID" \
  VMESS_UUID="$VMESS_UUID" \
  SHADOWSOCKS_PASSWORD="$SHADOWSOCKS_PASSWORD" \
  TROJAN_PASSWORD="$TROJAN_PASSWORD" \
  SSH_PASSWORD="$SSH_CONFIG_PASSWORD" \
  python3 - "$PROTOCOL_CONFIG_FILE" proxies/xray/config.json <<'PY'
import json
import os
import sys

enabled_tags = set(json.loads(os.environ["PROTOCOL_TAGS_JSON"]))
vless_uuid = os.environ["VLESS_UUID"]
vmess_uuid = os.environ["VMESS_UUID"]
shadowsocks_password = os.environ["SHADOWSOCKS_PASSWORD"]
trojan_password = os.environ["TROJAN_PASSWORD"]
ssh_password = os.environ["SSH_PASSWORD"]
output_path, template_path = sys.argv[1:]
with open(template_path, encoding="utf-8") as source:
    config = json.load(source)
config["inbounds"] = [
    inbound for inbound in config["inbounds"]
    if inbound["tag"] in enabled_tags
]
missing = enabled_tags - {inbound["tag"] for inbound in config["inbounds"]} - {"ssh-ws"}
if missing:
    raise SystemExit("proxies/xray/config.json has no inbound for: " + ", ".join(sorted(missing)))
for inbound in config["inbounds"]:
    settings = inbound["settings"]
    if inbound["protocol"] == "vless":
        for client in settings["clients"]:
            client["id"] = vless_uuid
    elif inbound["protocol"] == "vmess":
        for client in settings["clients"]:
            client["id"] = vmess_uuid
    elif inbound["protocol"] == "shadowsocks":
        settings["password"] = shadowsocks_password
    elif inbound["protocol"] == "trojan":
        for client in settings["clients"]:
            client["password"] = trojan_password
with open(output_path, "w", encoding="utf-8") as destination:
    json.dump(
        {"xray_config": config, "ssh_password": ssh_password},
        destination,
        indent=2,
    )
    destination.write("\n")
PY
  if ! gcloud secrets describe "$PROTOCOL_SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud secrets create "$PROTOCOL_SECRET_NAME" --replication-policy=automatic --project="$PROJECT_ID"
  fi
  PROTOCOL_SECRET_VERSION="$(gcloud secrets versions add "$PROTOCOL_SECRET_NAME" \
    --data-file="$PROTOCOL_CONFIG_FILE" --project="$PROJECT_ID" --format='value(name)')"
  rm -f -- "$PROTOCOL_CONFIG_FILE"
  PROTOCOL_CONFIG_FILE=""
  success "Xray configuration stored in Secret Manager (${PROTOCOL_SECRET_NAME})."
fi

# Write private client configs only after Terraform apply succeeds.
generate_client_profiles() {
  CLIENT_PROFILE_REPORT="$(PROTOCOL_TAGS_JSON="$(json_array "${PROTOCOL_TAGS[@]}")" \
VLESS_UUID="$PROTOCOL_UUID" \
VMESS_UUID="$VMESS_UUID" \
SHADOWSOCKS_PASSWORD="$SHADOWSOCKS_PASSWORD" \
TROJAN_PASSWORD="$TROJAN_PASSWORD" \
EDGE_DOMAIN="$DOMAIN" \
RELAY_DOMAIN="$RELAY_ENDPOINT" \
DEPLOY_TAG="$DEPLOY_TAG" \
python3 - "$OUTPUT_DIR" <<'PY'
import json
import os
import sys
from pathlib import Path

selected = set(json.loads(os.environ["PROTOCOL_TAGS_JSON"]))
edge_domain = os.environ["EDGE_DOMAIN"]
relay_domain = os.environ["RELAY_DOMAIN"]
vless_uuid = os.environ["VLESS_UUID"]
vmess_uuid = os.environ["VMESS_UUID"]
shadowsocks_password = os.environ["SHADOWSOCKS_PASSWORD"]
trojan_password = os.environ["TROJAN_PASSWORD"]
deploy_tag = os.environ["DEPLOY_TAG"]
directory = Path(sys.argv[1])
paths = {
  "vless-ws": ("vless", "ws", "/vless-ws", None),
  "vless-httpupgrade": ("vless", "httpupgrade", "/vless-httpupgrade", None),
  "vless-grpc": ("vless", "grpc", None, None),
  "xhttp-packet": ("vless", "xhttp", "/xhttp-packet", "packet-up"),
  "xhttp-chunked": ("vless", "xhttp", "/xhttp-chunked", "stream-up"),
  "xhttp-request-response": ("vless", "xhttp", "/xhttp-request-response", "stream-one"),
  "trojan-ws": ("trojan", "ws", "/trojan-ws", None),
  "trojan-httpupgrade": ("trojan", "httpupgrade", "/trojan-httpupgrade", None),
  "vmess-ws": ("vmess", "ws", "/vmess-ws", None),
}
tag_order = [
  "vless-ws", "vless-httpupgrade", "vless-grpc", "xhttp-packet",
  "xhttp-chunked", "xhttp-request-response", "trojan-ws",
  "trojan-httpupgrade", "vmess-ws", "shadowsocks",
]
report = []
for index, tag in enumerate(item for item in tag_order if item in selected):
  local_port = 10808 + index
  use_mux = True
  if tag == "shadowsocks":
    outbound = {
      "tag": "proxy",
      "protocol": "shadowsocks",
      "settings": {"servers": [{
        "address": relay_domain,
        "port": 8388,
        "method": "chacha20-ietf-poly1305",
        "password": shadowsocks_password,
      }]},
    }
  else:
    protocol, network, path, mode = paths[tag]
    if protocol == "vless":
      settings = {"vnext": [{"address": edge_domain, "port": 443, "users": [{"id": vless_uuid, "encryption": "none"}]}]}
    elif protocol == "vmess":
      settings = {"vnext": [{"address": edge_domain, "port": 443, "users": [{"id": vmess_uuid, "alterId": 0, "security": "auto"}]}]}
    else:
      settings = {"servers": [{"address": edge_domain, "port": 443, "password": trojan_password}]}
    h2_transport = network in ("grpc", "xhttp")
    stream_settings = {
      "network": network,
      "security": "tls",
      "tlsSettings": {
        "serverName": edge_domain,
        "allowInsecure": False,
        "fingerprint": "chrome",
        "alpn": ["h2"] if h2_transport else ["http/1.1"],
      },
    }
    if network == "ws":
      stream_settings["wsSettings"] = {"path": path}
    elif network == "httpupgrade":
      stream_settings["httpupgradeSettings"] = {"path": path}
    elif network == "grpc":
      stream_settings["grpcSettings"] = {"serviceName": "vless-grpc"}
    elif network == "xhttp":
      stream_settings["xhttpSettings"] = {"path": path, "mode": mode}
    # gRPC and xHTTP multiplex natively; Xray mux on top of them only adds overhead.
    use_mux = not h2_transport
    outbound = {
      "tag": "proxy",
      "protocol": protocol,
      "settings": settings,
      "streamSettings": stream_settings,
    }
  if use_mux:
    outbound["mux"] = {"enabled": True, "concurrency": 8}
  config = {
    "log": {"loglevel": "warning"},
    "inbounds": [{
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": local_port,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": True},
    }],
    "outbounds": [outbound, {"tag": "direct", "protocol": "freedom"}],
  }
  profile = directory / f"xray-client-{deploy_tag}-{tag}.json"
  descriptor = os.open(profile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
  with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
    json.dump(config, destination, indent=2)
    destination.write("\n")
  os.chmod(profile, 0o600)
  report.append(f"  {tag}: {profile} (local SOCKS 127.0.0.1:{local_port}; mux {'on' if use_mux else 'off'})")
print("\n".join(report))
PY
  )"
}

if [[ "$ENABLE_OPENVPN" == "true" ]]; then
  OPENVPN_PKI_DIR="$(mktemp -d)"
  chmod 0700 "$OPENVPN_PKI_DIR"
  run_with_spinner "Generating the OpenVPN certificate authority and keys" bash -c '
    set -Eeuo pipefail
    dir="$1"
    openssl genrsa -out "$dir/ca.key" 4096
    openssl req -x509 -new -sha256 -days 3650 -key "$dir/ca.key" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -subj "/CN=xgcpx-openvpn-ca" -out "$dir/ca.crt"
    for role in server client; do
      usage=clientAuth
      if [ "$role" = server ]; then usage=serverAuth; fi
      openssl genrsa -out "$dir/$role.key" 2048
      openssl req -new -key "$dir/$role.key" -subj "/CN=xgcpx-openvpn-$role" -out "$dir/$role.csr"
      printf "%s\n" "basicConstraints=CA:FALSE" "keyUsage=digitalSignature,keyEncipherment" \
        "extendedKeyUsage=$usage" >"$dir/$role.ext"
      openssl x509 -req -in "$dir/$role.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -CAcreateserial \
        -days 825 -sha256 -extfile "$dir/$role.ext" -out "$dir/$role.crt"
    done
  ' _ "$OPENVPN_PKI_DIR"
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
  success "OpenVPN credentials stored in Secret Manager (${OPENVPN_SECRET_NAME})."
fi

# ---------------------------------------------------------------------------------------------
# 10. Terraform
# ---------------------------------------------------------------------------------------------
section "DEPLOY  |  Terraform"
export TF_VAR_project_id="$PROJECT_ID"
export TF_VAR_region="$REGION"
export TF_VAR_service_name="$SERVICE_NAME"
export TF_VAR_image="$IMAGE"
export TF_VAR_backend_image="$BACKEND_IMAGE"
export TF_VAR_machine_type="$MACHINE_TYPE"
export TF_VAR_domain="$DOMAIN"
export TF_VAR_use_cloud_run_host="$USE_CLOUD_RUN_HOST"
export TF_VAR_upstream_primary="$UPSTREAM_PRIMARY"
export TF_VAR_upstream_fallback="$UPSTREAM_FALLBACK"
export TF_VAR_blocked_cidrs="$(json_array "${BLOCKED_CIDRS[@]}")"
export TF_VAR_allowed_cidrs="$(json_array "${ALLOWED_CIDRS[@]}")"
export TF_VAR_tcp_upstream_host="$TCP_UPSTREAM_HOST"
export TF_VAR_tls_upstream_host="$TLS_UPSTREAM_HOST"
export TF_VAR_protocol_runtime="$PROTOCOL_RUNTIME"
export TF_VAR_enable_cloudrun_protocols="$ENABLE_CLOUDRUN_PROTOCOLS"
export TF_VAR_enable_protocol_gateway="$ENABLE_PROTOCOL_VM"
export TF_VAR_protocol_image="$PROTOCOL_IMAGE"
export TF_VAR_protocol_domain="$RELAY_DOMAIN"
export TF_VAR_protocol_zone="$PROTOCOL_ZONE"
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
export TF_VAR_enable_tcp_proxy="$ENABLE_TCP_PROXY"
export TF_VAR_tcp_source_ranges="$(json_array "${TCP_RANGES[@]}")"

if ! run_with_spinner "Initializing Terraform state and provider" terraform -chdir=terraform init -input=false \
  -backend-config="bucket=${STATE_BUCKET}" -backend-config="prefix=${APP_NAME}/terraform"; then
  fail "Terraform init failed. Ensure its ADC principal can read and write gs://${STATE_BUCKET}, and verify provider/network access."
fi
if ! run_with_spinner "Validating the Terraform configuration" terraform -chdir=terraform validate; then
  fail "Terraform validation failed; fix the configuration error shown above."
fi
TERRAFORM_PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/xgcpx-terraform-plan.XXXXXX")"
if ! run_with_spinner "Planning: credentials, permissions, quotas, changes" \
  terraform -chdir=terraform plan -input=false -lock-timeout=120s -out="$TERRAFORM_PLAN_FILE"; then
  fail "Terraform plan failed; no Terraform infrastructure changes were applied. Check the ADC principal, project IAM roles, quota, billing, and organization policies shown above."
fi
if ! run_with_spinner "Applying the verified Terraform plan" \
  terraform -chdir=terraform apply -input=false -lock-timeout=120s "$TERRAFORM_PLAN_FILE"; then
  fail "Terraform apply failed. Review the provider error above; GCP may have accepted only part of the deployment."
fi
rm -f -- "$TERRAFORM_PLAN_FILE"
TERRAFORM_PLAN_FILE=""

if [[ "$USE_CLOUD_RUN_HOST" == "true" ]]; then
  RUN_URL="$(terraform -chdir=terraform output -raw https_url 2>/dev/null || true)"
  if [[ "$RUN_URL" != https://* ]]; then
    RUN_URL="$(gcloud run services describe "$SERVICE_NAME" --region="$REGION" --project="$PROJECT_ID" \
      --format='value(status.url)' 2>/dev/null || true)"
  fi
  if [[ "$RUN_URL" == https://* ]]; then
    ACTUAL_HOST="${RUN_URL#https://}"; ACTUAL_HOST="${ACTUAL_HOST%%/*}"
    if [[ "$ACTUAL_HOST" != "$DOMAIN" ]]; then
      warn "Cloud Run reported ${ACTUAL_HOST}, not the predicted ${DOMAIN}; using the real host."
    fi
    DOMAIN="$ACTUAL_HOST"
  else
    warn "Could not read the Cloud Run URL; falling back to the predicted host ${DOMAIN}."
  fi
fi
PROTOCOL_IP=""
if [[ "$ENABLE_PROTOCOL_VM" == "true" ]]; then
  PROTOCOL_IP="$(terraform -chdir=terraform output -raw protocol_gateway_ip)"
fi
if [[ "$PROTOCOL_RUNTIME" == "vm" && -z "$RELAY_DOMAIN" ]]; then
  RELAY_DOMAIN="${PROTOCOL_IP//./-}.sslip.io"
fi
# Direct-relay endpoints use the relay hostname when there is one, otherwise the VM IP.
RELAY_ENDPOINT="${RELAY_DOMAIN:-$PROTOCOL_IP}"
if ((${#PROTOCOL_TAGS[@]} > 0)); then generate_client_profiles; fi
LB_IP=""
if [[ "$USE_CLOUD_RUN_HOST" != "true" ]]; then
  LB_IP="$(terraform -chdir=terraform output -raw load_balancer_ip)"
fi

OPENVPN_CLIENT_CONFIG=""
if [[ "$ENABLE_OPENVPN" == "true" ]]; then
  OPENVPN_CLIENT_CONFIG="${OUTPUT_DIR}/openvpn-client-${DEPLOY_TAG}.ovpn"
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
fi

# ---------------------------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------------------------
print_endpoints() {
  printf 'Enabled protocol endpoints and credentials:\n'
  if [[ -n "$CLIENT_PROFILE_REPORT" ]]; then
    printf 'Generated Xray client profiles:\n%s\n' "$CLIENT_PROFILE_REPORT"
  fi
  if has_option 1 || has_option 2 || has_option 3; then
    printf '  VLESS client ID (UUID): %s\n' "$PROTOCOL_UUID"
    printf '  VLESS TLS server name: %s\n' "$DOMAIN"
  fi
  if has_option 1; then
    printf '  VLESS over TLS/WebSocket: %s:443, path /vless-ws\n' "$DOMAIN"
    printf '  VLESS over TLS/HTTPUpgrade: %s:443, path /vless-httpupgrade\n' "$DOMAIN"
  fi
  if has_option 2; then
    printf '  VLESS over TLS/gRPC: %s:443, service name vless-grpc\n' "$DOMAIN"
    if [[ "$PROTOCOL_RUNTIME" == "vm" ]]; then printf '  VLESS gRPC direct relay: %s:50051\n' "$RELAY_ENDPOINT"; fi
  fi
  if has_option 3; then
    printf '  VLESS xHTTP/TLS packet-up: %s:443, path /xhttp-packet\n' "$DOMAIN"
    printf '  VLESS xHTTP/TLS stream-up: %s:443, path /xhttp-chunked\n' "$DOMAIN"
    printf '  VLESS xHTTP/TLS stream-one: %s:443, path /xhttp-request-response\n' "$DOMAIN"
    if [[ "$PROTOCOL_RUNTIME" == "vm" ]]; then printf '  VLESS xHTTP direct relay: %s:8080\n' "$RELAY_ENDPOINT"; fi
  fi
  if has_option 4; then
    printf '  Shadowsocks: %s:8388 (TCP and UDP), method chacha20-ietf-poly1305\n  Shadowsocks password: %s\n' \
      "$RELAY_ENDPOINT" "$SHADOWSOCKS_PASSWORD"
  fi
  if has_option 6; then
    printf '  Trojan over TLS/WebSocket: %s:443, path /trojan-ws\n  Trojan over TLS/HTTPUpgrade: %s:443, path /trojan-httpupgrade\n  Trojan password: %s\n' \
      "$DOMAIN" "$DOMAIN" "$TROJAN_PASSWORD"
  fi
  if has_option 7; then
    printf '  VMess over TLS/WebSocket: %s:443, path /vmess-ws\n  VMess client ID (UUID): %s\n' "$DOMAIN" "$VMESS_UUID"
  fi
  if has_option 8; then
    printf '  SSH over TLS/WebSocket: %s:443, path /ssh-ws (install websocat for the SSH client)\n' "$DOMAIN"
    printf '  SSH username: xgcpx\n  SSH password: %s\n' "$SSH_PASSWORD"
    printf '  SSH command: ssh -o "ProxyCommand=websocat -E wss://%s/ssh-ws" xgcpx@%s\n' "$DOMAIN" "$DOMAIN"
  fi
  if [[ "$ENABLE_OPENVPN" == "true" ]]; then
    printf '  OpenVPN: %s:1194/udp (certificate-authenticated)\n  OpenVPN client profile: %s\n' "$PROTOCOL_IP" "$OPENVPN_CLIENT_CONFIG"
  fi
}
CREDENTIALS_REPORT="$(print_endpoints)"
CREDENTIALS_FILE="${OUTPUT_DIR}/credentials-${DEPLOY_TAG}.txt"
{
  printf 'xgcpx deployment %s (%s, %s)\nHTTPS URL: https://%s\n\n' "$DEPLOY_TAG" "$SERVICE_NAME" "$REGION" "$DOMAIN"
  printf '%s\n' "$CREDENTIALS_REPORT"
} >"$CREDENTIALS_FILE"
chmod 0600 "$CREDENTIALS_FILE"

section "COMPLETE  |  Deployment outputs"
kv "Service" "$SERVICE_NAME"
kv "Region" "${REGION} ($(region_flag "$REGION" "$REGION"))"
kv "Gateway" "$GATEWAY"
kv "HTTPS URL" "https://${DOMAIN}"
if [[ "$USE_CLOUD_RUN_HOST" == "true" ]]; then
  kv "DNS" "none needed (automatic Cloud Run host, Google-managed certificate)"
  kv "TLS" "terminates at Cloud Run's Google-managed edge"
else
  kv "Load balancer IP" "$LB_IP"
  kv "DNS" "create an A record for ${DOMAIN} -> ${LB_IP}; the certificate provisions after DNS resolves"
  kv "TLS" "terminates at the external HTTPS load balancer"
fi
printf '\n%sCloud Run routes%s\n' "$BOLD" "$RESET"
printf '%s\n' \
  "  Health: /healthz | API: /api/* (built-in sidecar unless an external upstream is supplied)" \
  "  Persistent streaming: /persistent/* | Assets: /assets/*" \
  "  WebSocket/gRPC need a compatible upstream; Cloud Run carries them over HTTP(S)"
if [[ "$ENABLE_TCP_PROXY" == "true" ]]; then
  printf 'Envoy TCP endpoint: %s:9000\nEnvoy TLS passthrough endpoint: %s:9443\n' \
    "$(terraform -chdir=terraform output -raw tcp_proxy_ip)" \
    "$(terraform -chdir=terraform output -raw tls_proxy_ip)"
fi
if [[ "$ENABLE_PROTOCOL_VM" == "true" ]]; then
  printf '\n%sProtocol VM%s\n' "$BOLD" "$RESET"
  kv "Public IP" "$PROTOCOL_IP"
  if [[ "$PROTOCOL_RUNTIME" == "vm" ]]; then
    if [[ "$RELAY_AUTO" == "true" ]]; then
      kv "Hostname" "${RELAY_DOMAIN} (automatic sslip.io name; no DNS record needed)"
      info "Caddy requests its Let's Encrypt certificate after the VM boots; allow a few minutes before the first connection."
    else
      kv "Hostname" "${RELAY_DOMAIN} (create its A record directly to ${PROTOCOL_IP})"
    fi
    info "The protocol VM firewall is public; protocol credentials are required."
  else
    info "This protocol VM runs OpenVPN only; HTTP transports run in the Cloud Run sidecar."
  fi
elif ((${#PROTOCOL_TAGS[@]} > 0)); then
  info "No protocol VM was created; HTTP transports run entirely within the Cloud Run revision."
fi
printf '\n%s\n' "$CREDENTIALS_REPORT"
printf '\nSelected services: %s\n' "${PROTOCOL_OPTIONS[*]}"
printf '%sSaved to%s %s (mode 0600)\n' "$BOLD" "$RESET" "$CREDENTIALS_FILE"
warn "Store the printed credentials, the Xray client profiles and any OpenVPN profile securely; they live in ${OUTPUT_DIR} (git-ignored)."
if [[ "$ENABLE_PROTOCOL_VM" == "true" ]]; then
  warn "The protocol VM IP is separate from the Cloud Run / load-balancer address."
fi
if [[ "$ENABLE_OPENVPN" == "true" ]]; then
  warn "Cloud Run cannot expose raw OpenVPN UDP; clients connect directly to the protocol VM IP."
fi
success "Done."

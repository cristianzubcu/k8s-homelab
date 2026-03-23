#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# k8s-homelab setup script
# Deploys all homelab services onto a running Kubernetes cluster.
# Requires: kubectl (configured), envsubst (gettext package)
# ─────────────────────────────────────────────────────────────────────────────

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${REPO_DIR}/manifests"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; exit 1; }

check_deps() {
  for cmd in kubectl envsubst; do
    command -v "$cmd" &>/dev/null || error "'$cmd' not found. Install it and re-run."
  done
  kubectl cluster-info &>/dev/null || error "kubectl cannot reach a cluster. Check your kubeconfig."
}

# ── Auto-detect local IP ──────────────────────────────────────────────────────
detect_ip() {
  # Try ip route first (Linux), fall back to hostname
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}') \
    || ip=$(hostname -I 2>/dev/null | awk '{print $1}') \
    || ip="127.0.0.1"
  echo "$ip"
}

# ── Prompt helpers ────────────────────────────────────────────────────────────
prompt()         { read -rp "$1 [${2:-}]: " _val; echo "${_val:-${2:-}}"; }
prompt_secret()  { read -rsp "$1: " _val; echo; echo "$_val"; }
prompt_yn()      { read -rp "$1 (yes/no) [${2:-no}]: " _val; echo "${_val:-${2:-no}}"; }

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          k8s-homelab — initial setup                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

check_deps

# ── Gather configuration ──────────────────────────────────────────────────────
export DATA_DIR
DATA_DIR=$(prompt "Data directory (absolute path on the node)" "/opt/homelab-data")
DATA_DIR=$(realpath -m "$DATA_DIR")

export PUID
PUID=$(prompt "PUID" "1000")

export PGID
PGID=$(prompt "PGID" "1000")

export TZ
TZ=$(prompt "Timezone" "Europe/Amsterdam")

DETECTED_IP=$(detect_ip)
export SERVER_IP
SERVER_IP=$(prompt "Server IP (used in dashboard links)" "$DETECTED_IP")

MULLVAD_PRIVATE_KEY=$(prompt_secret "Mullvad WireGuard private key")
[ -z "$MULLVAD_PRIVATE_KEY" ] && error "Mullvad private key cannot be empty."

export WIREGUARD_ADDRESS
WIREGUARD_ADDRESS=$(prompt "WireGuard interface address (from Mullvad config)" "10.74.34.21/32")

INSTALL_TAILSCALE=$(prompt_yn "Install Tailscale for remote access?" "no")
TAILSCALE_AUTHKEY=""
if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
  TAILSCALE_AUTHKEY=$(prompt_secret "Tailscale auth key")
  [ -z "$TAILSCALE_AUTHKEY" ] && error "Tailscale auth key cannot be empty when enabling Tailscale."
fi

# ─────────────────────────────────────────────────────────────────────────────
info "Creating namespace and directory structure..."

kubectl apply -f "${MANIFEST_DIR}/namespace.yaml"

# Create data directories on the node (works for single-node / local K8s)
for dir in \
    "${DATA_DIR}/media/movies/_incoming" \
    "${DATA_DIR}/media/tvshows/_incoming" \
    "${DATA_DIR}/wireguard/config/wg_confs" \
    "${DATA_DIR}/qbittorrent/appdata" \
    "${DATA_DIR}/prowlarr/data" \
    "${DATA_DIR}/radarr/config" \
    "${DATA_DIR}/sonarr/config" \
    "${DATA_DIR}/bazarr/config" \
    "${DATA_DIR}/jellyfin/config" \
    "${DATA_DIR}/portainer/data" \
    "${DATA_DIR}/homepage/config" \
    "${DATA_DIR}/prometheus/data" \
    "${DATA_DIR}/grafana/data"; do
  mkdir -p "$dir" && success "Created $dir" || warn "Could not create $dir (may be on remote node)"
done

if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
  mkdir -p "${DATA_DIR}/tailscale/state"
fi

# ─────────────────────────────────────────────────────────────────────────────
info "Creating Kubernetes Secrets..."

# WireGuard config file (contains private key — stored as a Secret)
WG_CONF=$(cat <<EOF
[Interface]
PrivateKey = ${MULLVAD_PRIVATE_KEY}
Address = ${WIREGUARD_ADDRESS}
DNS = 10.64.0.1

[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = 0.0.0.0/0
Endpoint = 193.32.249.66:51820
EOF
)

kubectl -n homelab create secret generic wireguard-config \
  --from-literal=wg0.conf="$WG_CONF" \
  --dry-run=client -o yaml | kubectl apply -f -
success "Secret 'wireguard-config' applied."

if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
  kubectl -n homelab create secret generic tailscale-secret \
    --from-literal=TS_AUTHKEY="$TAILSCALE_AUTHKEY" \
    --dry-run=client -o yaml | kubectl apply -f -
  success "Secret 'tailscale-secret' applied."
fi

# ─────────────────────────────────────────────────────────────────────────────
info "Creating ConfigMaps..."

# Homepage services.yaml with SERVER_IP substituted
envsubst < "${REPO_DIR}/homepage/services.yaml" | \
  kubectl -n homelab create configmap homepage-services \
    --from-file=services.yaml=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
success "ConfigMap 'homepage-services' applied."

# ─────────────────────────────────────────────────────────────────────────────
info "Applying storage manifests (PVs and PVCs)..."

envsubst < "${MANIFEST_DIR}/storage.yaml" | kubectl apply -f -
success "Storage applied."

# ─────────────────────────────────────────────────────────────────────────────
info "Applying service manifests..."

# Apply env-substituted manifests for deployments that use ${PUID}, ${PGID}, ${TZ}
for manifest in \
    wireguard-qbittorrent \
    prowlarr \
    radarr \
    sonarr \
    bazarr \
    flaresolverr \
    jellyfin \
    prometheus \
    grafana \
    node-exporter \
    cadvisor \
    portainer \
    homepage; do
  envsubst < "${MANIFEST_DIR}/${manifest}.yaml" | kubectl apply -f -
  success "${manifest} applied."
done

if [[ "$INSTALL_TAILSCALE" == "yes" ]]; then
  kubectl apply -f "${MANIFEST_DIR}/tailscale.yaml"
  success "tailscale applied."
fi

# ─────────────────────────────────────────────────────────────────────────────
info "Waiting for deployments to become ready..."
kubectl -n homelab wait deployment \
  wireguard-qbittorrent prowlarr radarr sonarr bazarr flaresolverr \
  jellyfin prometheus grafana portainer homepage \
  --for=condition=Available --timeout=120s 2>/dev/null || \
  warn "Some deployments are still starting — check 'kubectl -n homelab get pods'"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Setup complete!                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
printf "  %-20s %s\n" "Service"      "URL"
printf "  %-20s %s\n" "───────"      "───"
printf "  %-20s %s\n" "Homepage"     "http://${SERVER_IP}:30000"
printf "  %-20s %s\n" "Jellyfin"     "http://${SERVER_IP}:30096"
printf "  %-20s %s\n" "Radarr"       "http://${SERVER_IP}:30878"
printf "  %-20s %s\n" "Sonarr"       "http://${SERVER_IP}:30989"
printf "  %-20s %s\n" "Bazarr"       "http://${SERVER_IP}:30767"
printf "  %-20s %s\n" "qBittorrent"  "http://${SERVER_IP}:30080"
printf "  %-20s %s\n" "Prowlarr"     "http://${SERVER_IP}:30969"
printf "  %-20s %s\n" "Prometheus"   "http://${SERVER_IP}:30090"
printf "  %-20s %s\n" "Grafana"      "http://${SERVER_IP}:30301  (admin/admin)"
printf "  %-20s %s\n" "Portainer"    "https://${SERVER_IP}:30443"
echo ""
info "qBittorrent: check the pod logs for the temporary password:"
echo "    kubectl -n homelab logs deployment/wireguard-qbittorrent -c qbittorrent | grep 'temporary password'"
echo ""
info "Monitor all pods:"
echo "    kubectl -n homelab get pods -w"
echo ""

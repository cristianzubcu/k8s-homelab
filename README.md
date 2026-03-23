# k8s-homelab

Kubernetes version of [homelab](https://github.com/zubcuHD/homelab) — the same 14-service self-hosted media and monitoring stack, rewritten as native Kubernetes manifests.

## Services

| Service | Description | NodePort |
|---|---|---|
| Homepage | Dashboard | 30000 |
| Jellyfin | Media server | 30096 |
| Radarr | Movie manager | 30878 |
| Sonarr | TV show manager | 30989 |
| Bazarr | Subtitle manager | 30767 |
| qBittorrent | Torrent client (VPN-tunnelled) | 30080 |
| Prowlarr | Indexer aggregator | 30969 |
| FlareSolverr | Cloudflare bypass proxy | internal |
| Prometheus | Metrics collection | 30090 |
| Grafana | Monitoring dashboards | 30301 |
| Portainer | Kubernetes UI | 30443 |
| node-exporter | Host metrics | internal |
| cAdvisor | Container metrics | internal |
| Tailscale | Remote access VPN (optional) | — |

## Requirements

- A running Kubernetes cluster (single-node is fine — [k3s](https://k3s.io) recommended)
- `kubectl` configured to reach that cluster
- `envsubst` (`apt install gettext` / `brew install gettext`)
- A [Mullvad](https://mullvad.net) WireGuard configuration (for the VPN tunnel)

## Quick start

```bash
git clone https://github.com/zubcuHD/k8s-homelab
cd k8s-homelab
chmod +x setup.sh
./setup.sh
```

The script will prompt you for:

| Variable | Description | Default |
|---|---|---|
| Data directory | Where persistent data is stored on the node | `/opt/homelab-data` |
| PUID / PGID | User/group ID for LinuxServer containers | `1000` |
| Timezone | TZ database name | `Europe/Amsterdam` |
| Server IP | Used in dashboard links | auto-detected |
| Mullvad private key | From your Mullvad WireGuard config | — |
| WireGuard address | Interface IP from Mullvad config | `10.74.34.21/32` |
| Tailscale auth key | Optional — for remote access | — |

## Architecture

### VPN + qBittorrent (same Pod)

qBittorrent and WireGuard run as containers inside **the same Kubernetes Pod**. Containers in a Pod share a network namespace, so all of qBittorrent's traffic is automatically routed through the WireGuard VPN — equivalent to `network_mode: service:wireguard` in Docker Compose.

```
┌─────────────────────────────┐
│  Pod: wireguard-qbittorrent │
│  ┌────────────┐  ┌────────┐ │
│  │ wireguard  │  │  qbit  │ │  ← shared network namespace
│  └────────────┘  └────────┘ │
└─────────────────────────────┘
```

### Storage

All persistent data uses `hostPath` PersistentVolumes pointing to `DATA_DIR` on the node. The media library (`DATA_DIR/media`) is shared across Radarr, Sonarr, Jellyfin, Bazarr, and qBittorrent via a single `ReadWriteMany` PVC.

```
DATA_DIR/
├── media/
│   ├── movies/_incoming/
│   └── tvshows/_incoming/
├── wireguard/config/
├── qbittorrent/appdata/
├── radarr/config/
├── sonarr/config/
├── jellyfin/config/
├── bazarr/config/
├── prowlarr/data/
├── portainer/data/
├── homepage/config/
├── prometheus/data/
├── grafana/data/
└── tailscale/state/    ← if Tailscale enabled
```

### Secrets

WireGuard private key and Tailscale auth key are stored as Kubernetes Secrets (never in plain YAML files). `setup.sh` creates them via `kubectl create secret`.

## Redeployment

To update or redeploy after changes:

```bash
# Pull latest manifests
git pull

# Re-run setup (secrets will be updated with --dry-run=client trick)
./setup.sh

# Or apply individual manifests
envsubst < manifests/radarr.yaml | kubectl apply -f -
```

## Useful commands

```bash
# Watch all pods
kubectl -n homelab get pods -w

# View logs for a specific service
kubectl -n homelab logs deployment/radarr -f

# Restart a deployment
kubectl -n homelab rollout restart deployment/jellyfin

# Get qBittorrent temp password
kubectl -n homelab logs deployment/wireguard-qbittorrent -c qbittorrent | grep "temporary password"

# Check all services and ports
kubectl -n homelab get svc
```

## k3s single-node setup

k3s is the recommended Kubernetes distribution for homelabs:

```bash
# Install k3s
curl -sfL https://get.k3s.io | sh -

# Copy kubeconfig
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config

# Verify
kubectl get nodes
```

Then run `./setup.sh`.

## Unsafe sysctls (WireGuard)

The WireGuard pod requires `net.ipv4.conf.all.src_valid_mark=1`. On k3s, allow it by adding to `/etc/rancher/k3s/config.yaml`:

```yaml
kube-apiserver-arg:
  - "allow-privileged=true"
kubelet-arg:
  - "allowed-unsafe-sysctls=net.ipv4.conf.all.src_valid_mark"
```

Then restart k3s: `sudo systemctl restart k3s`

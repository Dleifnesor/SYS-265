#!/usr/bin/env bash
# =============================================================================
# setup-rocky.sh – Bootstrap a Rocky Linux host for the Plex Docker stack
# Run as root or with sudo:  sudo bash scripts/setup-rocky.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash $0"

# ── 1. System update ──────────────────────────────────────────────────────────
info "Updating system packages..."
dnf update -y

# ── 2. Install Docker (official repo) ────────────────────────────────────────
info "Installing Docker CE..."
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
info "Docker version: $(docker --version)"
info "Docker Compose version: $(docker compose version)"

# ── 3. Add current user to docker group ──────────────────────────────────────
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [[ -n "$REAL_USER" ]]; then
    usermod -aG docker "$REAL_USER"
    info "Added $REAL_USER to docker group. Log out and back in for this to take effect."
fi

# ── 4. Configure firewalld ────────────────────────────────────────────────────
info "Opening firewall ports..."
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --permanent --add-port=443/tcp
    firewall-cmd --permanent --add-port=32400/tcp   # Plex web/API
    firewall-cmd --permanent --add-port=32400/udp
    # Plex local network discovery (GDM)
    firewall-cmd --permanent --add-port=32410/udp
    firewall-cmd --permanent --add-port=32412/udp
    firewall-cmd --permanent --add-port=32413/udp
    firewall-cmd --permanent --add-port=32414/udp
    # Tautulli & Overseerr (behind nginx, but useful for direct access)
    firewall-cmd --permanent --add-port=8181/tcp
    firewall-cmd --permanent --add-port=5055/tcp
    firewall-cmd --reload
    info "Firewall rules applied."
else
    warn "firewalld is not running – skipping port rules."
fi

# ── 5. SELinux – allow container volume mounts ────────────────────────────────
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    info "Configuring SELinux for container use..."
    setsebool -P container_manage_cgroup true 2>/dev/null || true
    # Relabel media/config dirs after they are created
    info "SELinux: mount volumes with :z or :Z suffix, or run restorecon after setup."
fi

# ── 6. Create host directories ────────────────────────────────────────────────
info "Creating host directory structure..."
MEDIA_ROOT="${MEDIA_DIR:-/opt/plex/media}"
CONFIG_ROOT="${CONFIG_DIR:-/opt/plex/config}"

mkdir -p \
    "$CONFIG_ROOT/plex" \
    "$CONFIG_ROOT/overseerr" \
    "$CONFIG_ROOT/tautulli" \
    "$MEDIA_ROOT/movies" \
    "$MEDIA_ROOT/tv" \
    "$MEDIA_ROOT/music" \
    /tmp/plex-transcode

# Set ownership to the PUID/PGID defined in .env (defaults to 1000:1000)
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
chown -R "$PUID:$PGID" /opt/plex /tmp/plex-transcode
chmod -R 755 /opt/plex

info "Directories created under /opt/plex"

# ── 7. Copy .env if not already present ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
    warn ".env created from .env.example – EDIT IT before running docker compose up!"
else
    info ".env already exists – skipping copy."
fi

# ── 8. Done ───────────────────────────────────────────────────────────────────
echo ""
info "=== Setup complete ==="
echo ""
echo "  Next steps:"
echo "  1. Edit .env with your values (PLEX_CLAIM, passwords, paths, TZ)"
echo "  2. Add SSL certs to nginx/ssl/  (fullchain.pem + privkey.pem)"
echo "  3. Update nginx/conf.d/plex.conf with your actual domain names"
echo "  4. Run:  docker compose up -d"
echo "  5. Open http://<server-ip>:32400/web to finish Plex setup"
echo ""

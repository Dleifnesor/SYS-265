
### 1. Clone the repo

```bash
git clone <your-repo-url> /opt/plex-docker
cd /opt/plex-docker
```

> **Host:** `web01.DanielR.local`

### 2. Run the bootstrap script

```bash
sudo bash scripts/setup-rocky.sh
```

This installs Docker CE, opens firewall ports, creates host directories,
and copies `.env.example` → `.env`.

### 3. Edit `.env`

```bash
nano .env
```

Key values to set:

| Variable | Description |
|----------|-------------|
| `PUID` / `PGID` | Output of `id $(whoami)` |
| `TZ` | Your timezone, e.g. `America/Chicago` |
| `PLEX_CLAIM` | From https://www.plex.tv/claim (4 min TTL) |
| `DB_PASSWORD` | Strong password for PostgreSQL |
| `MEDIA_DIR` | Path to your media on the host |
| `CONFIG_DIR` | Path for persistent config data |

### 4. Add TLS certificates

**Self-signed (local – web01.DanielR.local):**
```bash
bash scripts/generate-selfsigned-ssl.sh web01.DanielR.local
```

This generates a cert covering `web01.DanielR.local`, `overseerr.web01.DanielR.local`, and `tautulli.web01.DanielR.local`.

> **Note:** `.local` subdomains require a local DNS server (e.g. Pi-hole, pfSense, Windows DNS) to resolve. mDNS alone only resolves the base hostname `web01.DanielR.local`.

### 5. Start the stack

```bash
docker compose up -d
```

### 6. Initial Plex setup

Open `http://web01.DanielR.local:32400/web` and complete the setup wizard.

| Service | URL |
|---------|-----|
| Plex | `http://web01.DanielR.local:32400/web` |
| Overseerr | `https://overseerr.web01.DanielR.local` |
| Tautulli | `https://tautulli.web01.DanielR.local` |

---

## Common Commands

```bash
# View logs
docker compose logs -f

# View logs for a single service
docker compose logs -f plex

# Restart a service
docker compose restart nginx

# Stop everything
docker compose down

# Stop and remove volumes (destructive!)
docker compose down -v

# Pull latest images
docker compose pull

# Check container status
docker compose ps
```

## SELinux Notes (Rocky Linux)

If containers cannot access volumes, relabel the directories:

```bash
sudo chcon -Rt svirt_sandbox_file_t /opt/plex
```

Or append `:z` to volume paths in `docker-compose.yml` for automatic relabeling.

## Ports Reference

| Port | Protocol | Service |
|------|----------|---------|
| 80 | TCP | Nginx HTTP (redirects to HTTPS) |
| 443 | TCP | Nginx HTTPS |
| 32400 | TCP/UDP | Plex (direct, via host network) |
| 32410–32414 | UDP | Plex GDM discovery |
| 5055 | TCP | Overseerr (direct, also via Nginx) |
| 8181 | TCP | Tautulli (direct, also via Nginx) |
| 5432 | TCP | PostgreSQL (localhost only) |

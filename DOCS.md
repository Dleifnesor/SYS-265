# Plex Docker Stack – Full Documentation

A production-ready, multi-container Plex media server stack designed for Rocky Linux.
Covers every file, configuration option, and operational procedure in the project.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Project Structure](#project-structure)
3. [Services](#services)
   - [Plex](#plex-media-server)
   - [PostgreSQL (db)](#postgresql-db)
   - [Overseerr](#overseerr)
   - [Tautulli](#tautulli)
   - [Nginx](#nginx)
   - [Watchtower](#watchtower)
4. [Environment Variables](#environment-variables)
5. [Volumes](#volumes)
6. [Database Initialization](#database-initialization)
7. [Nginx Configuration](#nginx-configuration)
   - [nginx.conf](#nginxconf)
   - [conf.d/plex.conf](#confdplexconf)
   - [SSL Certificates](#ssl-certificates)
8. [Scripts](#scripts)
   - [setup-rocky.sh](#setup-rockysh)
   - [generate-selfsigned-ssl.sh](#generate-selfsigned-sslsh)
9. [Quick Start](#quick-start)
10. [Common Commands](#common-commands)
11. [Ports Reference](#ports-reference)
12. [Security Notes](#security-notes)
13. [SELinux Notes](#selinux-notes)
14. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Internet / LAN
      │
      ▼
 ┌─────────┐   :80 / :443
 │  Nginx  │ ──────────────── Reverse proxy (TLS termination, HTTP→HTTPS redirect)
 └────┬────┘
      │
      ├──► overseerr:5055  ──► Overseerr  (media request UI)
      └──► tautulli:8181   ──► Tautulli   (analytics & monitoring)

 ┌──────────────────────┐
 │  Plex (host network) │  :32400 + GDM UDP ports
 └──────────┬───────────┘
            │  depends_on (healthy)
            ▼
 ┌──────────────────┐
 │  PostgreSQL :5432│  localhost-only; initialized by db/init/01_init.sql
 └──────────────────┘

 ┌───────────┐
 │ Watchtower│  Polls Docker Hub on a cron schedule; auto-updates all containers
 └───────────┘
```

- **Plex** uses `network_mode: host` so that LAN discovery (GDM) and direct Plex clients work without NAT hairpinning.
- **Nginx** sits in front of Overseerr and Tautulli, providing HTTPS and rate limiting.
- **PostgreSQL** is never exposed outside `127.0.0.1`; only the Plex container (and any future tooling) connects to it.
- **Watchtower** restarts containers automatically when new images are published.

---

## Project Structure

```
.
├── docker-compose.yml            # Defines all six services + named volumes
├── .env.example                  # Template for environment variables (copy → .env)
├── .env                          # Your secrets – never committed (gitignored)
├── .gitignore                    # Excludes .env, SSL keys, and log files
├── README.md                     # Quick-start reference
├── DOCS.md                       # This file – full documentation
│
├── db/
│   └── init/
│       └── 01_init.sql           # Auto-runs on first PostgreSQL container start
│
├── nginx/
│   ├── nginx.conf                # Global Nginx settings, security headers, rate limit
│   ├── conf.d/
│   │   └── plex.conf             # Virtual host blocks for Overseerr & Tautulli
│   └── ssl/                      # TLS certificate files (gitignored)
│       ├── fullchain.pem         # Certificate chain (Let's Encrypt or self-signed)
│       └── privkey.pem           # Private key (600 permissions required)
│
└── scripts/
    ├── setup-rocky.sh            # One-shot host bootstrap (Docker, firewall, dirs)
    └── generate-selfsigned-ssl.sh # Generates self-signed cert for local dev
```

---

## Services

All services are defined in `docker-compose.yml` (Compose format v3.9).

### Plex Media Server

| Property | Value |
|----------|-------|
| Image | `lscr.io/linuxserver/plex:latest` |
| Container name | `plex` |
| Network | `host` (required for GDM/LAN discovery) |
| Config volume | `${CONFIG_DIR}/plex:/config` |
| Media volumes | `/tv`, `/movies`, `/music` mapped from `${MEDIA_DIR}` |
| Transcode dir | `/tmp/plex-transcode:/transcode` |
| Restart policy | `unless-stopped` |
| Dependency | Waits for `db` to pass its healthcheck |

**Key environment variables for this service:**

| Variable | Purpose |
|----------|---------|
| `PUID` / `PGID` | Run process as this user/group (matches host ownership) |
| `TZ` | Timezone for logs and scheduling |
| `PLEX_CLAIM` | One-time claim token from plex.tv/claim to link server to your account |
| `VERSION=docker` | Tells linuxserver image to use the bundled Plex version |

**Notes:**
- Because it uses `network_mode: host`, it does **not** publish ports via Docker; all Plex ports are opened by `setup-rocky.sh` on the host firewall.
- The transcode directory uses `/tmp` (tmpfs-backed on most systems) for performance. It is ephemeral and will be cleared on reboot.

---

### PostgreSQL (db)

| Property | Value |
|----------|-------|
| Image | `postgres:16-alpine` |
| Container name | `plex-db` |
| Port | `127.0.0.1:5432:5432` (localhost-only) |
| Data volume | Named volume `db_data` → `/var/lib/postgresql/data` |
| Init scripts | `./db/init:/docker-entrypoint-initdb.d:ro` |
| Restart policy | `unless-stopped` |

**Healthcheck:**

```yaml
test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
interval: 10s
timeout: 5s
retries: 5
```

Plex will not start until this healthcheck passes, preventing startup race conditions.

**Key environment variables for this service:**

| Variable | Purpose |
|----------|---------|
| `DB_USER` | PostgreSQL superuser / application user |
| `DB_PASSWORD` | Password for `DB_USER` – use a strong value |
| `DB_NAME` | Name of the database created on first start |

---

### Overseerr

| Property | Value |
|----------|-------|
| Image | `lscr.io/linuxserver/overseerr:latest` |
| Container name | `overseerr` |
| Port | `5055:5055` |
| Config volume | `${CONFIG_DIR}/overseerr:/config` |
| Restart policy | `unless-stopped` |

Overseerr is a media request manager that integrates with Plex, Sonarr, and Radarr. It is accessible directly on port 5055 **and** via Nginx at `https://overseerr.<your-domain>`.

---

### Tautulli

| Property | Value |
|----------|-------|
| Image | `lscr.io/linuxserver/tautulli:latest` |
| Container name | `tautulli` |
| Port | `8181:8181` |
| Config volume | `${CONFIG_DIR}/tautulli:/config` |
| Restart policy | `unless-stopped` |
| Dependency | Requires `plex` to be running |

Tautulli provides Plex playback statistics, user activity, and notification integrations. Accessible on port 8181 or via Nginx at `https://tautulli.<your-domain>`.

---

### Nginx

| Property | Value |
|----------|-------|
| Image | `nginx:stable-alpine` |
| Container name | `plex-nginx` |
| Ports | `80:80`, `443:443` |
| Config (read-only) | `./nginx/nginx.conf`, `./nginx/conf.d/` |
| SSL (read-only) | `./nginx/ssl/` |
| Log volume | Named volume `nginx_logs` → `/var/log/nginx` |
| Restart policy | `unless-stopped` |
| Dependencies | `overseerr`, `tautulli` |

Acts as the public-facing reverse proxy. Handles TLS termination, HTTP→HTTPS redirection, WebSocket upgrades, security headers, and rate limiting.

---

### Watchtower

| Property | Value |
|----------|-------|
| Image | `containrrr/watchtower:latest` |
| Container name | `watchtower` |
| Docker socket | `/var/run/docker.sock:/var/run/docker.sock` |
| Restart policy | `unless-stopped` |

Watches all running containers and restarts them with updated images on the configured schedule.

**Key environment variables for this service:**

| Variable | Purpose |
|----------|---------|
| `WATCHTOWER_CLEANUP=true` | Removes old images after updating |
| `WATCHTOWER_SCHEDULE` | Cron expression for update checks |
| `TZ` | Ensures cron fires at the correct local time |

> **Security note:** Watchtower requires access to the Docker socket, which grants root-equivalent access to the host. Ensure the container is not reachable externally.

---

## Environment Variables

Copy `.env.example` to `.env` and fill in all values before starting the stack.

```bash
cp .env.example .env
```

| Variable | Default (example) | Description |
|----------|-------------------|-------------|
| `PUID` | `1000` | UID the LinuxServer containers run as. Get with: `id $(whoami)` |
| `PGID` | `1000` | GID the LinuxServer containers run as |
| `TZ` | `America/New_York` | Timezone string from the [tz database](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) |
| `PLEX_CLAIM` | `claim-XXXX…` | Claim token from [plex.tv/claim](https://www.plex.tv/claim) – valid for 4 minutes |
| `CONFIG_DIR` | `/opt/plex/config` | Host path where container config data is persisted |
| `MEDIA_DIR` | `/opt/plex/media` | Host path containing your media (`movies/`, `tv/`, `music/`) |
| `DB_USER` | `plexuser` | PostgreSQL username |
| `DB_PASSWORD` | `changeme_strong_password` | PostgreSQL password – **must be changed** |
| `DB_NAME` | `plexdb` | PostgreSQL database name |
| `WATCHTOWER_SCHEDULE` | `0 0 3 * * *` | Cron expression for Watchtower (default: 3 AM daily) |
| `SERVER_NAME` | `plex.example.com` | Used in Nginx virtual host configs |

> **Security:** `.env` is listed in `.gitignore`. Never commit it.

---

## Volumes

Two named Docker volumes are declared at the bottom of `docker-compose.yml`:

| Volume | Used by | Purpose |
|--------|---------|---------|
| `db_data` | `db` | Persists PostgreSQL data across container restarts |
| `nginx_logs` | `nginx` | Persists Nginx access and error logs |

Config directories (`plex`, `overseerr`, `tautulli`) are bind-mounted from `${CONFIG_DIR}` on the host so they survive `docker compose down -v` (which only removes named volumes).

---

## Database Initialization

**File:** `db/init/01_init.sql`

This script is mounted into `/docker-entrypoint-initdb.d/` and runs automatically the **first time** the PostgreSQL container starts (i.e., when `db_data` volume is empty).

```sql
-- Enables UUID generation functions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Metadata table used by other services to confirm DB readiness
CREATE TABLE IF NOT EXISTS plex_meta (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Seed the schema version
INSERT INTO plex_meta (key, value)
VALUES ('schema_version', '1')
ON CONFLICT (key) DO NOTHING;

-- Grant the application user full access
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO plexuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO plexuser;
```

To add additional initialization steps, add numbered SQL files to `db/init/` (e.g., `02_seed.sql`). They run in lexicographic order.

> **Note:** Init scripts only run on a **fresh** volume. To re-run them, remove the `db_data` volume first: `docker compose down -v && docker compose up -d`.

---

## Nginx Configuration

### nginx.conf

**File:** `nginx/nginx.conf`

Global settings applied to all virtual hosts:

| Setting | Value | Purpose |
|---------|-------|---------|
| `worker_processes auto` | — | Scales to available CPU cores |
| `worker_connections 1024` | — | Max simultaneous connections per worker |
| `keepalive_timeout 65` | 65s | Reuse TCP connections |
| `sendfile / tcp_nopush / tcp_nodelay` | on | Efficient file transfer |
| `gzip on` | — | Compresses responses |
| `limit_req_zone` | `20r/s` per IP | Rate limiting zone used by virtual hosts |

**Security headers added globally:**

| Header | Value |
|--------|-------|
| `X-Frame-Options` | `SAMEORIGIN` |
| `X-Content-Type-Options` | `nosniff` |
| `X-XSS-Protection` | `1; mode=block` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |

Virtual host files are loaded from `/etc/nginx/conf.d/*.conf`.

---

### conf.d/plex.conf

**File:** `nginx/conf.d/plex.conf`

Defines three server blocks:

#### 1. HTTP → HTTPS Redirect

```nginx
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}
```

Catches all HTTP traffic and permanently redirects it to HTTPS.

#### 2. Overseerr Virtual Host (port 443)

- `server_name`: `overseerr.plex.example.com` – **update to your domain**
- TLS: `TLSv1.2` and `TLSv1.3` only; weak ciphers excluded
- Rate limit: `burst=40 nodelay` from the `general` zone
- Proxy: forwards to `http://overseerr:5055`
- WebSocket headers (`Upgrade`, `Connection`) included for real-time features

#### 3. Tautulli Virtual Host (port 443)

- `server_name`: `tautulli.plex.example.com` – **update to your domain**
- Same TLS and rate limiting as Overseerr
- Proxy: forwards to `http://tautulli:8181`

**To update domain names:**

```bash
# Replace placeholder domains with your actual domain
sed -i 's/plex.example.com/your-actual-domain.com/g' nginx/conf.d/plex.conf
```

---

### SSL Certificates

Certificates must be placed at:

```
nginx/ssl/fullchain.pem   # Certificate + chain
nginx/ssl/privkey.pem     # Private key (chmod 600)
```

These paths are gitignored. Two options:

**Option A – Self-signed (dev/local):**

```bash
bash scripts/generate-selfsigned-ssl.sh plex.local
```

Generates a cert valid for the domain and its `overseerr.*` / `tautulli.*` subdomains.

**Option B – Let's Encrypt (production):**

```bash
sudo certbot certonly --standalone -d plex.example.com \
    -d overseerr.plex.example.com -d tautulli.plex.example.com
sudo cp /etc/letsencrypt/live/plex.example.com/fullchain.pem nginx/ssl/
sudo cp /etc/letsencrypt/live/plex.example.com/privkey.pem  nginx/ssl/
```

---

## Scripts

### setup-rocky.sh

**File:** `scripts/setup-rocky.sh`
**Run as:** `sudo bash scripts/setup-rocky.sh`

One-shot bootstrap script for a fresh Rocky Linux host. Steps performed:

| Step | Action |
|------|--------|
| 1 | `dnf update -y` – updates all system packages |
| 2 | Adds Docker CE repo and installs `docker-ce`, `docker-compose-plugin`, `containerd.io`, `docker-buildx-plugin` |
| 3 | Enables and starts the Docker service; adds the invoking user to the `docker` group |
| 4 | Opens firewall ports via `firewall-cmd` (see [Ports Reference](#ports-reference)) |
| 5 | Configures SELinux boolean `container_manage_cgroup` (if SELinux is enforcing) |
| 6 | Creates host directory tree under `/opt/plex/` with correct ownership (`PUID:PGID`) |
| 7 | Copies `.env.example` → `.env` if `.env` does not already exist |

**Directories created:**

```
/opt/plex/config/plex
/opt/plex/config/overseerr
/opt/plex/config/tautulli
/opt/plex/media/movies
/opt/plex/media/tv
/opt/plex/media/music
/tmp/plex-transcode
```

> After running, **log out and back in** for the `docker` group membership to take effect.

---

### generate-selfsigned-ssl.sh

**File:** `scripts/generate-selfsigned-ssl.sh`
**Usage:** `bash scripts/generate-selfsigned-ssl.sh [domain]`
**Default domain:** `plex.local`

Generates a self-signed RSA-2048 certificate valid for 365 days using `openssl`. The Subject Alternative Name (SAN) covers:

- `DNS:<domain>`
- `DNS:overseerr.<domain>`
- `DNS:tautulli.<domain>`
- `IP:127.0.0.1`

Output files:

| File | Permissions | Purpose |
|------|-------------|---------|
| `nginx/ssl/privkey.pem` | `600` | Private key |
| `nginx/ssl/fullchain.pem` | `644` | Self-signed certificate |

> For production deployments, replace these with Let's Encrypt certificates issued by `certbot`.

---

## Quick Start

### 1. Clone the repository

```bash
git clone <your-repo-url> /opt/plex-docker
cd /opt/plex-docker
```

### 2. Bootstrap the host (Rocky Linux)

```bash
sudo bash scripts/setup-rocky.sh
```

Log out and back in so your user is in the `docker` group.

### 3. Configure environment variables

```bash
nano .env
```

At minimum, set: `PLEX_CLAIM`, `DB_PASSWORD`, `TZ`, `PUID`/`PGID`, `MEDIA_DIR`, `CONFIG_DIR`.

### 4. Generate or install TLS certificates

**Local/dev:**
```bash
bash scripts/generate-selfsigned-ssl.sh plex.local
```

**Production:**
```bash
sudo certbot certonly --standalone -d plex.example.com
sudo cp /etc/letsencrypt/live/plex.example.com/fullchain.pem nginx/ssl/
sudo cp /etc/letsencrypt/live/plex.example.com/privkey.pem  nginx/ssl/
```

### 5. Update Nginx domain names

Edit `nginx/conf.d/plex.conf` and replace `plex.example.com` with your actual domain.

### 6. Start the stack

```bash
docker compose up -d
```

### 7. Complete Plex setup

Open `http://<server-ip>:32400/web` in your browser and follow the Plex setup wizard.

### 8. Connect Tautulli to Plex

Open `http://<server-ip>:8181` and configure Tautulli to point to your Plex server.

### 9. Connect Overseerr to Plex

Open `http://<server-ip>:5055` and follow the Overseerr setup, linking it to your Plex server and optionally to Sonarr/Radarr.

---

## Common Commands

```bash
# Start all services in the background
docker compose up -d

# Stop all services (keeps volumes)
docker compose down

# Stop and remove all named volumes (destructive – deletes DB data)
docker compose down -v

# View logs for all services (live)
docker compose logs -f

# View logs for a specific service
docker compose logs -f plex
docker compose logs -f db
docker compose logs -f nginx

# Check status of all containers
docker compose ps

# Pull latest images without restarting
docker compose pull

# Pull and restart with updated images
docker compose pull && docker compose up -d

# Restart a single service
docker compose restart nginx

# Open a shell inside a running container
docker compose exec plex bash
docker compose exec db psql -U plexuser -d plexdb

# Force recreate a specific service
docker compose up -d --force-recreate plex
```

---

## Ports Reference

| Port | Protocol | Service | Notes |
|------|----------|---------|-------|
| `80` | TCP | Nginx | HTTP; immediately redirects to HTTPS |
| `443` | TCP | Nginx | HTTPS; proxies Overseerr and Tautulli |
| `32400` | TCP/UDP | Plex | Web UI, API, and streaming |
| `32410` | UDP | Plex | GDM network discovery |
| `32412` | UDP | Plex | GDM network discovery |
| `32413` | UDP | Plex | GDM network discovery |
| `32414` | UDP | Plex | GDM network discovery |
| `5055` | TCP | Overseerr | Direct access (also via Nginx) |
| `8181` | TCP | Tautulli | Direct access (also via Nginx) |
| `5432` | TCP | PostgreSQL | Localhost-only; not externally accessible |

---

## Security Notes

- **`.env` must never be committed.** It contains database credentials and your Plex claim token.
- **PostgreSQL** is bound to `127.0.0.1:5432` and is not reachable from outside the host.
- **Watchtower** has access to the Docker socket (equivalent to root). Do not expose it externally.
- **Nginx** applies global security headers (`X-Frame-Options`, `X-Content-Type-Options`, `X-XSS-Protection`, `Referrer-Policy`) and rate-limits requests to 20 req/s per IP with a burst of 40.
- **TLS** is configured to allow only TLSv1.2 and TLSv1.3. Weak cipher suites (`aNULL`, `MD5`) are excluded.
- **SSL private key** (`nginx/ssl/privkey.pem`) is gitignored and should have `chmod 600` on the host.

---

## SELinux Notes

Rocky Linux runs SELinux in enforcing mode by default. If containers cannot read bind-mounted volumes:

**Option A – Relabel directories permanently:**

```bash
sudo chcon -Rt svirt_sandbox_file_t /opt/plex
```

**Option B – Append `:z` to volume paths in `docker-compose.yml`:**

```yaml
volumes:
  - ${CONFIG_DIR}/plex:/config:z
  - ${MEDIA_DIR}/tv:/tv:z
```

- `:z` – shared label (multiple containers can access)
- `:Z` – private label (only this container can access)

The `setup-rocky.sh` script sets the `container_manage_cgroup` boolean and reminds you to apply `:z`/`:Z` labels.

---

## Troubleshooting

### `dnf install docker-ce` fails with a conflict against `podman-docker`

Rocky Linux ships `podman-docker` — a shim that provides the `docker` command via Podman.
It conflicts with the real `docker-ce` package. Remove it first:

```bash
sudo dnf remove -y podman-docker
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

`setup-rocky.sh` now handles this automatically, but if you ran an older version of the script you will need to do this manually.

---

### Plex won't start

```bash
docker compose logs plex
```

Common causes:
- `db` healthcheck is failing – check `docker compose logs db`
- `PLEX_CLAIM` token has expired (4-minute window) – get a new one from plex.tv/claim
- `CONFIG_DIR` or `MEDIA_DIR` paths don't exist on the host – run `setup-rocky.sh` again or create them manually

### Database connection issues

```bash
docker compose exec db pg_isready -U plexuser -d plexdb
docker compose logs db
```

Check that `DB_USER`, `DB_PASSWORD`, and `DB_NAME` in `.env` match the values used when the volume was first initialized. If they don't match, remove the volume and recreate:

```bash
docker compose down -v
docker compose up -d
```

### Nginx returns 502 Bad Gateway

The upstream container (Overseerr or Tautulli) may not be running:

```bash
docker compose ps
docker compose logs overseerr
docker compose logs tautulli
```

### SSL certificate errors

Ensure `nginx/ssl/fullchain.pem` and `nginx/ssl/privkey.pem` exist and are readable:

```bash
ls -la nginx/ssl/
docker compose logs nginx
```

Regenerate self-signed certs if missing:

```bash
bash scripts/generate-selfsigned-ssl.sh plex.local
docker compose restart nginx
```

### Watchtower unexpectedly updated a container

To pin a container and prevent Watchtower from updating it, add this label in `docker-compose.yml`:

```yaml
labels:
  - "com.centurylinklabs.watchtower.enable=false"
```

### Container can't write to media or config directories

Check ownership and SELinux context:

```bash
ls -laZ /opt/plex
sudo chcon -Rt svirt_sandbox_file_t /opt/plex
```

Or ensure `PUID`/`PGID` in `.env` match the host user that owns those directories.

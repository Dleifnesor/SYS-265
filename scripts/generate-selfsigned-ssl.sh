#!/usr/bin/env bash
# =============================================================================
# generate-selfsigned-ssl.sh
# Creates a self-signed TLS certificate for local/dev use.
# For production, replace with Let's Encrypt certs via certbot.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSL_DIR="$(dirname "$SCRIPT_DIR")/nginx/ssl"

DOMAIN="${1:-plex.local}"

mkdir -p "$SSL_DIR"

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$SSL_DIR/privkey.pem" \
    -out    "$SSL_DIR/fullchain.pem" \
    -subj   "/CN=$DOMAIN/O=PlexStack/C=US" \
    -addext "subjectAltName=DNS:$DOMAIN,DNS:overseerr.$DOMAIN,DNS:tautulli.$DOMAIN,IP:127.0.0.1"

chmod 600 "$SSL_DIR/privkey.pem"
chmod 644 "$SSL_DIR/fullchain.pem"

echo "Self-signed certificate generated for: $DOMAIN"
echo "  Cert: $SSL_DIR/fullchain.pem"
echo "  Key:  $SSL_DIR/privkey.pem"
echo ""
echo "For production, replace with Let's Encrypt:"
echo "  certbot certonly --standalone -d $DOMAIN"

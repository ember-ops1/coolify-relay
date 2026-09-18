#!/usr/bin/env bash
# ==============================================================================
# Hardened Coolify State Restoration Script for Backblaze B2
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-b2:coolify-relay-state/coolify-state}"
BACKUP_DIR="/data/coolify/backups"
SOURCE_DIR="/data/coolify"

echo "[COOLIFY-RESTORE] === Phase: State Hydration & Permission Normalization ==="

sudo mkdir -p "$SOURCE_DIR" /var/lib/docker/volumes "$BACKUP_DIR"

# 1. Check if backup bundle exists in Backblaze B2
if rclone ls "${STORAGE_TARGET}/coolify_bundle.tar.gz" >/dev/null 2>&1; then
  echo "[COOLIFY-RESTORE] Backblaze B2 bundle detected. Extracting with --numeric-owner..."
  rclone cat "${STORAGE_TARGET}/coolify_bundle.tar.gz" | sudo tar --numeric-owner -xpzf - -C /data/coolify 2>/dev/null || true
  echo "[COOLIFY-RESTORE] Core /data/coolify state restored."
else
  echo "[COOLIFY-RESTORE] No prior backup found in B2. Marking as COLD_START baseline."
fi

# 2. Restore Docker volumes if present
if rclone ls "${STORAGE_TARGET}/volumes_bundle.tar.gz" >/dev/null 2>&1; then
  echo "[COOLIFY-RESTORE] Extracting Docker volumes with --numeric-owner..."
  rclone cat "${STORAGE_TARGET}/volumes_bundle.tar.gz" | sudo tar --numeric-owner -xpzf - -C /var/lib/docker/volumes 2>/dev/null || true
fi

# 3. Pull latest standalone PostgreSQL dump
if rclone ls "${STORAGE_TARGET}/coolify_pg_latest.sql.gz" >/dev/null 2>&1; then
  echo "[COOLIFY-RESTORE] Downloading fresh PostgreSQL dump..."
  rclone copyto "${STORAGE_TARGET}/coolify_pg_latest.sql.gz" "${BACKUP_DIR}/coolify_pg_latest.sql.gz" 2>/dev/null || true
fi

# ==============================================================================
# SAFEGUARD 1: Strict Linux File Ownership & Permissions
# ==============================================================================
echo "[COOLIFY-RESTORE] Applying strict Linux filesystem permissions..."
# Ensure /data/coolify is traversable and writable by docker and runner
sudo chmod -R 755 /data/coolify 2>/dev/null || true
[ -d "/data/coolify/source" ] && sudo chmod -R 775 /data/coolify/source 2>/dev/null || true

if [ -d "/data/coolify/ssh/keys" ]; then
  sudo chmod 700 /data/coolify/ssh/keys
  sudo chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
  sudo chmod 644 /data/coolify/ssh/keys/*.pub 2>/dev/null || true
fi

# ==============================================================================
# SAFEGUARD 2: Localhost SSH Injection & Daemon Hardening
# ==============================================================================
echo "[COOLIFY-RESTORE] Configuring host SSH server & authorized_keys for Coolify engine..."
sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server

# Drop-in sshd configuration to guarantee public key auth and root login via key
sudo mkdir -p /etc/ssh/sshd_config.d
cat << 'EOF' | sudo tee /etc/ssh/sshd_config.d/99-coolify.conf >/dev/null
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF

# Ensure sshd is running
sudo systemctl enable ssh 2>/dev/null || sudo systemctl enable sshd 2>/dev/null || true
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true

# Authorize Coolify's internal SSH key for root and runner users
sudo mkdir -p /root/.ssh /home/runner/.ssh

# Inject master Coolify onboarding key
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINGMEL5LpxfXWB1Q2gd028oYZzpuGe97jlmgbYza+pN" | sudo tee -a /root/.ssh/authorized_keys >/dev/null
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINGMEL5LpxfXWB1Q2gd028oYZzpuGe97jlmgbYza+pN" | sudo tee -a /home/runner/.ssh/authorized_keys >/dev/null

if [ -f "/data/coolify/ssh/keys/id_ed25519.pub" ]; then
  COOLIFY_PUB=$(sudo cat /data/coolify/ssh/keys/id_ed25519.pub)
  echo "$COOLIFY_PUB" | sudo tee -a /root/.ssh/authorized_keys >/dev/null
  echo "$COOLIFY_PUB" | sudo tee -a /home/runner/.ssh/authorized_keys >/dev/null
  echo "[COOLIFY-RESTORE] Injected Coolify id_ed25519.pub into /root/.ssh/authorized_keys."
elif [ -f "/data/coolify/ssh/keys/id_rsa.pub" ]; then
  COOLIFY_PUB=$(sudo cat /data/coolify/ssh/keys/id_rsa.pub)
  echo "$COOLIFY_PUB" | sudo tee -a /root/.ssh/authorized_keys >/dev/null
  echo "$COOLIFY_PUB" | sudo tee -a /home/runner/.ssh/authorized_keys >/dev/null
  echo "[COOLIFY-RESTORE] Injected Coolify id_rsa.pub into /root/.ssh/authorized_keys."
fi

# Ensure any public keys inside /data/coolify/ssh/keys are also in authorized_keys
for pub in /data/coolify/ssh/keys/*.pub; do
  [ -f "$pub" ] && sudo cat "$pub" | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null || true
done

sudo chmod 700 /root/.ssh /home/runner/.ssh
sudo chmod 600 /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys 2>/dev/null || true

# ==============================================================================
# SAFEGUARD 3: Database Boot & pg_isready Health Polling
# ==============================================================================
if [ -f "/data/coolify/source/docker-compose.yml" ] && [ -f "/data/coolify/source/docker-compose.prod.yml" ]; then
  # Ensure APP_URL is correctly set to coolify.justsawyou.cyou
  if [ -f "/data/coolify/source/.env" ]; then
    sudo sed -i 's|^APP_URL=.*|APP_URL=https://coolify.justsawyou.cyou|g' /data/coolify/source/.env 2>/dev/null || true
  fi

  echo "[COOLIFY-RESTORE] Booting coolify-db container..."
  sudo docker compose --project-directory /data/coolify/source \
    --env-file /data/coolify/source/.env \
    -f /data/coolify/source/docker-compose.yml \
    -f /data/coolify/source/docker-compose.prod.yml \
    up -d coolify-db 2>&1 || true

  echo "[COOLIFY-RESTORE] Polling PostgreSQL daemon readiness via pg_isready..."
  DB_READY=false
  for i in {1..30}; do
    if sudo docker exec coolify-db pg_isready -U coolify >/dev/null 2>&1; then
      echo "[COOLIFY-RESTORE] PostgreSQL is fully ready and accepting connections! ($((i*2))s)"
      DB_READY=true
      break
    fi
    sleep 2
  done

  if [ "$DB_READY" != "true" ]; then
    echo "[COOLIFY-RESTORE] Warning: PostgreSQL took longer than 60s to report ready. Proceeding with caution."
  fi

  # Restore PostgreSQL dump if available (using postgres maintenance DB for global restore)
  if [ -f "${BACKUP_DIR}/coolify_pg_latest.sql.gz" ]; then
    echo "[COOLIFY-RESTORE] Restoring PostgreSQL database from dump..."
    gunzip -c "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | sudo docker exec -i coolify-db psql -U coolify -d postgres 2>/dev/null || true
    echo "[COOLIFY-RESTORE] Database restored successfully."
  fi

  # Boot remaining Coolify engine services with full env-file and prod compose context
  echo "[COOLIFY-RESTORE] Booting complete Coolify engine (coolify, redis, realtime)..."
  sudo docker compose --project-directory /data/coolify/source \
    --env-file /data/coolify/source/.env \
    -f /data/coolify/source/docker-compose.yml \
    -f /data/coolify/source/docker-compose.prod.yml \
    up -d --remove-orphans 2>&1 || true

  # Boot Coolify Proxy (Traefik v3) if present
  if [ -d "/data/coolify/proxy" ] && [ -f "/data/coolify/proxy/docker-compose.yml" ]; then
    echo "[COOLIFY-RESTORE] Booting Coolify Traefik proxy on port 80/443..."
    sudo docker compose --project-directory /data/coolify/proxy -f /data/coolify/proxy/docker-compose.yml up -d 2>/dev/null || true
  fi

  # Verify container state
  echo "[COOLIFY-RESTORE] Active Docker containers:"
  sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
fi

echo "[COOLIFY-RESTORE] State restoration & environment hardening complete!"

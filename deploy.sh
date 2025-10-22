#!/usr/bin/env bash
# POSIX-compatible-ish (uses bash features but keeps it straightforward)
# Usage: ./deploy.sh
# Optional: ./deploy.sh --cleanup

set -o errexit
set -o nounset
set -o pipefail

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="./deploy_${TIMESTAMP}.log"

# Exit codes:
# 0 success, 1 generic, 2 validation, 3 ssh, 4 remote prepare, 5 deploy, 6 nginx, 7 validation fail

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE"
}

die() {
  log "ERROR: $*"
  exit "${2:-1}"
}

trap 'die "Unexpected error on line $LINENO"' INT TERM ERR

# --- Prompt for inputs (non-interactive mode supported via env vars)
CLEANUP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup) CLEANUP=1; shift ;;
    *) break ;;
  esac
done

prompt() {
  varname="$1"; prompt_text="$2"; default="${3:-}"
  if [ -n "${!varname:-}" ]; then
    return 0
  fi
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt_text" "$default"
  else
    printf "%s: " "$prompt_text"
  fi
  read -r input
  if [ -z "$input" ] && [ -n "$default" ]; then
    input="$default"
  fi
  eval "$varname=\"\$input\""
}

# Collect inputs
prompt GIT_REPO "Git repository URL (https or ssh)"
prompt PAT "Personal Access Token (if repo is https private; leave empty for ssh)"
prompt BRANCH "Branch (default: main)" "main"
prompt SSH_USER "Remote SSH username (ec2-user/ubuntu/...)"
prompt SSH_HOST "Remote server IP / hostname"
prompt SSH_KEY "Path to SSH private key (e.g. ~/.ssh/id_rsa)"
prompt APP_PORT "Application internal container port (e.g. 8000)"

# Validate minimal inputs
[ -n "$GIT_REPO" ] || die "Git repo URL required" 2
[ -n "$SSH_USER" ] || die "SSH username required" 2
[ -n "$SSH_HOST" ] || die "Remote host required" 2
[ -f "$SSH_KEY" ] || die "SSH key not found at $SSH_KEY" 2
[ -n "$APP_PORT" ] || die "App port required" 2

REMOTE="$SSH_USER@$SSH_HOST"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

log "Starting deployment. Logfile: $LOGFILE"

if [ "$CLEANUP" -eq 1 ]; then
  log "Running cleanup on remote..."
  ssh $SSH_OPTS "$REMOTE" <<'REMOTE_EOF' | tee -a "$LOGFILE"
set -o errexit
sudo systemctl stop nginx || true
sudo docker compose -f /opt/deploy/docker-compose.yml down --remove-orphans || true
sudo docker rm -f $(docker ps -aq) 2>/dev/null || true
sudo docker rmi -f $(docker images -q) 2>/dev/null || true
sudo rm -rf /opt/deploy || true
sudo rm -f /etc/nginx/sites-enabled/deploy_app || true
sudo rm -f /etc/nginx/sites-available/deploy_app || true
sudo nginx -t || true
sudo systemctl reload nginx || true
REMOTE_EOF
  log "Cleanup finished."
  exit 0
fi

# 1) Clone or pull locally
REPO_DIR="$(basename "$GIT_REPO" .git)"
if [ -d "$REPO_DIR/.git" ]; then
  log "Repo exists locally. Pulling latest from $BRANCH"
  (cd "$REPO_DIR" && git fetch --all --prune) >>"$LOGFILE" 2>&1 || die "git fetch failed" 1
  (cd "$REPO_DIR" && git checkout "$BRANCH" && git pull origin "$BRANCH") >>"$LOGFILE" 2>&1 || die "git pull failed" 1
else
  log "Cloning repo $GIT_REPO (branch: $BRANCH)"
  if [ -n "${PAT:-}" ]; then
    # convert https://github.com/owner/repo.git -> https://<PAT>@github.com/owner/repo.git
    if printf '%s\n' "$GIT_REPO" | grep -q '^https://'; then
      SAFE_URL="$(printf '%s' "$GIT_REPO" | sed "s|https://|https://$PAT@|")"
      git clone --branch "$BRANCH" "$SAFE_URL" || die "git clone failed" 1
    else
      git clone --branch "$BRANCH" "$GIT_REPO" || die "git clone failed" 1
    fi
  else
    git clone --branch "$BRANCH" "$GIT_REPO" || die "git clone failed" 1
  fi
fi

cd "$REPO_DIR" || die "Cannot cd into repo dir" 1

# 2) Check for Dockerfile or docker-compose.yml
if [ -f Dockerfile ]; then
  HAS_DOCKERFILE=1
else
  HAS_DOCKERFILE=0
fi
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  HAS_COMPOSE=1
else
  HAS_COMPOSE=0
fi
if [ "$HAS_DOCKERFILE" -eq 0 ] && [ "$HAS_COMPOSE" -eq 0 ]; then
  die "No Dockerfile or docker-compose.yml found in repo root" 1
fi
log "Project check: Dockerfile=$HAS_DOCKERFILE docker-compose=$HAS_COMPOSE"

# 3) Check SSH connectivity
log "Checking SSH connectivity to $REMOTE"
ssh $SSH_OPTS -o BatchMode=yes "$REMOTE" "echo ok" >>"$LOGFILE" 2>&1 || die "SSH connectivity failed (check user/ip/key)" 3
log "SSH reachable."

# 4) Prepare remote environment (install docker, compose, nginx)
log "Preparing remote environment (install Docker, Docker Compose, Nginx if missing)..."
ssh $SSH_OPTS "$REMOTE" bash -s <<'REMOTE_EOF' >>"$LOGFILE" 2>&1
set -o errexit
# detect package manager
if command -v apt-get >/dev/null 2>&1; then
  PKG=apt
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  # docker
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
    sudo systemctl enable --now docker
  fi
  # docker-compose plugin
  if ! docker compose version >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose-plugin
  fi
  # nginx
  if ! command -v nginx >/dev/null 2>&1; then
    sudo apt-get install -y nginx
    sudo systemctl enable --now nginx
  fi
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y yum-utils
  if ! command -v docker >/dev/null 2>&1; then
    sudo yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || true
    sudo yum install -y docker
    sudo systemctl enable --now docker
  fi
  if ! docker compose version >/dev/null 2>&1; then
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose || true
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    sudo yum install -y nginx
    sudo systemctl enable --now nginx
  fi
fi

# Add current user to docker group if needed
if [ "$(id -u)" -ne 0 ]; then
  if ! groups | grep -qw docker; then
    sudo usermod -aG docker "$USER" || true
  fi
fi

# confirm versions
docker --version || true
docker compose version || true
nginx -v || true
REMOTE_EOF

log "Remote prepare complete."

# 5) Transfer files (rsync)
log "Transferring project files to remote (/opt/deploy)..."
RSYNC_EXCLUDES="--exclude .git --exclude .env --exclude node_modules"
rsync -az --delete $RSYNC_EXCLUDES -e "ssh $SSH_OPTS" ./ "$REMOTE:/tmp/deploy_src/" >>"$LOGFILE" 2>&1 || die "rsync failed" 3

# Move to final location remotely
ssh $SSH_OPTS "$REMOTE" bash -s <<'REMOTE_EOF' >>"$LOGFILE" 2>&1
set -o errexit
sudo mkdir -p /opt/deploy
sudo rm -rf /opt/deploy/* || true
sudo cp -r /tmp/deploy_src/. /opt/deploy/
sudo chown -R $(whoami):$(whoami) /opt/deploy
REMOTE_EOF

log "Files copied."

# 6) Deploy app: use docker-compose if present else docker build/run
if [ "$HAS_COMPOSE" -eq 1 ]; then
  log "Using docker-compose deployment."
  ssh $SSH_OPTS "$REMOTE" bash -s <<'REMOTE_EOF' >>"$LOGFILE" 2>&1
set -o errexit
cd /opt/deploy
# down existing
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  sudo docker compose -f docker-compose.yml down --remove-orphans || true
  sudo docker compose -f docker-compose.yml up -d --build
else
  # fallback: if docker-compose file missing for any reason
  echo "No docker-compose.yml on remote" >&2
  exit 5
fi
# wait and show status
sleep 3
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
REMOTE_EOF
else
  # single Dockerfile flow
  log "Using Dockerfile build/run flow."
  CONTAINER_NAME="deploy_app"
  ssh $SSH_OPTS "$REMOTE" bash -s <<'REMOTE_EOF' >>"$LOGFILE" 2>&1
set -o errexit
cd /opt/deploy
sudo docker build -t deploy_app_image .
# remove previous container if exists
if sudo docker ps -a --format '{{.Names}}' | grep -w deploy_app >/dev/null 2>&1; then
  sudo docker rm -f deploy_app || true
fi
# run (map port to host high port automatically; nginx will reverse proxy)
sudo docker run -d --name deploy_app -p 127.0.0.1:0:$APP_PORT deploy_app_image || true
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
REMOTE_EOF
fi

log "Containers should be up. Waiting briefly for health checks..."
sleep 5

# 7) Configure nginx reverse proxy
NGINX_CONF="/etc/nginx/sites-available/deploy_app"
REMOTE_NGINX_CONF="server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
"

log "Uploading nginx config and reloading nginx..."
ssh $SSH_OPTS "$REMOTE" bash -s <<REMOTE_EOF >>"$LOGFILE" 2>&1
set -o errexit
sudo tee /etc/nginx/sites-available/deploy_app > /dev/null <<'NGINX'
$REMOTE_NGINX_CONF
NGINX
sudo ln -sf /etc/nginx/sites-available/deploy_app /etc/nginx/sites-enabled/deploy_app
sudo nginx -t
sudo systemctl reload nginx
REMOTE_EOF

log "Nginx configured to proxy to container:$APP_PORT"

# 8) Validation: check docker, container, nginx, endpoint
log "Validating deployment..."
ssh $SSH_OPTS "$REMOTE" bash -s <<'REMOTE_EOF' >>"$LOGFILE" 2>&1
set -o errexit
echo "Docker version:"; docker --version
echo "Docker ps:"; docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo "Nginx status:"; sudo systemctl status nginx --no-pager | sed -n '1,5p'
# quick local curl from remote to the app via localhost
if command -v curl >/dev/null 2>&1; then
  echo "Local curl to app:"
  curl -sI http://127.0.0.1:${APP_PORT} | sed -n '1,5p' || true
fi
REMOTE_EOF

# remote external check (from local machine)
log "External check from this machine to http://$SSH_HOST (port 80)"
if command -v curl >/dev/null 2>&1; then
  curl -sI "http://$SSH_HOST" | sed -n '1,5p' >>"$LOGFILE" 2>&1 || log "curl external check failed (maybe firewall)."
else
  log "curl not found locally; skipping external HTTP check."
fi

log "Deployment script finished. Check $LOGFILE for details."
exit 0

#!/usr/bin/env bash
# -----------------------------------------------------------------------------
#  setup_surveillance.sh — Cross‑Platform Edge NVR Bootstrap (Linux/macOS)
# -----------------------------------------------------------------------------
#  ▸ Records RTSP feeds as continuous mp4 files using MediaMTX + Docker
#  ▸ Supports configurable feed list, cron-based cleanup, and optional restream
# -----------------------------------------------------------------------------

set -euo pipefail
trap 'echo "[ERROR] Line $LINENO: $BASH_COMMAND" >&2' ERR

###############################################################################
# 0. Globals
###############################################################################
: "${INSTALL_DIR:=$(eval echo ~$SUDO_USER)/surveillance}"
RECORD_DIR="$INSTALL_DIR/recordings"
MTX_TAG="latest"
RETENTION_HOURS=24
RTSP_FEED_FILE="$INSTALL_DIR/rtsp_feeds.txt"
CAMS=()

###############################################################################
# 1. Docker Installation (Linux only)
###############################################################################
install_docker_linux() {
  echo "[INFO] Installing Docker Engine…"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
}

require_docker() {
  if ! command -v docker &>/dev/null; then
    [[ "$(uname -s)" == "Linux" ]] && install_docker_linux || {
      echo "[ERROR] Please install Docker Desktop: https://www.docker.com/products/docker-desktop" >&2
      exit 1
    }
  fi
}

###############################################################################
# 2. Privilege Check (Linux)
###############################################################################
[[ "$(uname -s)" == "Linux" && $EUID -ne 0 ]] && {
  echo "[ERROR] Please run this script with sudo." >&2
  exit 1
}

require_docker

###############################################################################
# 3. Directory Setup
###############################################################################
mkdir -p "$INSTALL_DIR/config" "$RECORD_DIR"
chmod 777 "$RECORD_DIR"

###############################################################################
# 4. RTSP Feed Bootstrapping
###############################################################################
if [[ ! -f "$RTSP_FEED_FILE" ]]; then
  echo "[INFO] Creating feed file: $RTSP_FEED_FILE"
  cat > "$RTSP_FEED_FILE" <<EOF
# Format: cam_name|rtsp://user:pass@host:port/stream
EOF
  echo "[ACTION] Populate the feed file and re-run this script."
  exit 0
fi

###############################################################################
# 5. Parse RTSP Feeds
###############################################################################
cam_index=1
while IFS= read -r line || [[ -n $line ]]; do
  line_trimmed="$(echo "$line" | xargs)"
  [[ -z "$line_trimmed" || "$line_trimmed" =~ ^# ]] && continue
  if [[ "$line_trimmed" == *"|"* ]]; then
    CAMS+=("$line_trimmed")
  else
    CAMS+=("cam${cam_index}|$line_trimmed")
    ((cam_index++))
  fi
done < "$RTSP_FEED_FILE"

###############################################################################
# 6. Generate MediaMTX Config (continuous .mp4 recording)
###############################################################################
cat > "$INSTALL_DIR/config/mediamtx.yml" <<EOF
logLevel: info
api: yes
metrics: yes
rtmp: no
hls: no
webrtc: no
srt: no

pathDefaults:
  record: true
  recordPath: /recordings/%path/%Y-%m-%d/%H-%M-%S.mp4
  recordFormat: fmp4

  recordSegmentDuration: 3600s   
  recordPartDuration: 0s
  recordDeleteAfter: ${RETENTION_HOURS}h

paths:
EOF

for entry in "${CAMS[@]}"; do
  name="${entry%%|*}"
  url="${entry##*|}"
  printf "  %s:\n    source: %s\n" "$name" "$url" >> "$INSTALL_DIR/config/mediamtx.yml"
done

###############################################################################
# 7. Docker Compose Setup
###############################################################################
cat > "$INSTALL_DIR/.env" <<EOF
INSTALL_DIR=$INSTALL_DIR
RECORD_DIR=$RECORD_DIR
MTX_TAG=$MTX_TAG
EOF

cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  mediamtx:
    image: bluenviron/mediamtx:\${MTX_TAG}
    container_name: mediamtx
    restart: unless-stopped
    network_mode: host
    volumes:
      - \${INSTALL_DIR}/config:/config:ro
      - \${RECORD_DIR}:/recordings
    command: ["/config/mediamtx.yml"]
EOF

###############################################################################
# 8. Deploy Stack
###############################################################################
cd "$INSTALL_DIR"
docker rm -f mediamtx 2>/dev/null || true
docker compose pull --quiet
docker compose up -d

###############################################################################
# 9. Crontab: Cleanup Older Files
###############################################################################
if command -v crontab &>/dev/null; then
  TMP_CRON=$(mktemp)
  crontab -l 2>/dev/null | grep -v "$RECORD_DIR" > "$TMP_CRON" || true
  echo "*/30 * * * * find $RECORD_DIR -type f -mmin +$((RETENTION_HOURS * 60)) -delete" >> "$TMP_CRON"
  crontab "$TMP_CRON" && rm "$TMP_CRON"
else
  echo "[WARN] crontab not found — manual cleanup may be required."
fi

###############################################################################
# 10. Summary Output
###############################################################################
if [[ "$(uname -s)" == "Darwin" ]]; then
  HOST_IP=$(ipconfig getifaddr "$(route get default 2>/dev/null | awk '/interface: / {print $2}')" 2>/dev/null || echo "localhost")
else
  HOST_IP=$(hostname -I | awk '{print $1}')
fi
[[ -z "$HOST_IP" ]] && HOST_IP="localhost"

echo -e "\n✅ [DEPLOYED] MediaMTX is recording the following RTSP streams:"
for entry in "${CAMS[@]}"; do
  name="${entry%%|*}"
  echo "  rtsp://$HOST_IP:8554/$name"
done

echo -e "\n📁 Recordings Directory: $RECORD_DIR"
echo "📄 MediaMTX Logs: docker logs -f mediamtx"

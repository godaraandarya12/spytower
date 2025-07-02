#!/usr/bin/env bash
# -----------------------------------------------------------------------------
#  setup_surveillance.sh – Cross‑Platform Edge‑NVR bootstrap (Linux & macOS)
# -----------------------------------------------------------------------------
#  ▸ Converts any Linux box or macOS host with Docker into a 24‑h rolling NVR
#  ▸ Pulls RTSP cameras listed in rtsp_feeds.txt and records fMP4 segments
#  ▸ Auto‑installs Docker Engine on major Linux distributions if missing
#  ▸ Creates a Docker Compose stack + retention + playback‑fix routine
# -----------------------------------------------------------------------------

set -euo pipefail
trap 'echo "[ERROR] Line $LINENO: $BASH_COMMAND" >&2' ERR

###############################################################################
# 0. Globals
###############################################################################
: "${INSTALL_DIR:=$HOME/surveillance}"  # override by env if desired
RECORD_DIR="$INSTALL_DIR/recordings"
MTX_TAG="latest"
RETENTION_HOURS=24
SEGMENT_SEC=900
RTSP_FEED_FILE="$INSTALL_DIR/rtsp_feeds.txt"
CAMS=()

###############################################################################
# 1. Functions – minimal OS detection
###############################################################################
install_docker_linux() {
  if command -v docker &>/dev/null; then return; fi
  echo "[INFO] Installing Docker Engine (root)…"
  if command -v apt-get &>/dev/null; then
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  elif command -v yum &>/dev/null; then
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  elif command -v apk &>/dev/null; then
    apk add --update docker docker-cli-compose
  else
    echo "[ERROR] Unsupported Linux distribution – install Docker manually." >&2; exit 1
  fi
  systemctl enable --now docker || service docker start
}

require_docker() {
  if command -v docker &>/dev/null; then return; fi
  if [[ $(uname -s) == "Linux" ]]; then install_docker_linux; else
    echo "[ERROR] Docker not found. Install Docker Desktop on macOS: https://www.docker.com/products/docker-desktop" >&2; exit 1
  fi
}

###############################################################################
# 2. Privilege check (only Linux needs root for installs)
###############################################################################
if [[ $(uname -s) == "Linux" && $EUID -ne 0 ]]; then
  echo "[ERROR] Run as root (sudo) on Linux." >&2; exit 1
fi

require_docker

###############################################################################
# 3. Scaffold directories with permissive ACL for container
###############################################################################
mkdir -p "$INSTALL_DIR/config" "$RECORD_DIR"
chmod 777 "$RECORD_DIR"

###############################################################################
# 4. Create default RTSP feed file if missing
###############################################################################
if [[ ! -f "$RTSP_FEED_FILE" ]]; then
  echo "[INFO] Creating starter RTSP feed file at: $RTSP_FEED_FILE"
  cat > "$RTSP_FEED_FILE" <<EOF
# Add your RTSP camera streams below, one per line.
# Format: cam_name|rtsp://user:pass@ip:port/stream
EOF
  echo "[ACTION REQUIRED] Please edit this file and re-run the script."
  exit 0
fi

###############################################################################
# 5. Load RTSP feeds from file
###############################################################################
cam_index=1
while IFS= read -r line || [[ -n $line ]]; do
  line_trimmed="$(echo "$line" | xargs)"
  [[ -z $line_trimmed || $line_trimmed =~ ^# ]] && continue
  if [[ $line_trimmed == *"|"* ]]; then
    CAMS+=("$line_trimmed")
  else
    CAMS+=("cam${cam_index}|$line_trimmed")
    ((cam_index++))
  fi
done < "$RTSP_FEED_FILE"

###############################################################################
# 6. Generate MediaMTX config
###############################################################################
cat > "$INSTALL_DIR/config/mediamtx.yml" <<EOF
logLevel: info
rtmp: no
hls: no
webrtc: no
srt: no
api: yes
metrics: yes

pathDefaults:
  record: true
  recordPath: /recordings/%path/%Y-%m-%d/%H-%M-%S
  recordFormat: fmp4
  recordSegmentDuration: ${SEGMENT_SEC}s
  recordDeleteAfter: ${RETENTION_HOURS}h

paths:
EOF
for entry in "${CAMS[@]}"; do
  name="${entry%%|*}"; url="${entry##*|}"
  [[ -z $url ]] && continue
  printf "  %s:\n    source: %s\n" "$name" "$url" >> "$INSTALL_DIR/config/mediamtx.yml"
done

###############################################################################
# 7. Compose stack + .env for portability
###############################################################################
cat > "$INSTALL_DIR/.env" <<EOF
INSTALL_DIR=$INSTALL_DIR
RECORD_DIR=$RECORD_DIR
MTX_TAG=$MTX_TAG
EOF

cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  mediamtx:
    image: bluenviron/mediamtx:${MTX_TAG}
    container_name: mediamtx
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${INSTALL_DIR}/config:/config:ro
      - ${RECORD_DIR}:/recordings
    command: ["/config/mediamtx.yml"]
EOF

###############################################################################
# 8. (Re)Deploy
###############################################################################
cd "$INSTALL_DIR"
if docker ps -a --format '{{.Names}}' | grep -q '^mediamtx$'; then docker rm -f mediamtx; fi

docker compose pull --quiet && docker compose up -d

###############################################################################
# 9. Finalize MP4 helper and retention guidance
###############################################################################
cat > "$INSTALL_DIR/finalize_mp4.sh" <<'EOF'
#!/usr/bin/env bash
REC_DIR="$(dirname "$0")/recordings"
find "$REC_DIR" -type f -name "*.mp4" -mmin -5 | while read -r f; do
  ffmpeg -loglevel error -y -i "$f" -c copy -movflags +faststart "${f}.fix" && mv "${f}.fix" "$f"
done
EOF
chmod +x "$INSTALL_DIR/finalize_mp4.sh"

# Schedule finalize_mp4.sh to run every 5 minutes if crontab is available
if command -v crontab &>/dev/null; then
  TMP_CRON=$(mktemp)
  crontab -l 2>/dev/null | grep -v finalize_mp4.sh > "$TMP_CRON" || true
  echo "*/5 * * * * $INSTALL_DIR/finalize_mp4.sh" >> "$TMP_CRON"
  crontab "$TMP_CRON" && rm "$TMP_CRON"
else
  echo "[WARN] 'crontab' not available. Please schedule manually:"
  echo "*/5 * * * * $INSTALL_DIR/finalize_mp4.sh"
fi

# Add cron job to delete old recordings on Linux systems
if [[ "$(uname -s)" == "Linux" ]] && command -v crontab &>/dev/null; then
  TMP_CRON=$(mktemp)
  crontab -l 2>/dev/null | grep -v "$RECORD_DIR" > "$TMP_CRON" || true
  echo "*/30 * * * * find $RECORD_DIR -type f -mmin +$((RETENTION_HOURS*60)) -delete" >> "$TMP_CRON"
  crontab "$TMP_CRON" && rm "$TMP_CRON"
fi

###############################################################################
# 10. Success summary
###############################################################################
if [[ $(uname -s) == "Darwin" ]]; then
  HOST_IP=$(ipconfig getifaddr $(route get default 2>/dev/null | awk '/interface: /{print $2}') 2>/dev/null || echo "localhost")
else
  HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
[[ -z $HOST_IP ]] && HOST_IP="localhost"

echo -e "\n[SUCCESS] MediaMTX running. Streams:"
for entry in "${CAMS[@]}"; do
  name="${entry%%|*}"
  echo "  rtsp://${HOST_IP}:8554/${name}"
done

echo -e "\nRecordings: $RECORD_DIR"
echo "Logs: docker logs -f mediamtx"

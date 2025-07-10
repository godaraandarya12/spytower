#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  mac_cctv_gateway.sh  –  v2.4.0
#  One‑touch bootstrap that turns a macOS workstation (Intel/Apple‑Silicon)
#  into a secure, low‑bandwidth IP‑camera edge gateway.
#  • WireGuard VPN (server)            • FFmpeg motion‑clip extractor
#  • Nginx reverse proxy (MJPEG/WebRTC) • MotionEye in Docker
# ---------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# 0.  Shell Hygiene & Locals
###############################################################################
BASE_DIR="$HOME/Camerastorage"                 # single root for all artefacts
STREAM_URL="rtsp://admin:asAS1212@192.168.1.64"
WG_PORT=51820
WG_NETWORK="10.10.10.0/24"
WG_SERVER_IP="10.10.10.1/24"
MJPEG_PORT=8083
MJPEG_SOURCE_PORT=8082
MOTIONEYE_PORT=8765
JANUS_PORT=8088

###############################################################################
# 1.  Homebrew Bootstrapping (non‑root only!)
###############################################################################
if ! command -v brew >/dev/null 2>&1; then
  echo "ℹ️  Homebrew not found. Initiating installation sequence…"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
BREW_PREFIX="$(brew --prefix)"
eval "$(brew shellenv)"

###############################################################################
# 2.  Core Packages & Nginx Conflict Clean‑up
###############################################################################
if sudo launchctl list | grep -q 'homebrew.mxcl.nginx'; then
  echo "⚠️  Detected system‑level nginx service — removing to prevent conflicts…"
  sudo launchctl bootout system /Library/LaunchDaemons/homebrew.mxcl.nginx.plist || true
  sudo rm -f /Library/LaunchDaemons/homebrew.mxcl.nginx.plist
fi

echo "ℹ️  Installing core dependencies: WireGuard, FFmpeg, Nginx, Docker CLI…"
brew install wireguard-tools ffmpeg nginx docker >/dev/null

###############################################################################
# 3.  Docker Desktop Pre‑flight
###############################################################################
if ! docker info >/dev/null 2>&1; then
  echo "❌ Docker Desktop is not running. Please launch Docker and rerun this script."
  exit 1
fi

###############################################################################
# 4.  Directory Scaffold
###############################################################################
mkdir -p "$BASE_DIR"/{wireguard,cctv/{clips,www}}

###############################################################################
# 5.  WireGuard Server Provisioning
###############################################################################
KEY_FILE="$BASE_DIR/wireguard/server.key"
PUB_FILE="$BASE_DIR/wireguard/server.pub"
CFG_FILE="$BASE_DIR/wireguard/wg0.conf"

if [[ ! -f "$KEY_FILE" ]]; then
  echo "ℹ️  Generating WireGuard server key pair…"
  ( umask 077; wg genkey | tee "$KEY_FILE" | wg pubkey > "$PUB_FILE" )
fi
PRIVATE_KEY="$(cat "$KEY_FILE")"

cat > "$CFG_FILE" <<EOF
[Interface]
Address      = $WG_SERVER_IP
ListenPort   = $WG_PORT
PrivateKey   = $PRIVATE_KEY

# ➜ Append additional [Peer] stanzas below for clients.
EOF
chmod 600 "$CFG_FILE"

if ifconfig | grep -q "utun.*wg0"; then
  echo "ℹ️  WireGuard interface 'wg0' already exists (utun) — skipping bring-up."
else
  if sudo wg show wg0 >/dev/null 2>&1; then
    echo "ℹ️  WireGuard interface 'wg0' already active — skipping bring-up."
  else
    sudo wg-quick up "$CFG_FILE" || {
      echo "❌ Failed to start WireGuard tunnel. Run manually: sudo wg-quick up \"$CFG_FILE\""
      exit 1
    }
  fi
fi

###############################################################################
# 6.  FFmpeg Helpers
###############################################################################
cat > "$BASE_DIR/cctv/stream.sh" <<'EOS'
#!/usr/bin/env bash
set -e
SRC="rtsp://admin:asAS1212@192.168.1.64"
DEST="$HOME/Camerastorage/cctv/clips"
mkdir -p "$DEST"
ffmpeg -hide_banner -loglevel warning \
  -i "$SRC" \
  -vf "select=gt(scene\,0.12)" -vsync vfr \
  -c:v libx265 -preset veryfast -crf 28 \
  -f segment -segment_time 10 -reset_timestamps 1 \
  "$DEST/motion_%Y%m%d_%H%M%S.mp4"
EOS
chmod +x "$BASE_DIR/cctv/stream.sh"

cat > "$BASE_DIR/cctv/stream_server.sh" <<'EOS'
#!/usr/bin/env bash
set -e
SRC="rtsp://admin:asAS1212@192.168.1.64"
ffmpeg -hide_banner -loglevel warning \
  -r 10 -re -i "$SRC" \
  -vf "scale=1280:-1" \
  -c:v mjpeg -q:v 5 -f mjpeg \
  tcp://127.0.0.1:8082?listen
EOS
chmod +x "$BASE_DIR/cctv/stream_server.sh"

###############################################################################
# 7.  Nginx Reverse Proxy (Homebrew variant)
###############################################################################
NGINX_CONF_DIR="$BREW_PREFIX/etc/nginx"
SERVER_SNIPPET="$NGINX_CONF_DIR/servers/cctv_gateway.conf"

sudo mkdir -p "$NGINX_CONF_DIR/servers"

if lsof -i :$MJPEG_PORT >/dev/null; then
  echo "⚠️  Port $MJPEG_PORT is already in use. Attempting to release it…"
  sudo kill -9 $(lsof -ti :$MJPEG_PORT) || true
fi

sudo tee "$SERVER_SNIPPET" >/dev/null <<EOF
server {
    listen $MJPEG_PORT;
    server_name _;
    root $BASE_DIR/cctv/www;

    location /stream {
        proxy_pass http://127.0.0.1:$MJPEG_SOURCE_PORT;
        proxy_buffering off;
    }

    location /janus/ {
        proxy_pass http://127.0.0.1:$JANUS_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

brew services restart nginx >/dev/null
sleep 2
if ! lsof -i :$MJPEG_PORT >/dev/null; then
  echo "❌ Nginx failed to bind to port $MJPEG_PORT. Please inspect logs or validate configuration."
  exit 1
fi

###############################################################################
# 8.  Ultra‑light Dashboard (static HTML)
###############################################################################
cat > "$BASE_DIR/cctv/www/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CCTV Live Viewer</title><style>body{font-family:system-ui,Arial,sans-serif;margin:0;padding:2rem;display:flex;flex-direction:column;gap:1rem;max-width:720px}.btn,input{padding:.6rem .8rem;font-size:1rem;border:1px solid #ccc;border-radius:.5rem}.btn{cursor:pointer;background:#007ACC;color:#fff}.btn:hover{background:#005EA8}video{width:100%;border:1px solid #ccc;border-radius:1rem}</style></head><body><h2>🔍 Low‑Bandwidth CCTV Viewer</h2><input id="url" class="input" value="http://localhost:8083/stream"><button id="load" class="btn">Load Stream</button><video id="player" controls autoplay muted></video><script>document.getElementById('load').addEventListener('click',()=>{const u=document.getElementById('url').value.trim();if(!u){alert('Enter a URL');return;}const v=document.getElementById('player');v.src=u;v.play().catch(console.error);});</script></body></html>
EOF

cat > "$BASE_DIR/cctv/www/webrtc.html" <<'EOF'
<!DOCTYPE html>
<html>
<head><title>WebRTC Stream</title></head>
<body>
  <h2>🎥 WebRTC Stream via Janus Gateway</h2>
  <a href="/janus/demos/streamingtest.html" target="_blank">Launch Janus Streaming Test UI</a>
</body>
</html>
EOF

###############################################################################
# 9.  MotionEye Container
###############################################################################
echo "ℹ️  Deploying MotionEye container instance via Docker…"
CONTAINER_NAME="motioneye"
IMAGE_NAME="ghcr.io/motioneye-project/motioneye:edge"

if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^$IMAGE_NAME$"; then
  docker pull $IMAGE_NAME
fi

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  docker start $CONTAINER_NAME >/dev/null
else
  docker run -d --restart unless-stopped --name $CONTAINER_NAME \
    -p $MOTIONEYE_PORT:8765 \
    -v "$BASE_DIR/cctv/motioneye:/etc/motioneye" \
    -v "$BASE_DIR/cctv/clips:/var/lib/motioneye" \
    $IMAGE_NAME >/dev/null
fi

###############################################################################
# 9.5 Janus Gateway for WebRTC (Docker)
###############################################################################
JANUS_CONTAINER="janus-gateway"
echo "ℹ️  Deploying Janus WebRTC Gateway via Docker…"

if docker ps -a --format '{{.Names}}' | grep -q "^${JANUS_CONTAINER}$"; then
  docker start $JANUS_CONTAINER >/dev/null
else
  docker run -d --name $JANUS_CONTAINER \
    -p $JANUS_PORT:8088 \
    -p 8188:8188 \
    -p 10000-10200:10000-10200/udp \
    --restart unless-stopped \
    meetecho/janus-gateway
fi

###############################################################################
# 10. Epilogue
###############################################################################
cat <<EON

✅ Provisioning complete. System is now operational.

Access endpoints (local host):
— Live MJPEG Stream   : http://localhost:$MJPEG_PORT/stream
— Viewer Dashboard    : http://localhost:$MJPEG_PORT
— WebRTC Viewer       : http://localhost:$MJPEG_PORT/webrtc.html
— Janus Test Console  : http://localhost:$MJPEG_PORT/janus/demos/streamingtest.html
— MotionEye UI        : http://localhost:$MOTIONEYE_PORT
— WireGuard subnet    : $WG_NETWORK (gateway $WG_SERVER_IP)

Next steps:
1)  Append client [Peer] blocks to $CFG_FILE.
2)  Optionally start motion detection: $BASE_DIR/cctv/stream.sh &
3)  To stream to Janus WebRTC: ffmpeg -re -i "$STREAM_URL" -c:v libx264 -f mpegts udp://127.0.0.1:5004
EON

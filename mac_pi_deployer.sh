#!/bin/bash
# File: mac_pi_deployer.sh
# Purpose: Configure macOS as an IP camera gateway with RTSP URL rtsp://admin:asAS1212@192.168.1.64

# Exit on error
set -e

# Check for Homebrew
if ! command -v brew >/dev/null 2>&1; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add Homebrew to PATH
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Install required packages without sudo
echo "Installing WireGuard, FFmpeg, Nginx, and Docker..."
brew install wireguard-tools ffmpeg nginx docker || {
    echo "Homebrew installation failed. Check Homebrew setup and try again."
    exit 1
}

# Check if Docker Desktop is installed and running
if ! docker info >/dev/null 2>&1; then
    echo "Docker Desktop is not running. Please install and start Docker Desktop from https://www.docker.com/products/docker-desktop/"
    echo "After starting Docker, re-run this script."
    exit 1
}

# Configure WireGuard VPN
echo "Setting up WireGuard VPN..."
mkdir -p ~/wireguard
wg genkey | tee ~/wireguard/server.key | wg pubkey > ~/wireguard/server.pub
PRIVATE_KEY=$(cat ~/wireguard/server.key)

cat << EOF > ~/wireguard/wg0.conf
[Interface]
Address = 10.10.10.1/24
ListenPort = 51820
PrivateKey = $PRIVATE_KEY

# Add client peers manually here
EOF

# Start WireGuard (requires sudo)
echo "Starting WireGuard... (You may need to run 'sudo wg-quick up ~/wireguard/wg0' manually)"
sudo wg-quick up ~/wireguard/wg0 || {
    echo "WireGuard failed to start. Ensure port 51820 is open and try 'sudo wg-quick up ~/wireguard/wg0' manually."
}

# Configure FFmpeg for motion detection
echo "Setting up FFmpeg for motion detection..."
mkdir -p ~/cctv/clips
cat << EOF > ~/cctv/stream.sh
#!/bin/bash
ffmpeg -i "rtsp://admin:asAS1212@192.168.1.64" -vf "select='gt(scene,0.1)'" -vsync vfr -f segment -segment_time 10 -segment_format mp4 ~/cctv/clips/motion_%04d.mp4
EOF
chmod +x ~/cctv/stream.sh

# Configure FFmpeg streaming server
cat << EOF > ~/cctv/stream_server.sh
#!/bin/bash
ffmpeg -i "rtsp://admin:asAS1212@192.168.1.64" -c:v copy -f mjpeg http://127.0.0.1:8082
EOF
chmod +x ~/cctv/stream_server.sh

# Configure Nginx for viewer dashboard
echo "Setting up Nginx..."
mkdir -p ~/cctv/www
cat << EOF | sudo tee /usr/local/etc/nginx/nginx.conf
worker_processes 1;
events { worker_connections 1024; }
http {
    server {
        listen 8081;
        root ~/cctv/www;
        location /stream {
            proxy_pass http://127.0.0.1:8082;
        }
    }
}
EOF
# Start Nginx
brew services start nginx || {
    echo "Nginx failed to start. Check configuration and try 'brew services start nginx' manually."
}

# Run MotionEye in Docker
echo "Setting up MotionEye in Docker..."
docker run -d --name motioneye -p 8765:8765 -v ~/cctv/motioneye:/etc/motioneye -v ~/cctv/clips:/var/lib/motioneye ccrisan/motioneye:master-amd64 || {
    echo "Docker MotionEye failed to start. Ensure Docker is running and try again."
}

# Create viewer dashboard
echo "Creating viewer dashboard..."
cat << EOF > ~/cctv/www/viewer_dashboard.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CCTV Viewer Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: #f0f0f0; }
        .container { max-width: 800px; margin: auto; text-align: center; }
        h1 { font-size: 24px; color: #333; }
        input[type="text"] { padding: 10px; width: 300px; font-size: 16px; }
        button { padding: 10px 20px; font-size: 16px; cursor: pointer; background: #007bff; color: white; border: none; }
        button:hover { background: #0056b3; }
        img { max-width: 100%; height: auto; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>CCTV Live Stream</h1>
        <input type="text" id="streamUrl" placeholder="Enter MJPEG URL (e.g., http://10.10.10.1:8081/stream)" value="http://localhost:8081/stream">
        <button onclick="loadStream()">Load Stream</button>
        <br>
        <img id="stream" src="" alt="Live Stream">
    </div>
    <script>
        function loadStream() {
            const url = document.getElementById('streamUrl').value;
            const stream = document.getElementById('stream');
            if (url) {
                stream.src = url;
            } else {
                alert('Please enter a valid MJPEG URL');
            }
        }
    </script>
</body>
</html>
EOF

echo "Setup complete! Follow these manual steps:"
echo "1. Run '~/cctv/stream.sh' to start motion detection."
echo "2. Run '~/cctv/stream_server.sh' to start the streaming server."
echo "3. Access MotionEye at http://localhost:8765 and add the camera (rtsp://admin:asAS1212@192.168.1.64)."
echo "4. Access the viewer dashboard at http://localhost:8081/viewer_dashboard.html."
echo "5. Configure WireGuard clients: Add [Peer] to ~/wireguard/wg0.conf and forward port 51820 on your router."
echo "6. Monitor data usage manually to stay under 1.3 GB/month (no tc on macOS)."
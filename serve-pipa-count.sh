#!/bin/bash
# PiPa Count - Local Server Launcher
# Run this from the folder containing pipa-count.html
# Then open the URL on your iPhone (same WiFi network)

PORT=8080
FILE_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get local IP
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)

echo ""
echo "  🍷 PiPa Count Server"
echo "  ─────────────────────"
echo "  Local:   http://localhost:$PORT/pipa-count.html"
if [ -n "$IP" ]; then
echo "  iPhone:  http://$IP:$PORT/pipa-count.html"
fi
echo ""
echo "  Open the iPhone URL in Safari, then:"
echo "  Share → Add to Home Screen"
echo ""
echo "  Press Ctrl+C to stop the server"
echo ""

cd "$FILE_DIR"
python3 -m http.server $PORT

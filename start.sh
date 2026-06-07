#!/usr/bin/env bash
set -e

PORT=8012

echo "Starting Smoke & Terrain on http://localhost:${PORT}"
flutter run -d web-server --web-port=${PORT} --web-hostname=localhost

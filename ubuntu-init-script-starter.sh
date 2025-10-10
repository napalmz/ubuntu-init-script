#!/usr/bin/env bash
set -euo pipefail

# Configurazione variabili
SCRIPT_NAME="ubuntu-init-script-worker.sh"
SCRIPT_URL="https://raw.githubusercontent.com/napalmz/ubuntu-init-script/main/$SCRIPT_NAME"
SCRIPT_OUT="/tmp/$SCRIPT_NAME"

command -v curl >/dev/null 2>&1 || sudo apt-get update && sudo apt-get install -y curl

echo "[*] Scarico $SCRIPT_NAME da GitHub..."
curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_OUT"
chmod +x "$SCRIPT_OUT"

echo "[*] Eseguo $SCRIPT_NAME..."
"$SCRIPT_OUT"
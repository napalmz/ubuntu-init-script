#!/usr/bin/env bash
set -euo pipefail

# Rileva l’utente reale (non root) per file in $HOME e gruppi
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
OS_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
ARCH="$(dpkg --print-architecture)"

echo "[*] Utente target: $TARGET_USER  Home: $TARGET_HOME  Codename: $OS_CODENAME  Arch: $ARCH"

# 1) Sudo senza password per l’utente
echo "[*] Configuro sudo NOPASSWD per $TARGET_USER..."
echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/90-$TARGET_USER-nopasswd" >/dev/null
sudo chmod 440 "/etc/sudoers.d/90-$TARGET_USER-nopasswd"
sudo visudo -cf "/etc/sudoers.d/90-$TARGET_USER-nopasswd" >/dev/null

# 2) Aggiorna sistema
echo "[*] Aggiorno il sistema..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get -o Dpkg::Options::="--force-confnew" \
  -o Dpkg::Options::="--force-confdef" \
  -y --with-new-pkgs upgrade
sudo apt-get -y autoremove

# 3) Installa Docker CE
echo "[*] Aggiungo Docker Repo..."
sudo apt-get install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${OS_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
echo "[*] Installo Docker..."
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$TARGET_USER" || true

# 4) Installa Tailscale
echo "[*] Installo Tailscale..."
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${OS_CODENAME}.noarmor.gpg" | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${OS_CODENAME}.tailscale-keyring.list" | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y tailscale
sudo systemctl enable --now tailscaled

# 5) Utility scripts nella home dell’utente
echo "[*] Creo utility scripts in $TARGET_HOME ..."
cat > "$TARGET_HOME/upgrade.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt update
sudo apt -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confdef" --with-new-pkgs -y upgrade
sudo apt -y autoremove
if [ -f /var/run/reboot-required ]; then
  echo -e "[*** Hello $USER, you \033[1mMUST REBOOT\033[0m your machine ***]"
else
  echo "[*** Hello $USER, no reboot needed ***]"
fi
EOF

cat > "$TARGET_HOME/docker-prune.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
docker system df
read -r -p "Prune tutto (y/N)? " ans
[[ "${ans,,}" == "y" ]] && docker system prune -a --volumes
EOF

cat > "$TARGET_HOME/sysinfo.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Hostname: $(hostname)"
echo "Kernel:   $(uname -r)"
echo "Uptime:   $(uptime -p)"
echo "IP:       $(hostname -I || true)"
echo "Disk:"
df -hT | awk 'NR==1 || /^\/dev\//'
echo "Docker:"
command -v docker >/dev/null && docker --version || echo "Docker non installato"
EOF

cat > "$TARGET_HOME/tailscale-up.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Esegui login su Tailscale..."
sudo tailscale up --ssh
EOF

sudo chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/"{upgrade.sh,docker-prune.sh,sysinfo.sh,tailscale-up.sh}
chmod +x "$TARGET_HOME/"{upgrade.sh,docker-prune.sh,sysinfo.sh,tailscale-up.sh}

# 6) Altre operazioni utili per template
echo "[*] Imposto logrotate di base e pulizia..."
sudo apt-get install -y logrotate
sudo logrotate -d /etc/logrotate.conf >/dev/null || true

# 7) Pulizia history e log di apt (per template pulito)
echo "[*] Ripulisco tracce comando e cache..."
unset HISTFILE || true
history -c || true
rm -f "$TARGET_HOME/.bash_history" || true
sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb || true
sudo apt-get update -y >/dev/null

# 8) Chiedi se cancellare questo script
read -r -p "[?] Cancellare $(basename "$0") (y/N)? " ans
if [[ "${ans,,}" == "y" ]]; then
  rm -- "$0" || true
  echo "[*] Script rimosso."
fi

echo "[✓] Preparazione template completata. Logout e login per applicare il gruppo docker."
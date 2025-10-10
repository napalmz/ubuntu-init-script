#!/usr/bin/env bash
set -euo pipefail

# ---- Detect context ----
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
OS_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
ARCH="$(dpkg --print-architecture)"

log() { echo "[ubuntu-init] $*"; }

log "User: $TARGET_USER  Home: $TARGET_HOME  Codename: $OS_CODENAME  Arch: $ARCH"
export DEBIAN_FRONTEND=noninteractive

# ---- Helpers ----
need_pkg() { dpkg -s "$1" >/dev/null 2>&1 || return 0 && return 1; }
file_has_line() { local f="$1"; local patt="$2"; [ -f "$f" ] && sudo grep -Fxq "$patt" "$f"; }
ensure_apt_update() { sudo apt-get update -y; }

# ---- 1) Ensure sudo NOPASSWD for TARGET_USER ----
SUDOERS_DROP="/etc/sudoers.d/90-$TARGET_USER-nopasswd"
NOPASSWD_LINE="$TARGET_USER ALL=(ALL) NOPASSWD:ALL"
if ! file_has_line "$SUDOERS_DROP" "$NOPASSWD_LINE"; then
  log "Configuro sudo NOPASSWD per $TARGET_USER"
  echo "$NOPASSWD_LINE" | sudo tee "$SUDOERS_DROP" >/dev/null
  sudo chmod 440 "$SUDOERS_DROP"
  sudo visudo -cf "$SUDOERS_DROP" >/dev/null
else
  log "Sudoers già configurato"
fi

# ---- 2) System upgrade (safe) ----
log "Aggiornamento sistema"
sudo apt-get update -y
sudo apt-get -o Dpkg::Options::="--force-confnew" \
  -o Dpkg::Options::="--force-confdef" -y --with-new-pkgs upgrade || true
sudo apt-get -y autoremove || true

# ---- 3) Docker CE repo + install (idempotent) ----
DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"
if ! command -v docker >/dev/null 2>&1; then
  log "Docker non presente: preparo repo e installo"
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  sudo install -m 0755 -d /etc/apt/keyrings
  if [ ! -f "$DOCKER_KEYRING" ]; then
    curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" | sudo gpg --dearmor -o "$DOCKER_KEYRING"
    sudo chmod a+r "$DOCKER_KEYRING"
  fi
  if [ ! -f "$DOCKER_LIST" ] || ! grep -q "download.docker.com/linux/ubuntu" "$DOCKER_LIST"; then
    echo "deb [arch=${ARCH} signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/ubuntu ${OS_CODENAME} stable" | \
      sudo tee "$DOCKER_LIST" >/dev/null
  fi
  ensure_apt_update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$TARGET_USER" || true
else
  log "Docker già installato"
  # Assicura abilitazione servizio
  sudo systemctl enable --now docker || true
  sudo usermod -aG docker "$TARGET_USER" || true
fi

# ---- 4) Tailscale repo + install (idempotent) ----
TS_KEYRING="/usr/share/keyrings/tailscale-archive-keyring.gpg"
TS_LIST="/etc/apt/sources.list.d/tailscale.list"
if ! command -v tailscale >/dev/null 2>&1; then
  log "Tailscale non presente: preparo repo e installo"
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${OS_CODENAME}.noarmor.gpg" | sudo tee "$TS_KEYRING" >/dev/null
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${OS_CODENAME}.tailscale-keyring.list" | sudo tee "$TS_LIST" >/dev/null
  ensure_apt_update
  sudo apt-get install -y tailscale
  sudo systemctl enable --now tailscaled
else
  log "Tailscale già installato"
  sudo systemctl enable --now tailscaled || true
fi

# ---- 5) Utility scripts: overwrite to keep updated ----
log "Creo/Aggiorno utility scripts in $TARGET_HOME"
install_user_script() {
  local path="$1"; shift
  cat >"$path" <<'EOS'
$CONTENT$
EOS
  sudo chown "$TARGET_USER:$TARGET_USER" "$path"
  chmod +x "$path"
}

# upgrade.sh
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

# docker-prune.sh
cat > "$TARGET_HOME/docker-prune.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
docker system df
read -r -p "Prune tutto (y/N)? " ans
[[ "${ans,,}" == "y" ]] && docker system prune -a --volumes
EOF

# sysinfo.sh
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

# tailscale-up.sh
cat > "$TARGET_HOME/tailscale-up.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Esegui login su Tailscale..."
sudo tailscale up --ssh
EOF

sudo chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/"{upgrade.sh,docker-prune.sh,sysinfo.sh,tailscale-up.sh}
chmod +x "$TARGET_HOME/"{upgrade.sh,docker-prune.sh,sysinfo.sh,tailscale-up.sh}

# ---- 6) Utilities: logrotate present ----
if need_pkg logrotate; then
  log "Installo logrotate"
  sudo apt-get install -y logrotate
else
  log "logrotate già installato"
fi

# ---- 7) Cleanup: history and apt caches ----
log "Pulizia tracce e cache"
unset HISTFILE || true
history -c || true
rm -f "$TARGET_HOME/.bash_history" || true
sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb || true
sudo apt-get update -y >/dev/null || true

# ---- 8) Optionally self-remove ----
# Determina il percorso sorgente in modo affidabile.
SCRIPT_SRC="${BASH_SOURCE[0]:-$0}"
read -r -p "[?] Cancellare $(basename "$SCRIPT_SRC") (y/N)? " ans || true
if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
  # Se eseguito via process substitution (/dev/fd/* o /proc/*), non provare a rimuovere.
  if [[ "$SCRIPT_SRC" =~ ^/dev/fd/ || "$SCRIPT_SRC" =~ ^/proc/ ]]; then
    log "Esecuzione da stream (\"$SCRIPT_SRC\"). Salto auto-rimozione."
  elif [ -f "$SCRIPT_SRC" ]; then
    rm -- "$SCRIPT_SRC" || true
    log "Script rimosso"
  else
    log "Percorso script non rimovibile: $SCRIPT_SRC"
  fi
fi

# ---- 9) Extra: pulizia history utente ----
log "Pulizia completa history dell'utente $TARGET_USER"
# shell history
sudo -u "$TARGET_USER" bash -c 'history -c || true; : > ~/.bash_history || true; unset HISTFILE || true'
# zsh
sudo -u "$TARGET_USER" bash -c ': > ~/.zsh_history 2>/dev/null || true'
# vari interpreti REPL
sudo -u "$TARGET_USER" bash -c 'for f in ~/.python_history ~/.node_repl_history ~/.psql_history ~/.mysql_history ~/.sqlite_history ~/.lesshst ~/.nano_history ~/.viminfo ~/.wget-hsts; do [ -f "$f" ] && : > "$f"; done'
# fish e altri
sudo -u "$TARGET_USER" bash -c ': > ~/.local/share/fish/fish_history 2>/dev/null || true; : > ~/.local/share/recently-used.xbel 2>/dev/null || true'
# journal user-level
journalctl --user --rotate 2>/dev/null || true
journalctl --user --vacuum-time=1s 2>/dev/null || true

log "Template pronto. Logout/login per gruppo docker."
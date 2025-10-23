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

# ---- 1b) Password utente: opzionale con prompt ----
read -r -p "[?] Vuoi cambiare la password per $TARGET_USER (y/N)? " ans_pw || true
if [[ "${ans_pw,,}" == "y" ]]; then
  log "Cambio password per $TARGET_USER"
  sudo passwd "$TARGET_USER"
fi

#
# ---- 2) System upgrade (opzionale) ----
read -r -p "[?] Eseguire aggiornamento del sistema ora (y/N)? " ans_up || true
if [[ "${ans_up,,}" == "y" ]]; then
  UPGRADE_QUIET="${INIT_UPGRADE_QUIET:-0}"
  LOGFILE="/var/log/ubuntu-init-upgrade.log"
  if [[ "$UPGRADE_QUIET" == "1" ]]; then
    log "Aggiornamento sistema in modalità quiet. Log: $LOGFILE"
    sudo bash -c "\
      apt-get update -y -qq && \
      apt-get -o Dpkg::Options::='--force-confnew' -o Dpkg::Options::='--force-confdef' \
              -o Dpkg::Use-Pty=0 -y --with-new-pkgs -qq upgrade && \
      apt-get -y -qq autoremove" >"$LOGFILE" 2>&1 || true
  else
    log "Aggiornamento sistema"
    sudo apt-get update -y
    sudo apt-get -o Dpkg::Options::="--force-confnew" \
      -o Dpkg::Options::="--force-confdef" -y --with-new-pkgs upgrade || true
    sudo apt-get -y autoremove || true
  fi
else
  log "Aggiornamento sistema saltato"
fi

#
# ---- 2c) Hostname: opzionale con prompt ----
current_hn="$(hostname)"
read -r -p "[?] Vuoi cambiare l'hostname (attuale: ${current_hn}) (y/N)? " ans || true
if [[ "${ans,,}" == "y" ]]; then
  read -r -p "Nuovo hostname (FQDN o semplice, es. myhost o vm01.lab): " NEW_HN
  # Validazione semplice RFC 1123
  if [[ -z "$NEW_HN" ]] || ! [[ "$NEW_HN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    log "Hostname non valido. Salto modifica."
  else
    log "Imposto hostname a $NEW_HN"
    sudo hostnamectl set-hostname "$NEW_HN" || true
    # Aggiorna /etc/hosts per 127.0.1.1 -> short hostname
    SHORT_HN="${NEW_HN%%.*}"
    if [ -f /etc/hosts ]; then
      sudo cp /etc/hosts "/etc/hosts.bak.$(date +%s)"
      if grep -qE '^127\.0\.1\.1\b' /etc/hosts; then
        sudo sed -i "s/^127\\.0\\.1\\.1.*/127.0.1.1\t${SHORT_HN}/" /etc/hosts
      else
        echo -e "127.0.1.1\t${SHORT_HN}" | sudo tee -a /etc/hosts >/dev/null
      fi
    fi
    log "Hostname aggiornato runtime e in modo persistente."
  fi
fi

# ---- 2e) Post-clone sysprep: opzionale ----
read -r -p "[?] Eseguire post-clone sysprep (rigenera machine-id, chiavi SSH, pulisce DHCP lease)? (y/N) " ans_sysprep || true
if [[ "${ans_sysprep,,}" == "y" ]]; then
  log "Rigenero SSH host keys"
  sudo systemctl stop ssh 2>/dev/null || true
  sudo rm -f /etc/ssh/ssh_host_*key* || true
  sudo ssh-keygen -A
  sudo systemctl start ssh 2>/dev/null || true

  log "Rigenero machine-id"
  # Svuota e rigenera machine-id (necessario per unicità host)
  sudo truncate -s 0 /etc/machine-id || true
  sudo rm -f /var/lib/dbus/machine-id || true
  sudo systemd-machine-id-setup || true

  # Se presente cloud-init, pulisce stato e rigenera machine-id lato cloud-init
  if command -v cloud-init >/dev/null 2>&1; then
    log "Pulizia cloud-init"
    sudo cloud-init clean --logs --machine-id || true
  fi

  log "Pulisce lease DHCP"
  sudo rm -f /var/lib/dhcp/* /var/lib/NetworkManager/*lease* 2>/dev/null || true

  log "Reset random-seed"
  sudo systemd-random-seed --reset 2>/dev/null || true

  # Opzionale: reset Tailscale per evitare conflitti di identity su cloni
  if command -v tailscale >/dev/null 2>&1; then
    read -r -p "[?] Resettare l'identità Tailscale su questo clone (y/N)? " ans_ts || true
    if [[ "${ans_ts,,}" == "y" ]]; then
      log "Reset Tailscale"
      sudo systemctl stop tailscaled || true
      sudo tailscale logout 2>/dev/null || true
      sudo rm -f /var/lib/tailscale/tailscaled.state || true
      sudo systemctl start tailscaled || true
      echo "[nota] Esegui 'tailscale up --ssh' per riautenticare questo nodo."
    fi
  fi
fi

# ---- 2d) DHCP: usa MAC come client-id (netplan/dhclient) ----
log "Forzo DHCP client-id = MAC"
changed=0
if sudo ls /etc/netplan/*.y*ml >/dev/null 2>&1; then
  for f in /etc/netplan/*.y*ml; do
    [ -f "$f" ] || continue
    if sudo grep -Eq '^\s*dhcp4:\s*true\s*$' "$f"; then
      if ! sudo grep -Eq '^\s*dhcp-identifier:\s*mac\s*$' "$f"; then
        log "Aggiorno netplan: $f -> dhcp-identifier: mac"
        sudo cp "$f" "$f.bak.$(date +%s)"
        tmpfile="$(sudo mktemp /etc/netplan/.netplanXXXX.yaml)"
        # Legge con sudo e scrive con sudo per evitare problemi di permessi
        sudo awk '
          {
            print $0;
            if ($0 ~ /(^|[[:space:]])dhcp4:[[:space:]]*true[[:space:]]*$/) {
              match($0, /^[[:space:]]*/); ind=substr($0, RSTART, RLENGTH);
              print ind "dhcp-identifier: mac";
            }
          }
        ' "$f" | sudo tee "$tmpfile" >/dev/null
        sudo mv "$tmpfile" "$f"
        changed=1
      else
        log "Netplan già configurato in $f"
      fi
    fi
  done
  if [ "$changed" = "1" ]; then
    log "Applico netplan"
    sudo netplan apply || true
  fi
else
  log "Netplan non trovato. Verifico dhclient"
fi

# Fallback per dhclient: usa MAC come client-id
if [ -d /etc/dhcp ]; then
  DHCLIENT_CONF=/etc/dhcp/dhclient.conf
  if [ -f "$DHCLIENT_CONF" ] && grep -Eq 'dhcp-client-identifier' "$DHCLIENT_CONF"; then
    log "dhclient.conf ha già una direttiva client-id"
  else
    log "Configuro dhclient per usare hardware (MAC) come client-id"
    sudo install -m 0644 /dev/null "$DHCLIENT_CONF" 2>/dev/null || true
    sudo cp "$DHCLIENT_CONF" "$DHCLIENT_CONF.bak.$(date +%s)" 2>/dev/null || true
    sudo bash -c "cat >> '$DHCLIENT_CONF'" <<'EOF'
# Imposta il client-id al MAC address (RFC 2132 option 61)
send dhcp-client-identifier = hardware;
EOF
  fi
fi

# ---- 2b) Imposta timezone ----
log "Imposto timezone Europe/Rome"
sudo timedatectl set-timezone Europe/Rome || true

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

# ---- 5b) Base packages: ensure essentials ----
log "Verifico e installo pacchetti base"
BASE_PACKAGES=(open-vm-tools curl wget vim htop net-tools dnsutils unzip gnupg ca-certificates lsb-release software-properties-common iputils-ping)
for pkg in "${BASE_PACKAGES[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    log "$pkg già installato"
  else
    log "Installo $pkg"
    sudo apt-get install -y "$pkg"
  fi
done

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

# docker-portainer-agent-update.sh
cat > "$TARGET_HOME/docker-portainer-agent-update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Uso: ./docker-portainer-agent-update.sh [AGENT_SECRET]
# Persistenza del secret: $HOME/.config/portainer/agent.env
SECRET_FILE="$HOME/.config/portainer/agent.env"
mkdir -p "$(dirname "$SECRET_FILE")"
SAVED_SECRET=""
if [ -f "$SECRET_FILE" ]; then
  # shellcheck disable=SC1090
  . "$SECRET_FILE"
  SAVED_SECRET="${AGENT_SECRET:-}"
  # Evita che AGENT_SECRET influenzi la scelta automatica
  unset AGENT_SECRET || true
fi

# Precedenze: argomento > prompt con default del secret salvato (se esiste)
SECRET="${1:-}"
if [[ -z "${SECRET}" && -n "${SAVED_SECRET}" ]]; then
  echo "[portainer-agent] secret salvato trovato in $SECRET_FILE"
  read -r -p "AGENT_SECRET [Invio per riutilizzare quello salvato]: " INPUT || true
  if [[ -z "${INPUT}" ]]; then
    SECRET="$SAVED_SECRET"
    echo "[portainer-agent] uso secret salvato"
  else
    SECRET="$INPUT"
  fi
elif [[ -z "${SECRET}" ]]; then
  read -r -p "AGENT_SECRET: " SECRET || true
fi

if [[ -z "${SECRET}" ]]; then
  echo "Errore: AGENT_SECRET mancante" >&2
  exit 1
fi

# Salva/aggiorna secret in chiaro con permessi restrittivi
printf 'AGENT_SECRET=%s\n' "$SECRET" >"$SECRET_FILE"
chmod 600 "$SECRET_FILE"

echo "[portainer-agent] pull latest"
sudo docker pull portainer/agent:latest

if sudo docker ps -a --format '{{.Names}}' | grep -Fxq portainer_agent; then
  echo "[portainer-agent] stop+rm container esistente"
  sudo docker stop portainer_agent || true
  sudo docker rm portainer_agent || true
fi

echo "[portainer-agent] run container"
sudo docker run --name portainer_agent --restart=always -d \
  -p 9001:9001 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/docker/volumes:/var/lib/docker/volumes \
  -e AGENT_SECRET="$SECRET" \
  portainer/agent:latest

echo "[portainer-agent] ok"
EOF

sudo chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/"{upgrade.sh,docker-prune.sh,sysinfo.sh,tailscale-up.sh,docker-portainer-agent-update.sh}
chmod +x "$TARGET_HOME/"{upgrade.sh,docker-prune.sh,sysinfo.sh,tailscale-up.sh,docker-portainer-agent-update.sh}

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

# ---- 10) Opzionale: riavvio macchina ----
read -r -p "[?] Riavviare ora la macchina (y/N)? " ans_reboot || true
if [[ "${ans_reboot,,}" == "y" ]]; then
  log "Riavvio sistema in corso..."
  sudo reboot now
else
  log "Riavvio saltato. Esegui 'sudo reboot now' manualmente se necessario."
fi
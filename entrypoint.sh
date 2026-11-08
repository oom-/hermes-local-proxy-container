#!/bin/bash
set -euo pipefail

DATA=/data
CONF=$DATA/config.env
KEY=$DATA/id_ed25519
PORT_FIRST=1081
PORT_LAST=1090
SOCKS_PORT=1080

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

ssh_vps() {
  ssh -i "$KEY" -p "$VPS_PORT" \
    -o UserKnownHostsFile="$DATA/known_hosts" -o StrictHostKeyChecking="${STRICT:-yes}" \
    -o BatchMode=yes -o ConnectTimeout=10 "$@"
}

hermes_prompt() {
  echo "=================== PROMPT TO SEND TO HERMES ==================="
  awk '/hermes-prompt:end/{f=0} f && !/^```/; /hermes-prompt:start/{f=1}' /app/README.md
  echo "================================================================"
}

ask() {  # ask VAR "question" default
  local answer
  read -rp "$2 [${3}]: " answer
  printf -v "$1" '%s' "${answer:-$3}"
}

setup() {
  mkdir -p "$DATA"
  if [ -f "$CONF" ] || [ -f "$KEY" ]; then
    local state="NOT finished" choice
    grep -q '^BIND_IP=.' "$CONF" 2>/dev/null && state="finished"
    echo "A previous setup was found ($state)."
    ask choice "Resume with the saved answers and SSH key (r) or start from scratch (s)?" r
    case "$choice" in
      r|R) ;;
      s|S)
        rm -f "$CONF" "$KEY" "$KEY.pub" "$DATA/known_hosts" "$DATA/remote-bootstrap.sh"
        echo "Cleared. A new SSH key will be generated: remove the old one from authorized_keys on the VPS." ;;
      *) die "answer r or s" ;;
    esac
    echo
  fi
  [ -f "$CONF" ] && . "$CONF"

  echo "== Step 1: VPS connection =="
  ask VPS_HOST "VPS IP or hostname" "${VPS_HOST:-}"
  ask VPS_USER "SSH user on the VPS (not root)" "${VPS_USER:-}"
  ask VPS_PORT "SSH port" "${VPS_PORT:-22}"
  [[ "$VPS_HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || die "invalid host"
  [[ "$VPS_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid user name"
  [ "$VPS_USER" != root ] || die "root is not allowed, use a normal user"
  [[ "$VPS_PORT" =~ ^[0-9]+$ ]] || die "invalid port"
  # saved now so a re-run after an interrupted setup pre-fills the answers
  printf 'VPS_HOST=%s\nVPS_USER=%s\nVPS_PORT=%s\n' "$VPS_HOST" "$VPS_USER" "$VPS_PORT" > "$CONF"

  echo; echo "== Step 2: SSH key =="
  if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N "" -f "$KEY" \
      -C "hermes-proxy-setup-${DEVICE_NAME:-$(hostname)}-$(date +%F)"
  fi
  echo "Add this line to ~$VPS_USER/.ssh/authorized_keys on the VPS:"
  echo; cat "$KEY.pub"; echo
  read -rp "Press Enter once done... "

  echo; echo "== Step 3: testing SSH =="
  local who
  who=$(STRICT=accept-new ssh_vps "$VPS_USER@$VPS_HOST" whoami) || die "SSH connection failed"
  [ "$who" = "$VPS_USER" ] || die "whoami returned '$who', expected '$VPS_USER'"
  log "SSH OK, connected as $who"

  echo; echo "== Step 4: one-time root setup on the VPS =="
  sed -e "s/__SSH_USER__/$VPS_USER/" -e "s/__PORT_FIRST__/$PORT_FIRST/" -e "s/__PORT_LAST__/$PORT_LAST/" \
    /app/bootstrap.sh.tmpl > "$DATA/remote-bootstrap.sh"
  echo "Log in to the VPS as root (console or your usual way) and paste everything between the lines."
  echo "Also saved on this machine as /opt/hermes-local-proxy/remote-bootstrap.sh (default volume path)."
  echo "------------------------------------------------------------------"
  cat "$DATA/remote-bootstrap.sh"
  echo "------------------------------------------------------------------"
  read -rp "Press Enter once it printed DONE... "

  echo; echo "== Step 5: checking the VPS =="
  local info
  info=$(ssh_vps "$VPS_USER@$VPS_HOST" sudo -n /usr/local/bin/hermes-proxy-info) \
    || die "cannot run 'sudo hermes-proxy-info' on the VPS, did the root script finish?"
  echo "$info" | sed '/^--- last relay log lines ---$/q'
  BIND_IP=$(sed -n 's/^BIND_IP=//p' <<<"$info")
  [ -n "$BIND_IP" ] || die "no BIND_IP from the VPS"
  grep -qx 'RELAY_STATUS=running' <<<"$info" || die "relay container is not running on the VPS"
  grep -qx 'RELAY_ON_HERMES_NETWORK=yes' <<<"$info" || die "relay is not on the Hermes network"

  cat > "$CONF" <<EOF
VPS_HOST=$VPS_HOST
VPS_USER=$VPS_USER
VPS_PORT=$VPS_PORT
BIND_IP=$BIND_IP
EOF
  chmod 600 "$CONF" "$KEY"

  echo; echo "== Setup complete =="
  echo "Start the proxy (restarts on boot):"
  echo "  docker run -d --name hermes-local-proxy --restart always -v /opt/hermes-local-proxy:/data hermes-local-proxy"
  echo
  hermes_prompt
}

run() {
  [ -f "$CONF" ] && . "$CONF"
  [ -n "${BIND_IP:-}" ] || die "setup not finished, run: docker run -it --rm -v /opt/hermes-local-proxy:/data hermes-local-proxy setup"
  trap 'kill 0 2>/dev/null; exit 0' TERM INT

  hermes_prompt

  (while true; do microsocks -i 127.0.0.1 -p "$SOCKS_PORT"; log "microsocks exited, restarting"; sleep 1; done) &

  local port=$PORT_FIRST fails=0 start up delay pid
  while true; do
    log "tunnel: connecting to $VPS_USER@$VPS_HOST, exposing $BIND_IP:$port on the VPS"
    start=$(date +%s)
    ssh_vps -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -R "$BIND_IP:$port:127.0.0.1:$SOCKS_PORT" "$VPS_USER@$VPS_HOST" &
    pid=$!
    sleep 5
    kill -0 "$pid" 2>/dev/null && log "tunnel: UP on $BIND_IP:$port"
    wait "$pid" || true
    up=$(( $(date +%s) - start ))
    if [ "$up" -lt 20 ]; then
      # quick exit: VPS unreachable or port held by another device / stale session, try the next slot
      fails=$((fails + 1))
      port=$(( port >= PORT_LAST ? PORT_FIRST : port + 1 ))
    else
      fails=0
    fi
    delay=$(( fails > 5 ? 60 : 1 << fails ))
    log "tunnel: DOWN after ${up}s, retrying in ${delay}s"
    sleep "$delay"
  done
}

case "${1:-run}" in
  setup) setup ;;
  run) run ;;
  prompt) hermes_prompt ;;
  *) die "usage: setup | run | prompt" ;;
esac

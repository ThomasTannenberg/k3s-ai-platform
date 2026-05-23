#!/usr/bin/env bash

# 02-create-host-bridge.sh
# Erstellt eine Linux Bridge br0 auf dem Ubuntu Host.
# Die VMs können dadurch direkt im FRITZ!Box LAN laufen.
#
# Wichtig:
#   Dieses Skript sollte lokal am Rechner ausgeführt werden.
#   Bei falscher Netzwerkkonfiguration kann kurzzeitig die Verbindung abbrechen.
#   Für WLAN Interfaces ist diese Bridge Variante nicht empfohlen.

set -euo pipefail

BRIDGE_NAME="${BRIDGE_NAME:-br0}"
BRIDGE_IFACE="${BRIDGE_IFACE:-}"
NETPLAN_RENDERER="${NETPLAN_RENDERER:-NetworkManager}"

log() {
  echo "==> $*"
}

die() {
  echo "FEHLER: $*" >&2
  exit 1
}

if [ -z "$BRIDGE_IFACE" ]; then
  BRIDGE_IFACE="$(ip route show default | awk '{print $5; exit}')"
fi

[ -n "$BRIDGE_IFACE" ] || die "Konnte Default Netzwerkinterface nicht ermitteln."

if [[ "$BRIDGE_IFACE" == wl* ]] || [[ "$BRIDGE_IFACE" == wlan* ]]; then
  die "Das Default Interface ist WLAN ($BRIDGE_IFACE). Eine klassische Bridge ist damit nicht empfohlen."
fi

log "Bridge Name: $BRIDGE_NAME"
log "Physisches Interface: $BRIDGE_IFACE"
log "Netplan Renderer: $NETPLAN_RENDERER"

echo ""
echo "Dieses Skript ersetzt die aktive Netplan Konfiguration durch eine Bridge."
echo "Backup wird unter /etc/netplan/backup-k3s-ai-* erstellt."
echo ""
read -rp "Fortfahren? 'yes' zum Bestätigen: " confirm
[ "$confirm" = "yes" ] || { echo "Abgebrochen."; exit 0; }

BACKUP_DIR="/etc/netplan/backup-k3s-ai-$(date +%Y%m%d-%H%M%S)"

log "Backup der bestehenden Netplan Dateien erstellen: $BACKUP_DIR"
sudo mkdir -p "$BACKUP_DIR"

if ls /etc/netplan/*.yaml >/dev/null 2>&1; then
  sudo cp /etc/netplan/*.yaml "$BACKUP_DIR"/
  sudo rm -f /etc/netplan/*.yaml
fi

log "Neue Netplan Bridge Konfiguration schreiben"

sudo tee /etc/netplan/99-k3s-ai-bridge.yaml >/dev/null <<EOF
network:
  version: 2
  renderer: ${NETPLAN_RENDERER}
  ethernets:
    ${BRIDGE_IFACE}:
      dhcp4: false
      dhcp6: false
  bridges:
    ${BRIDGE_NAME}:
      interfaces:
        - ${BRIDGE_IFACE}
      dhcp4: true
      dhcp6: true
      accept-ra: true
      parameters:
        stp: false
        forward-delay: 0
EOF

log "Netplan Konfiguration erzeugen"
sudo netplan generate

log "Netplan anwenden"
sudo netplan apply

sleep 5

log "Aktuelle IP Adressen"
ip -br addr show "$BRIDGE_NAME" || true

log "Bridge Status"
bridge link || true

echo ""
echo "Bridge wurde erstellt."
echo "Falls Netzwerkprobleme auftreten, kann das Backup aus $BACKUP_DIR zurückkopiert werden."
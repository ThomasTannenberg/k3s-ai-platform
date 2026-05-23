#!/usr/bin/env bash

# 99-cleanup.sh
# Löscht die lokalen libvirt VMs, Disks, Seed ISOs, DHCP Reservierungen,
# SSH known_hosts Einträge und lokale cloud-init Dateien.

set -euo pipefail

REMOVE_BASE_IMAGE="${REMOVE_BASE_IMAGE:-0}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-jammy}"
LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"

CLOUD_IMG_BASE="/var/lib/libvirt/boot/${UBUNTU_RELEASE}-server-cloudimg-amd64.img"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLOUD_INIT_BASE="${CLOUD_INIT_BASE:-$REPO_ROOT/tmp/cloud-init}"

VMS=(
  "k3s-lb-1|52:54:00:00:00:10|192.168.178.50"
  "k3s-server-1|52:54:00:00:00:11|192.168.178.51"
  "k3s-agent-tools-1|52:54:00:00:00:22|192.168.178.62"
)

read -rp "WARNUNG: Alle Cluster VMs werden zerstört. 'yes' zum Bestätigen: " confirm
[ "$confirm" = "yes" ] || { echo "Abgebrochen."; exit 0; }

for vm_def in "${VMS[@]}"; do
  IFS='|' read -r name mac ip <<< "$vm_def"

  echo "==> Bereinige $name"

  if virsh list --all --name | grep -qw "$name"; then
    echo "    VM stoppen und undefinieren"
    virsh destroy "$name" 2>/dev/null || true
    virsh undefine "$name" --remove-all-storage --nvram 2>/dev/null \
      || virsh undefine "$name" --remove-all-storage 2>/dev/null \
      || true
  fi

  echo "    Seed ISO entfernen"
  sudo rm -f "/var/lib/libvirt/boot/${name}-seed.iso"

  echo "    cloud-init Dateien entfernen"
  rm -rf "${CLOUD_INIT_BASE:?}/${name}"

  echo "    DHCP Reservation entfernen, falls im libvirt default Netzwerk vorhanden"
  if virsh net-info "$LIBVIRT_NETWORK" >/dev/null 2>&1 && virsh net-dumpxml "$LIBVIRT_NETWORK" | grep -q "mac='${mac}'"; then
    virsh net-update "$LIBVIRT_NETWORK" delete ip-dhcp-host \
      "<host mac='${mac}' name='${name}' ip='${ip}'/>" \
      --live --config 2>/dev/null || true
  fi

  echo "    SSH known_hosts Einträge entfernen"
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  ssh-keygen -R "$name" >/dev/null 2>&1 || true
done

if [ -f "$HOME/.ssh/config" ] && grep -qF "BEGIN k3s-cluster" "$HOME/.ssh/config"; then
  echo "==> SSH config Block entfernen"

  awk '
    /# === BEGIN k3s-cluster/ {skip=1}
    skip != 1 {print}
    /# === END k3s-cluster ===/ {skip=0; next}
  ' "$HOME/.ssh/config" > "$HOME/.ssh/config.tmp"

  mv "$HOME/.ssh/config.tmp" "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"
fi

if [ "$REMOVE_BASE_IMAGE" = "1" ] && [ -f "$CLOUD_IMG_BASE" ]; then
  echo "==> Cloud Image Base entfernen: $CLOUD_IMG_BASE"
  sudo rm -f "$CLOUD_IMG_BASE"
else
  if [ -f "$CLOUD_IMG_BASE" ]; then
    echo "==> Cloud Image Base bleibt erhalten. Zum Löschen REMOVE_BASE_IMAGE=1 setzen."
  fi
fi

echo "==> Cleanup fertig."
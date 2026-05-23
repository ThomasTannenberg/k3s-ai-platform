#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 99-cleanup.sh
# Reißt das komplette Cluster ab (für saubere Re-Runs).
# Löscht VMs, deren Disks, Seed-ISOs, DHCP-Reservations und cloud-init-Dateien.
# ---------------------------------------------------------------------------
set -euo pipefail

# REMOVE_BASE_IMAGE=1 löscht zusätzlich das heruntergeladene Cloud-Image-Base
# unter /var/lib/libvirt/boot. Default 0 = behalten (schnellere Re-Runs).
REMOVE_BASE_IMAGE="${REMOVE_BASE_IMAGE:-0}"
CLOUD_IMG_BASE="/var/lib/libvirt/boot/jammy-server-cloudimg-amd64.img"

VMS=(
  "k3s-lb-1|52:54:00:00:00:10|192.168.122.10"
  "k3s-server-1|52:54:00:00:00:11|192.168.122.11"
  "k3s-agent-gpu-1|52:54:00:00:00:21|192.168.122.21"
  "k3s-agent-tools-1|52:54:00:00:00:22|192.168.122.22"
)

read -rp "WARNUNG: Alle Cluster-VMs werden zerstört. 'yes' zum Bestätigen: " confirm
[ "$confirm" = "yes" ] || { echo "Abgebrochen."; exit 0; }

for vm_def in "${VMS[@]}"; do
  IFS='|' read -r name mac ip <<< "$vm_def"

  if virsh list --all --name | grep -qw "$name"; then
    echo "==> $name herunterfahren / zerstören..."
    virsh destroy "$name"  2>/dev/null || true
    virsh undefine "$name" --remove-all-storage --nvram 2>/dev/null \
      || virsh undefine "$name" --remove-all-storage 2>/dev/null \
      || true
  fi

  sudo rm -f "/var/lib/libvirt/boot/${name}-seed.iso"
  rm -rf "$HOME/Development/cloud-init/$name"

  # DHCP-Reservation entfernen (best effort)
  if virsh net-dumpxml default | grep -q "mac='${mac}'"; then
    virsh net-update default delete ip-dhcp-host \
      "<host mac='${mac}' name='${name}' ip='${ip}'/>" \
      --live --config 2>/dev/null || true
  fi

  # SSH-Known-Hosts-Eintrag entfernen
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  ssh-keygen -R "$name" >/dev/null 2>&1 || true
done

# ssh/config-Block entfernen
if [ -f "$HOME/.ssh/config" ] && grep -qF "BEGIN k3s-cluster" "$HOME/.ssh/config"; then
  awk '
    /# === BEGIN k3s-cluster/ {skip=1}
    skip != 1 {print}
    /# === END k3s-cluster ===/ {skip=0; next}
  ' "$HOME/.ssh/config" > "$HOME/.ssh/config.tmp" && mv "$HOME/.ssh/config.tmp" "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"
fi

# Cloud-Image-Base optional entfernen
if [ "$REMOVE_BASE_IMAGE" = "1" ] && [ -f "$CLOUD_IMG_BASE" ]; then
  echo "==> Cloud-Image-Base entfernen: $CLOUD_IMG_BASE"
  sudo rm -f "$CLOUD_IMG_BASE"
else
  if [ -f "$CLOUD_IMG_BASE" ]; then
    echo "==> Cloud-Image-Base bleibt erhalten (REMOVE_BASE_IMAGE=1 zum Löschen)."
  fi
fi

echo "==> Cleanup fertig."

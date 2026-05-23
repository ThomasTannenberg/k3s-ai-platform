#!/usr/bin/env bash

# 01-deploy-cluster-cloudimg.sh
# Ubuntu Cloud-Image + cloud-init, kein Installer.
# 1-2 min pro VM


set -euo pipefail

#  Konfiguration

SSH_USER="${SSH_USER:-k3sadmin}"
CLOUD_IMG_NAME="jammy-server-cloudimg-amd64.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/${CLOUD_IMG_NAME}"
CLOUD_IMG_LOCAL="$HOME/Downloads/${CLOUD_IMG_NAME}"
CLOUD_IMG_BASE="/var/lib/libvirt/boot/${CLOUD_IMG_NAME}"
SSH_KEY_PUB="${SSH_KEY_PUB:-$HOME/.ssh/id_ed25519.pub}"
SSH_KEY_PRIV="${SSH_KEY_PRIV:-$HOME/.ssh/id_ed25519}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLOUD_INIT_BASE="${CLOUD_INIT_BASE:-$REPO_ROOT/tmp/cloud-init}"

# Wenn STANDALONE_DISKS=1, werden Disks per cp + resize erzeugt statt Klon. 
# Langsamer aber Disks sind unabhängig vom Cloud-Image
STANDALONE_DISKS="${STANDALONE_DISKS:-0}"

VMS=(
  "k3s-lb-1|192.168.122.10|52:54:00:00:00:10|2048|1|20"
  "k3s-server-1|192.168.122.11|52:54:00:00:00:11|4096|2|60"
  "k3s-agent-gpu-1|192.168.122.21|52:54:00:00:00:21|32768|8|200"
  "k3s-agent-tools-1|192.168.122.22|52:54:00:00:00:22|4096|4|100"
)

# Hilfsfunktionen  (Hauptablauf weiter unten)

log() { echo -e "==> $*"; }
die() { echo "FEHLER: $*" >&2; exit 1; }

check_prereqs() {
  log "Voraussetzungen prüfen..."
  id -nG "$USER" | grep -qw libvirt || die "User nicht in Gruppe 'libvirt' (Bootstrap + Reboot fehlt?)."
  id -nG "$USER" | grep -qw kvm     || die "User nicht in Gruppe 'kvm'."
  command -v virt-install  >/dev/null || die "virt-install fehlt."
  command -v cloud-localds >/dev/null || die "cloud-localds fehlt (Paket cloud-image-utils)."
  command -v qemu-img      >/dev/null || die "qemu-img fehlt."
  command -v virsh         >/dev/null || die "virsh fehlt."
  [ -f "$SSH_KEY_PUB"  ] || die "SSH-Public-Key fehlt: $SSH_KEY_PUB"
  [ -f "$SSH_KEY_PRIV" ] || die "SSH-Private-Key fehlt: $SSH_KEY_PRIV"
  virsh -c qemu:///system list >/dev/null 2>&1 || die "Kein libvirt-Zugriff."

  if [ -z "${PASSWORD_HASH:-}" ]; then
    log "Admin Passwort nicht gesetzt — interaktiv erzeugen (zweimal eingeben):"
    PASSWORD_HASH="$(openssl passwd -6)"
    export PASSWORD_HASH
  fi
}

ensure_cloud_image() {
  log "Cloud-Image bereitstellen..."

  # Reste von früheren Fehlversuchen aufräumen. Was notwendig am Anfang, kann eigentlich raus. Aber schadet auch nicht.
  if [ -f "$CLOUD_IMG_LOCAL" ] && [ ! -s "$CLOUD_IMG_LOCAL" ]; then
    log "    Verwerfe leere/abgebrochene Datei: $CLOUD_IMG_LOCAL"
    rm -f "$CLOUD_IMG_LOCAL"
  fi

  if [ ! -f "$CLOUD_IMG_LOCAL" ]; then
    log "    Lade $CLOUD_IMG_URL ..."
    # Download nach .tmp, erst bei Erfolg umbenennen
    if ! wget --show-progress --tries=3 -O "${CLOUD_IMG_LOCAL}.tmp" "$CLOUD_IMG_URL"; then
      rm -f "${CLOUD_IMG_LOCAL}.tmp"
      die "Download fehlgeschlagen. Bitte URL prüfen: $CLOUD_IMG_URL"
    fi
    mv "${CLOUD_IMG_LOCAL}.tmp" "$CLOUD_IMG_LOCAL"
  else
    log "    Cloud-Image bereits lokal vorhanden."
  fi

  if [ ! -f "$CLOUD_IMG_BASE" ]; then
    log "    Kopiere Cloud-Image nach /var/lib/libvirt/boot/ ..."
    sudo mkdir -p /var/lib/libvirt/boot
    sudo cp "$CLOUD_IMG_LOCAL" "$CLOUD_IMG_BASE"
    sudo chmod 644 "$CLOUD_IMG_BASE"
  fi
}

vm_exists() {
  virsh list --all --name | grep -qw "$1"
}

create_disk() {
  # Erzeugt /var/lib/libvirt/images/<name>.qcow2 in Ziel-Größe.
  # Standard: qcow2 mit Cloud-Image als Backing-File (sehr schnell).
  # STANDALONE_DISKS=1: copy + resize (Disk unabhängig vom Base-Image).
  local vm_name="$1"
  local disk_gb="$2"
  local disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"

  # Disk von früherem abgebrochenem Lauf entfernen.
  # Sicher, weil create_vm vorher prüft, dass keine VM dieses Namens existiert.
  if [ -f "$disk_path" ]; then
    sudo rm -f "$disk_path"
  fi

  if [ "$STANDALONE_DISKS" = "1" ]; then
    sudo cp "$CLOUD_IMG_BASE" "$disk_path"
  else
    sudo qemu-img create -q -F qcow2 -b "$CLOUD_IMG_BASE" \
      -f qcow2 "$disk_path" >/dev/null
  fi
  sudo qemu-img resize -q "$disk_path" "${disk_gb}G"
  # Ownership setzen auf libvirt-qemu:libvirt-qemu, damit virt-install auch ohne sudo Zugriff auf die Disk hat.
  # || true: schlägt nicht fehl, falls die Gruppe libvirt-qemu nicht existiert. 
  sudo chown libvirt-qemu:libvirt-qemu "$disk_path" 2>/dev/null || true
  sudo chmod 644 "$disk_path"
  echo "$disk_path"
}

create_seed_iso() {
  local vm_name="$1"
  local cloud_init_dir="$CLOUD_INIT_BASE/$vm_name"
  local seed_local="$cloud_init_dir/seed.iso"
  local seed_libvirt="/var/lib/libvirt/boot/${vm_name}-seed.iso"

  mkdir -p "$cloud_init_dir"
  local ssh_key
  ssh_key="$(cat "$SSH_KEY_PUB")"

  # KEIN autoinstall: Cloud-Image hat schon Ubuntu installiert
  # cloud-init liest #cloud-config direkt.
  cat > "$cloud_init_dir/user-data" <<EOF
#cloud-config
hostname: ${vm_name}
preserve_hostname: false
manage_etc_hosts: true
timezone: Europe/Berlin

users:
  - name: ${SSH_USER}
    passwd: "${PASSWORD_HASH}"
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: [sudo, adm]
    ssh_authorized_keys:
      - ${ssh_key}

ssh_pwauth: false
disable_root: true

package_update: true
package_upgrade: false
packages:
  - qemu-guest-agent
  - curl
  - ca-certificates
  - vim
  - net-tools

growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false

runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl restart ssh
EOF

  cat > "$cloud_init_dir/meta-data" <<EOF
instance-id: ${vm_name}
local-hostname: ${vm_name}
EOF

  cloud-localds "$seed_local" "$cloud_init_dir/user-data" "$cloud_init_dir/meta-data"
  sudo cp "$seed_local" "$seed_libvirt"
  sudo chmod 644 "$seed_libvirt"

  echo "$seed_libvirt"
}

set_dhcp_reservation() {
  local mac="$1" name="$2" ip="$3"
  if virsh net-dumpxml default | grep -q "mac='${mac}'"; then
    log "    DHCP-Reservation für $name existiert bereits."
    return 0
  fi
  virsh net-update default add-last ip-dhcp-host \
    "<host mac='${mac}' name='${name}' ip='${ip}'/>" \
    --live --config
}

wait_for_ssh() {
  local ip="$1"
  local max_attempts=72   # 72 × 5s = 6 Minuten Timeout 
  echo -n "    SSH-Polling: "
  for ((i=0; i<max_attempts; i++)); do
    if ssh -o ConnectTimeout=3 \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o BatchMode=yes \
           -i "$SSH_KEY_PRIV" \
           "${SSH_USER}@${ip}" "true" 2>/dev/null; then
      echo " OK"
      return 0
    fi
    echo -n "."
    sleep 5
  done
  echo ""
  die "SSH zu $ip war nach $((max_attempts * 5))s nicht erreichbar."
}

create_vm() {
  local vm_def="$1"
  IFS='|' read -r name ip mac memory vcpus disk_gb <<< "$vm_def"

  echo ""
  echo "------------------------------------------------------------"
  log "VM $name (IP=$ip, MAC=$mac, RAM=${memory}MB, vCPU=$vcpus, Disk=${disk_gb}GB)"
  echo "------------------------------------------------------------"

  if vm_exists "$name"; then
    log "    existiert bereits, überspringe."
    return 0
  fi

  log "    Disk aus Cloud-Image erzeugen..."
  local disk_path
  disk_path="$(create_disk "$name" "$disk_gb")"

  log "    cloud-init seed.iso bauen..."
  local seed_libvirt
  seed_libvirt="$(create_seed_iso "$name")"

  log "    DHCP-Reservation setzen..."
  set_dhcp_reservation "$mac" "$name" "$ip"

  log "    virt-install --import (Direktboot vom Cloud-Image)..."
  virt-install \
    --name "$name" \
    --memory "$memory" \
    --vcpus "$vcpus" \
    --disk path="$disk_path",bus=virtio,format=qcow2 \
    --disk path="$seed_libvirt",device=cdrom \
    --os-variant ubuntu22.04 \
    --network network=default,model=virtio,mac="$mac" \
    --graphics none \
    --noautoconsole \
    --import \
    >/dev/null

  wait_for_ssh "$ip"
  log "    $name ist bereit."
}

update_ssh_config() {
  local ssh_config="$HOME/.ssh/config"
  local marker_start="# === BEGIN k3s-cluster (managed by deploy-cluster.sh) ==="
  local marker_end="# === END k3s-cluster ==="

  log "~/.ssh/config aktualisieren..."
  touch "$ssh_config"
  chmod 600 "$ssh_config"

  if grep -qF "$marker_start" "$ssh_config"; then
    awk -v s="$marker_start" -v e="$marker_end" '
      $0 ~ s {skip=1}
      skip != 1 {print}
      $0 ~ e {skip=0; next}
    ' "$ssh_config" > "${ssh_config}.tmp" && mv "${ssh_config}.tmp" "$ssh_config"
  fi

  {
    echo ""
    echo "$marker_start"
    for vm_def in "${VMS[@]}"; do
      IFS='|' read -r name ip _ _ _ _ <<< "$vm_def"
      cat <<EOF
Host $name
    HostName $ip
    User $SSH_USER
    IdentityFile $SSH_KEY_PRIV


EOF
    done
    echo "$marker_end"
  } >> "$ssh_config"
}

test_all_vms() {
  echo ""
  log "SSH-Test zu allen VMs..."
  local ok=0 fail=0

  for vm_def in "${VMS[@]}"; do
    IFS='|' read -r name ip _ _ _ _ <<< "$vm_def"

    if ssh \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -i "$SSH_KEY_PRIV" \
      "${SSH_USER}@${ip}" \
      hostname >/dev/null 2>&1; then

      echo "    [OK]   ${SSH_USER}@${name} (${ip})"
      ok=$((ok + 1))
    else
      echo "    [FAIL] ${SSH_USER}@${name} (${ip})"
      fail=$((fail + 1))
    fi
  done

  echo ""
  log "Ergebnis: $ok OK / $fail FEHLER"
}

# Hauptablauf

main() {
  check_prereqs
  ensure_cloud_image

  local t_start
  t_start="$(date +%s)"

  for vm_def in "${VMS[@]}"; do
    create_vm "$vm_def"
  done

  update_ssh_config
  test_all_vms

  local t_end elapsed
  t_end="$(date +%s)"
  elapsed=$((t_end - t_start))

  echo ""
  echo "============================================================"
  echo "  Fertig in ${elapsed}s. Login z. B.:"
  echo "      ssh k3sadmin@k3s-lb-1"
  echo "      ssh k3sadmin@k3s-server-1"
  echo "      ssh k3sadmin@k3s-agent-1"
  echo "============================================================"
}

main "$@"
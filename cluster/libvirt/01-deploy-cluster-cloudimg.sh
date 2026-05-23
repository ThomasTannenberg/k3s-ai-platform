#!/usr/bin/env bash

# 01-deploy-cluster-cloudimg.sh
# Ubuntu Cloud Image + cloud-init, kein Installer.
# Erstellt die VMs für das lokale k3s AI Cluster.

set -euo pipefail

SSH_USER="${SSH_USER:-k3sadmin}"

CLOUD_IMG_NAME="jammy-server-cloudimg-amd64.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/${CLOUD_IMG_NAME}"
CLOUD_IMG_LOCAL="$HOME/Downloads/${CLOUD_IMG_NAME}"
CLOUD_IMG_BASE="/var/lib/libvirt/boot/${CLOUD_IMG_NAME}"

SSH_KEY_PUB="${SSH_KEY_PUB:-$HOME/.ssh/id_ed25519.pub}"
SSH_KEY_PRIV="${SSH_KEY_PRIV:-$HOME/.ssh/id_ed25519}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLOUD_INIT_BASE="${CLOUD_INIT_BASE:-$REPO_ROOT/tmp/cloud-init}"

STANDALONE_DISKS="${STANDALONE_DISKS:-0}"

NETWORK_MODE="${NETWORK_MODE:-bridge}"
LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"
LIBVIRT_BRIDGE="${LIBVIRT_BRIDGE:-br0}"

LAN_PREFIX="${LAN_PREFIX:-24}"
LAN_GATEWAY="${LAN_GATEWAY:-192.168.178.1}"
LAN_DNS="${LAN_DNS:-192.168.178.1,1.1.1.1}"

VMS=(
  "k3s-lb-1|192.168.178.50|52:54:00:00:00:10|2048|1|20"
  "k3s-server-1|192.168.178.51|52:54:00:00:00:11|4096|4|60"
  "k3s-agent-gpu-1|192.168.178.61|52:54:00:00:00:21|32768|8|200"
  "k3s-agent-tools-1|192.168.178.62|52:54:00:00:00:22|4096|4|100"
)

log() {
  echo -e "==> $*"
}

die() {
  echo "FEHLER: $*" >&2
  exit 1
}

check_prereqs() {
  log "Voraussetzungen prüfen..."

  id -nG "$USER" | grep -qw libvirt || die "User nicht in Gruppe 'libvirt' (Bootstrap + Reboot fehlt?)."
  id -nG "$USER" | grep -qw kvm || die "User nicht in Gruppe 'kvm'."

  command -v virt-install >/dev/null || die "virt-install fehlt."
  command -v cloud-localds >/dev/null || die "cloud-localds fehlt (Paket cloud-image-utils)."
  command -v qemu-img >/dev/null || die "qemu-img fehlt."
  command -v virsh >/dev/null || die "virsh fehlt."
  command -v openssl >/dev/null || die "openssl fehlt."
  command -v wget >/dev/null || die "wget fehlt."

  [ -f "$SSH_KEY_PUB" ] || die "SSH Public Key fehlt: $SSH_KEY_PUB"
  [ -f "$SSH_KEY_PRIV" ] || die "SSH Private Key fehlt: $SSH_KEY_PRIV"

  virsh -c qemu:///system list >/dev/null 2>&1 || die "Kein libvirt Zugriff."

  if [ "$NETWORK_MODE" = "bridge" ]; then
    ip link show "$LIBVIRT_BRIDGE" >/dev/null 2>&1 || die "Bridge nicht gefunden: $LIBVIRT_BRIDGE. Bitte zuerst 02-create-host-bridge.sh ausführen."
  else
    virsh net-info "$LIBVIRT_NETWORK" >/dev/null 2>&1 || die "Libvirt Netzwerk nicht gefunden: $LIBVIRT_NETWORK"
  fi

  if [ -z "${PASSWORD_HASH:-}" ]; then
    log "Admin Passwort nicht gesetzt. Interaktiv Passwort Hash erzeugen:"
    PASSWORD_HASH="$(openssl passwd -6)"
    export PASSWORD_HASH
  fi
}

ensure_cloud_image() {
  log "Cloud Image bereitstellen..."

  if [ -f "$CLOUD_IMG_LOCAL" ] && [ ! -s "$CLOUD_IMG_LOCAL" ]; then
    log "    Verwerfe leere oder abgebrochene Datei: $CLOUD_IMG_LOCAL"
    rm -f "$CLOUD_IMG_LOCAL"
  fi

  if [ ! -f "$CLOUD_IMG_LOCAL" ]; then
    log "    Lade $CLOUD_IMG_URL"
    if ! wget --show-progress --tries=3 -O "${CLOUD_IMG_LOCAL}.tmp" "$CLOUD_IMG_URL"; then
      rm -f "${CLOUD_IMG_LOCAL}.tmp"
      die "Download fehlgeschlagen. Bitte URL prüfen: $CLOUD_IMG_URL"
    fi
    mv "${CLOUD_IMG_LOCAL}.tmp" "$CLOUD_IMG_LOCAL"
  else
    log "    Cloud Image bereits lokal vorhanden."
  fi

  if [ ! -f "$CLOUD_IMG_BASE" ]; then
    log "    Kopiere Cloud Image nach /var/lib/libvirt/boot/"
    sudo mkdir -p /var/lib/libvirt/boot
    sudo cp "$CLOUD_IMG_LOCAL" "$CLOUD_IMG_BASE"
    sudo chmod 644 "$CLOUD_IMG_BASE"
  fi
}

vm_exists() {
  virsh list --all --name | grep -qw "$1"
}

create_disk() {
  local vm_name="$1"
  local disk_gb="$2"
  local disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"

  if [ -f "$disk_path" ]; then
    sudo rm -f "$disk_path"
  fi

  if [ "$STANDALONE_DISKS" = "1" ]; then
    sudo cp "$CLOUD_IMG_BASE" "$disk_path"
  else
    sudo qemu-img create -q -F qcow2 -b "$CLOUD_IMG_BASE" -f qcow2 "$disk_path" >/dev/null
  fi

  sudo qemu-img resize -q "$disk_path" "${disk_gb}G"
  sudo chown libvirt-qemu:libvirt-qemu "$disk_path" 2>/dev/null || true
  sudo chmod 644 "$disk_path"

  echo "$disk_path"
}

create_seed_iso() {
  local vm_name="$1"
  local vm_ip="$2"
  local vm_mac="$3"

  local cloud_init_dir="$CLOUD_INIT_BASE/$vm_name"
  local seed_local="$cloud_init_dir/seed.iso"
  local seed_libvirt="/var/lib/libvirt/boot/${vm_name}-seed.iso"

  mkdir -p "$cloud_init_dir"

  local ssh_key
  ssh_key="$(cat "$SSH_KEY_PUB")"

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

  cat > "$cloud_init_dir/network-config" <<EOF
version: 2
ethernets:
  lan0:
    match:
      macaddress: "${vm_mac}"
    set-name: enp1s0
    dhcp4: false
    dhcp6: false
    addresses:
      - ${vm_ip}/${LAN_PREFIX}
    routes:
      - to: default
        via: ${LAN_GATEWAY}
    nameservers:
      addresses: [${LAN_DNS}]
EOF

  cloud-localds "$seed_local" "$cloud_init_dir/user-data" "$cloud_init_dir/meta-data" "$cloud_init_dir/network-config"

  sudo cp "$seed_local" "$seed_libvirt"
  sudo chmod 644 "$seed_libvirt"

  echo "$seed_libvirt"
}

set_dhcp_reservation() {
  local mac="$1"
  local name="$2"
  local ip="$3"

  if virsh net-dumpxml "$LIBVIRT_NETWORK" | grep -q "mac='${mac}'"; then
    log "    DHCP Reservation für $name existiert bereits."
    return 0
  fi

  virsh net-update "$LIBVIRT_NETWORK" add-last ip-dhcp-host \
    "<host mac='${mac}' name='${name}' ip='${ip}'/>" \
    --live --config
}

wait_for_ssh() {
  local ip="$1"
  local max_attempts=72

  echo -n "    SSH Polling: "

  for ((i = 0; i < max_attempts; i++)); do
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
  die "SSH zu $ip war nach $((max_attempts * 5)) Sekunden nicht erreichbar."
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

  log "    Disk aus Cloud Image erzeugen"
  local disk_path
  disk_path="$(create_disk "$name" "$disk_gb")"

  log "    cloud-init seed.iso bauen"
  local seed_libvirt
  seed_libvirt="$(create_seed_iso "$name" "$ip" "$mac")"

  if [ "$NETWORK_MODE" != "bridge" ]; then
    log "    DHCP Reservation setzen"
    set_dhcp_reservation "$mac" "$name" "$ip"
  else
    log "    Bridge Modus aktiv, keine libvirt DHCP Reservation notwendig."
  fi

  local network_arg

  if [ "$NETWORK_MODE" = "bridge" ]; then
    network_arg="bridge=${LIBVIRT_BRIDGE},model=virtio,mac=${mac}"
  else
    network_arg="network=${LIBVIRT_NETWORK},model=virtio,mac=${mac}"
  fi

  log "    virt-install --import"
  virt-install \
    --name "$name" \
    --memory "$memory" \
    --vcpus "$vcpus" \
    --disk path="$disk_path",bus=virtio,format=qcow2 \
    --disk path="$seed_libvirt",device=cdrom \
    --os-variant ubuntu22.04 \
    --network "$network_arg" \
    --graphics none \
    --noautoconsole \
    --import \
    >/dev/null

  wait_for_ssh "$ip"
  log "    $name ist bereit."
}

update_ssh_config() {
  local ssh_config="$HOME/.ssh/config"
  local marker_start="# === BEGIN k3s-cluster (managed by 01-deploy-cluster-cloudimg.sh) ==="
  local marker_end="# === END k3s-cluster ==="

  log "~/.ssh/config aktualisieren"
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
  log "SSH Test zu allen VMs"
  local ok=0
  local fail=0

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

  local t_end
  local elapsed
  t_end="$(date +%s)"
  elapsed=$((t_end - t_start))

  echo ""
  echo "============================================================"
  echo "  Fertig in ${elapsed}s. Login z. B.:"
  echo "      ssh k3sadmin@k3s-lb-1"
  echo "      ssh k3sadmin@k3s-server-1"
  echo "      ssh k3sadmin@k3s-agent-gpu-1"
  echo "      ssh k3sadmin@k3s-agent-tools-1"
  echo "============================================================"
}

main "$@"
#!/usr/bin/env bash

# 00-bootstrap.sh
# Installiert KVM/libvirt-Pakete und legt Gruppen Mitgliedschaften an.

set -euo pipefail

PACKAGES=(
  qemu-system-x86
  libvirt-daemon-system
  libvirt-daemon-driver-qemu
  libvirt-clients
  virtinst
  virt-manager
  bridge-utils
  cloud-image-utils
  cpu-checker
  whois
  wget
  openssh-client
  openssl
)

echo "==> Virtualisierungs-Support prüfen"
if ! grep -E -q '(vmx|svm)' /proc/cpuinfo; then
  echo "FEHLER: CPU unterstützt keine Virtualisierung oder es ist deaktiviert. Abbruch."
  exit 1
fi

echo "==> Pakete installieren"
sudo apt update
sudo apt install -y "${PACKAGES[@]}"

echo "==> Benutzer $USER zu Gruppen libvirt und kvm hinzufügen"
sudo usermod -aG libvirt "$USER"
sudo usermod -aG kvm "$USER"

echo "==> libvirtd aktivieren"
sudo systemctl enable --now libvirtd

echo "==> Default-Netzwerk starten und autostart setzen"
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default 2>/dev/null || true

echo "==> Arbeitsverzeichnisse anlegen. Für Downloads eigentlich unnötig, aber lieber safe"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$REPO_ROOT/tmp/cloud-init"
mkdir -p "$HOME/Downloads"

echo "==> SSH-Key prüfen"
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  echo "    Kein SSH-Key gefunden, erzeuge neuen ed25519-Key"
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "$USER@$(hostname)"
else
  echo "    SSH-Key bereits vorhanden: $HOME/.ssh/id_ed25519"
fi

echo ""
echo "<============================================================>"
echo "  Bootstrap abgeschlossen."
echo ""
echo "  JETZT mit der VM-Erstellung beginnen"
echo "<============================================================>"


# k3s AI Platform

Lokale Kubernetes Plattform auf Basis von KVM, libvirt, Ubuntu Cloud Images und K3s.

Das Projekt stellt eine lokale VM Umgebung bereit, auf der ein kleines K3s Cluster für spätere AI und GPU Workloads aufgebaut wird. Die Umgebung besteht aus einem LoadBalancer, einem K3s Server Node, einem GPU Worker Node und einem Tools Worker Node.

## Ziel

Ziel des Projekts ist eine lokale Kubernetes Plattform für AI Workloads.

Die Plattform soll später folgende Aufgaben unterstützen:

- Lokales Kubernetes Cluster mit K3s
- Getrennte Worker Nodes für AI und Tools
- Vorbereitung für NVIDIA GPU Workloads
- LoadBalancer für Kubernetes API und spätere Ingress Weiterleitung
- Automatisierter Aufbau über Bash, libvirt und Ansible
- Reproduzierbare lokale Testumgebung

## Architektur

Die Umgebung besteht aktuell aus vier virtuellen Maschinen.

| VM | IP | Rolle | RAM | vCPU | Disk |
|---|---:|---|---:|---:|---:|
| k3s-lb-1 | 192.168.122.10 | HAProxy LoadBalancer | 2048 MB | 1 | 20 GB |
| k3s-server-1 | 192.168.122.11 | K3s Server, Control Plane, etcd | 4096 MB | 4 | 60 GB |
| k3s-agent-gpu-1 | 192.168.122.21 | Worker Node für AI und GPU Workloads | 32768 MB | 8 | 200 GB |
| k3s-agent-tools-1 | 192.168.122.22 | Worker Node für Tools und Plattformdienste | 4096 MB | 4 | 100 GB |

## Node Labels

Nach der Installation werden die Worker Nodes automatisch gelabelt.

Der GPU Node erhält:

```text
node-role.kubernetes.io/worker=true
workload-type=ai
accelerator=nvidia
```

Der Tools Node erhält:

```text
node-role.kubernetes.io/worker=true
workload-type=tools
```

Die Labels können geprüft werden mit:

```bash
kubectl get nodes --show-labels
```

Oder übersichtlicher:

```bash
kubectl get nodes -L workload-type -L accelerator
```

Beispiel für spätere AI Workloads:

```yaml
nodeSelector:
  workload-type: ai
  accelerator: nvidia
```

Beispiel für Tools Workloads:

```yaml
nodeSelector:
  workload-type: tools
```

## Wichtiger Hinweis zur GPU

Der Node `k3s-agent-gpu-1` ist aktuell als GPU Node vorbereitet und entsprechend gelabelt.

Das Label `accelerator=nvidia` bedeutet nur, dass der Node logisch als NVIDIA GPU Node markiert ist. Damit Kubernetes echte GPU Ressourcen verwenden kann, sind weitere Schritte nötig.

Dazu gehören später:

- GPU Passthrough der NVIDIA GPU in die VM
- NVIDIA Treiber innerhalb der GPU VM
- NVIDIA Container Toolkit
- NVIDIA Device Plugin oder NVIDIA GPU Operator im Cluster

Solange diese Schritte nicht umgesetzt sind, zeigt Kubernetes keine echte Ressource wie `nvidia.com/gpu` an.

## Projektstruktur

```text
.
├── Makefile
├── cluster
│   ├── ansible
│   │   ├── ansible.cfg
│   │   ├── group_vars
│   │   │   └── all.yml
│   │   ├── inventory.ini
│   │   ├── site.yml
│   │   ├── templates
│   │   │   └── haproxy.cfg.j2
│   │   └── uninstall.yml
│   └── libvirt
│       ├── 00-bootstrap.sh
│       ├── 01-deploy-cluster-cloudimg.sh
│       └── 99-cleanup.sh
└── tmp
    └── cloud-init
```

## Voraussetzungen

Das Projekt ist für ein lokales Ubuntu Hostsystem gedacht.

Benötigt werden:

- Ubuntu Hostsystem
- CPU Virtualisierung aktiviert
- KVM und libvirt
- SSH Key für den Zugriff auf die VMs
- Ansible
- kubectl
- helm

Die VM Erstellung nutzt Ubuntu Cloud Images und cloud init. Es wird kein klassischer Ubuntu Installer gestartet.

## Git Ignore

Lokale Secrets und temporäre Dateien sollen nicht ins Repository.

Empfohlene `.gitignore` Einträge:

```gitignore
# Lokale Secrets
.local-secrets
.local-secrets/

# Temporäre Dateien
tmp/

# Lokale Cluster Dateien
cluster/ansible/k3s.yaml
cluster/ansible/.k3s-bootstrap-token
```

## Installation

### 1. Host vorbereiten und VMs erstellen

```bash
make vm-create
```

Das Ziel führt zuerst das Bootstrap Skript aus und erstellt anschließend die VMs.

Das Bootstrap Skript installiert die benötigten Pakete für KVM und libvirt, aktiviert libvirtd, startet das default Netzwerk und erzeugt bei Bedarf einen SSH Key.

Nach dem ersten Bootstrap kann ein Logout oder Reboot notwendig sein, damit die Gruppenmitgliedschaften für `libvirt` und `kvm` aktiv werden.

Falls die VM Erstellung danach wegen fehlender Gruppenrechte fehlschlägt, einmal neu anmelden oder rebooten und danach erneut ausführen:

```bash
make vm-create
```

### 2. SSH Zugriff prüfen

```bash
make vm-test
```

Alternativ direkt:

```bash
ssh k3sadmin@k3s-lb-1
ssh k3sadmin@k3s-server-1
ssh k3sadmin@k3s-agent-gpu-1
ssh k3sadmin@k3s-agent-tools-1
```

### 3. K3s Cluster erstellen

```bash
make cluster-create
```

Das Ansible Playbook führt folgende Schritte aus:

- HAProxy auf `k3s-lb-1` installieren
- HAProxy für die Kubernetes API konfigurieren
- `k3s-server-1` als ersten K3s Server Node initialisieren
- K3s Agent Nodes joinen
- Worker Labels setzen
- GPU und Tools Labels setzen
- lokale Kubeconfig erzeugen

Die Kubeconfig wird hier abgelegt:

```text
cluster/ansible/k3s.yaml
```

### 4. Kubeconfig verwenden

```bash
export KUBECONFIG=cluster/ansible/k3s.yaml
```

Prüfen:

```bash
kubectl get nodes -o wide
kubectl get nodes -L workload-type -L accelerator
kubectl get pods -A
```

## Validierung

Die Umgebung kann mit folgendem Ziel geprüft werden:

```bash
make validate
```

Dabei werden unter anderem geprüft:

- Nodes
- Node Labels
- Pods
- Helm Releases
- StorageClasses
- PVCs
- PVs
- Services
- Ingress Ressourcen

## Nützliche Befehle

VMs anzeigen:

```bash
make vm-list
```

VMs starten:

```bash
make vm-start
```

VMs herunterfahren:

```bash
make vm-shutdown
```

Cluster per Ansible entfernen:

```bash
make cluster-delete
```

VMs löschen:

```bash
make vm-delete
```

Alles bereinigen:

```bash
make cleanup
```

## Makefile Ziele

| Ziel | Beschreibung |
|---|---|
| make vm-create | Host vorbereiten und VMs erstellen |
| make vm-delete | VMs und lokale VM Dateien löschen |
| make vm-list | libvirt VMs anzeigen |
| make vm-start | VMs starten |
| make vm-shutdown | VMs herunterfahren |
| make vm-test | SSH Verbindung zu den VMs prüfen |
| make cluster-create | K3s Cluster per Ansible erstellen |
| make cluster-delete | K3s Cluster per Ansible entfernen |
| make install | VMs erstellen und Cluster erstellen |
| make validate | Cluster Status prüfen |
| make cleanup | Cluster und VMs löschen |

## HAProxy

HAProxy läuft auf:

```text
k3s-lb-1
192.168.122.10
```

Aktuell wird darüber die Kubernetes API bereitgestellt:

```text
192.168.122.10:6443
```

Die HAProxy Konfiguration wird aus folgendem Template erzeugt:

```text
cluster/ansible/templates/haproxy.cfg.j2
```

Später kann HAProxy zusätzlich für HTTP und HTTPS Ingress Traffic genutzt werden. Die vorbereiteten Ports in `group_vars/all.yml` sind:

```yaml
traefik_http_port: 30080
traefik_https_port: 30443
```

Diese Werte müssen zur späteren Traefik Installation passen.

## K3s Konfiguration

Das eingebaute K3s Traefik wird deaktiviert:

```yaml
disable_traefik: true
```

Dadurch kann Traefik später kontrolliert per Helm installiert werden.

Server Nodes werden getaintet:

```yaml
taint_servers: true
```

Dadurch laufen normale Workloads nicht automatisch auf dem Control Plane Node.

## Aktueller Cluster Zustand

Ein erfolgreicher Cluster Aufbau sieht zum Beispiel so aus:

```text
NAME                STATUS   ROLES                INTERNAL-IP
k3s-agent-gpu-1     Ready    worker               192.168.122.21
k3s-agent-tools-1   Ready    worker               192.168.122.22
k3s-server-1        Ready    control-plane,etcd    192.168.122.11
```

Die Labels sehen zum Beispiel so aus:

```text
k3s-agent-gpu-1     workload-type=ai      accelerator=nvidia
k3s-agent-tools-1   workload-type=tools
```

## Cleanup

Der K3s Cluster kann entfernt werden mit:

```bash
make cluster-delete
```

Die VMs können gelöscht werden mit:

```bash
make vm-delete
```

Alles zusammen:

```bash
make cleanup
```

Das Cleanup Skript entfernt:

- VMs
- VM Disks
- Seed ISOs
- DHCP Reservierungen
- SSH known hosts Einträge
- lokalen SSH config Block
- lokale cloud init Dateien

Das Ubuntu Cloud Image bleibt standardmäßig erhalten, damit spätere Re Runs schneller sind.

Zum Entfernen des Base Images:

```bash
REMOVE_BASE_IMAGE=1 make vm-delete
```

## Aktueller Stand

Aktuell umgesetzt:

- libvirt VM Erstellung
- Ubuntu Cloud Image Provisionierung
- cloud init für User, SSH und Basis Pakete
- feste DHCP Reservierungen
- SSH Config Einträge
- HAProxy Installation über Ansible
- K3s Installation über Ansible
- Worker Labeling
- GPU und Tools Node Labeling
- lokale Kubeconfig Ausgabe

Noch offen für spätere Ausbaustufen:

- GPU Passthrough in die VM
- NVIDIA Treiber in der GPU VM
- NVIDIA Container Toolkit
- NVIDIA Device Plugin oder GPU Operator
- Traefik Installation per Helm
- Keycloak für Authentifizierung
- Weboberfläche für AI Workloads
- Persistenter Storage
- Monitoring
- GitOps

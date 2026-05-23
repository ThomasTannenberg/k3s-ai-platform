# k3s AI Platform

Lokale Kubernetes Plattform für AI Workloads auf Basis von KVM, libvirt, Ubuntu Cloud Images und K3s.

Das Projekt baut ein lokales Kubernetes Cluster als virtuelle Maschinen auf einem Ubuntu Host auf. Die Plattform ist so vorbereitet, dass Dienste später über eine eigene Domain öffentlich erreichbar sind. Der externe Zugriff läuft über eine feste öffentliche IPv4 Adresse, eine FRITZ!Box, HAProxy, Traefik und cert-manager.

Öffentliche Werte wie die feste IPv4 Adresse und die Domain werden in dieser Dokumentation bewusst als Platzhalter beschrieben.

## Ziel

Ziel ist eine lokal betreibbare Kubernetes Plattform für AI und spätere GPU Workloads.

Die Plattform deckt aktuell folgende Punkte ab:

- lokale VM Umgebung mit KVM und libvirt
- K3s Cluster mit getrennten Rollen
- LoadBalancer VM als zentraler Einstiegspunkt
- HAProxy als vorgelagerter TCP LoadBalancer
- Traefik als Kubernetes Ingress Controller
- cert-manager für Let’s Encrypt Zertifikate
- öffentliche Erreichbarkeit über eigene Domain
- Vorbereitung für spätere NVIDIA GPU Workloads
- reproduzierbarer Aufbau über Bash, Ansible und Helm Wrapper Charts

## Architektur

Das Cluster besteht aus vier virtuellen Maschinen.

| VM | IP | Rolle | RAM | vCPU | Disk |
|---|---:|---|---:|---:|---:|
| k3s-lb-1 | 192.168.178.50 | HAProxy LoadBalancer | 2048 MB | 1 | 20 GB |
| k3s-server-1 | 192.168.178.51 | K3s Server, Control Plane, etcd | 4096 MB | 4 | 60 GB |
| k3s-agent-gpu-1 | 192.168.178.61 | Worker Node für AI und spätere GPU Workloads | 32768 MB | 8 | 200 GB |
| k3s-agent-tools-1 | 192.168.178.62 | Worker Node für Tools und Plattformdienste | 4096 MB | 4 | 100 GB |

## Netzwerk Zielbild

Der öffentliche Zugriff läuft über diesen Pfad:

```text
Internet
  -> feste öffentliche IPv4
  -> FRITZ!Box
  -> Portfreigabe TCP 80 und TCP 443
  -> k3s-lb-1
  -> HAProxy
  -> Traefik
  -> Kubernetes Service
  -> Pod
```

Beispiel mit Platzhaltern:

```text
https://whoami.<DOMAIN>
```

## Öffentliche Werte


Beispielhafte Verwendung:

```text
A   @     <PUBLIC_IPV4>
A   *     <PUBLIC_IPV4>
A   www   <PUBLIC_IPV4>
```

Für lokale Tests und private Konfigurationen können diese Werte in einer nicht getrackten Datei gepflegt werden, zum Beispiel:

```text
.local-secrets/network.env
```

Diese Datei darf nicht nach GitHub.

## DNS

Die Domain wird beim DNS Anbieter verwaltet.

Benötigte DNS Records:

```text
A   @     <PUBLIC_IPV4>
A   *     <PUBLIC_IPV4>
A   www   <PUBLIC_IPV4>
```

Damit zeigen die Hauptdomain, `www` und alle Subdomains auf die feste öffentliche IPv4 Adresse.

Beispiele:

```text
<DOMAIN>
www.<DOMAIN>
whoami.<DOMAIN>
ai.<DOMAIN>
keycloak.<DOMAIN>
```

Für den aktuellen Aufbau wird IPv4 verwendet.

AAAA Records sollten nur gesetzt werden, wenn auch IPv6 sauber auf den eigenen Anschluss und den eigenen Einstiegspunkt zeigt. Andernfalls können Clients über IPv6 an einem falschen Ziel landen.

DNS prüfen:

```bash
dig @8.8.8.8 <DOMAIN> A
dig @8.8.8.8 whoami.<DOMAIN> A
dig @8.8.8.8 <DOMAIN> AAAA
```

Erwartung:

```text
A Record zeigt auf <PUBLIC_IPV4>
AAAA ist leer oder bewusst korrekt gesetzt
```

## FRITZ!Box

Die FRITZ!Box leitet eingehende Anfragen aus dem Internet an die LoadBalancer VM weiter.

Pfad in der FRITZ!Box:

```text
Internet
  -> Freigaben
  -> Portfreigaben
```

Die Portfreigaben zeigen auf:

```text
k3s-lb-1
192.168.178.50
```

Benötigte Freigaben:

```text
TCP 80  -> 192.168.178.50:80
TCP 443 -> 192.168.178.50:443
```

Nicht öffentlich freigeben:

```text
TCP 6443
TCP 22
```

Port `6443` ist die Kubernetes API und sollte nicht aus dem Internet erreichbar sein.

## Ubuntu Host

Der Ubuntu Host ist der physische Rechner für die Virtualisierung.

Er stellt bereit:

```text
KVM
libvirt
virt-install
cloud-init
Ansible
kubectl
helm
```

Die VMs werden mit Ubuntu Cloud Images und cloud-init erstellt.

Wichtige Ordner:

```text
cluster/libvirt
cluster/ansible
platform/traefik
platform/cert-manager
apps/demo
docs
```

## libvirt Bridge

Die VMs laufen im FRITZ!Box LAN über eine Linux Bridge.

Die aktive Bridge heißt:

```text
br0
```

Prüfen:

```bash
ip -br addr show br0
bridge link
```

Erwartung:

```text
br0 UP 192.168.178.x/24
enp11s0 master br0
```

## Wann muss 02-create-host-bridge.sh ausgeführt werden?

Das Skript `cluster/libvirt/02-create-host-bridge.sh` wird nur benötigt, wenn der Ubuntu Host noch keine Bridge `br0` hat.

Bei einem bereits eingerichteten Host mit aktiver Bridge muss es nicht erneut ausgeführt werden.

Ausführen nur in diesen Fällen:

```text
neuer Ubuntu Host
Host wurde neu installiert
br0 wurde gelöscht
Netzwerk soll bewusst neu auf Bridge umgebaut werden
ip -br addr show br0 liefert keine Bridge
```

Nicht bei jedem Redeploy ausführen.

Der normale Redeploy Ablauf beginnt mit:

```bash
make vm-create
```

Nicht mit:

```bash
make host-bridge
```

Das `host-bridge` Target verändert die Netzwerkkonfiguration des Hosts und sollte bewusst manuell ausgeführt werden.

## Unterschied zum alten Testaufbau

Vor dem Bridge Umbau wurde temporär `socat` verwendet.

Alter Testpfad:

```text
Internet
  -> FRITZ!Box
  -> Ubuntu Host
  -> socat
  -> k3s-lb-1 im libvirt NAT Netz
  -> HAProxy
  -> Traefik
```

Dieser Aufbau war nur ein Funktionstest.

Der Zielaufbau ist jetzt:

```text
Internet
  -> FRITZ!Box
  -> k3s-lb-1 192.168.178.50
  -> HAProxy
  -> Traefik
```

`socat` wird nach dem Bridge Umbau nicht mehr benötigt.

Alte socat Prozesse können gestoppt werden:

```bash
sudo pkill -f "socat TCP-LISTEN:80" || true
sudo pkill -f "socat TCP-LISTEN:443" || true
sudo ss -tulpn | grep -E ':80|:443' || true
```

## HAProxy

HAProxy läuft auf:

```text
k3s-lb-1
192.168.178.50
```

HAProxy leitet den Traffic weiter.

Kubernetes API intern:

```text
192.168.178.50:6443
  -> k3s-server-1:6443
```

HTTP:

```text
192.168.178.50:80
  -> k3s-agent-gpu-1:30080
  -> k3s-agent-tools-1:30080
```

HTTPS:

```text
192.168.178.50:443
  -> k3s-agent-gpu-1:30443
  -> k3s-agent-tools-1:30443
```

Die HAProxy Konfiguration wird über Ansible erzeugt.

Template:

```text
cluster/ansible/templates/haproxy.cfg.j2
```

HAProxy prüfen:

```bash
ssh k3s-lb-1

sudo systemctl status haproxy --no-pager
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo ss -tulpn | grep -E ':80|:443|:6443'
```

## K3s

Das K3s Cluster wird über Ansible installiert.

Inventory:

```text
cluster/ansible/inventory.ini
```

Globale Variablen:

```text
cluster/ansible/group_vars/all.yml
```

Die Kubeconfig wird erzeugt unter:

```text
cluster/ansible/k3s.yaml
```

Diese Datei darf nicht nach GitHub.

Kubeconfig setzen:

```bash
export KUBECONFIG=$PWD/cluster/ansible/k3s.yaml
```

Oder dauerhaft nach `~/.kube/config` kopieren:

```bash
mkdir -p ~/.kube
cp cluster/ansible/k3s.yaml ~/.kube/config
chmod 600 ~/.kube/config
```

## Node Labels

Die Worker Nodes werden automatisch gelabelt.

GPU Node:

```text
node-role.kubernetes.io/worker=true
workload-type=ai
accelerator=nvidia
```

Tools Node:

```text
node-role.kubernetes.io/worker=true
workload-type=tools
```

Prüfen:

```bash
kubectl get nodes -L workload-type -L accelerator
kubectl get nodes --show-labels
```

Workloads können später gezielt geplant werden.

AI Workloads:

```yaml
nodeSelector:
  workload-type: ai
  accelerator: nvidia
```

Tools Workloads:

```yaml
nodeSelector:
  workload-type: tools
```

## Hinweis zur GPU

Der Node `k3s-agent-gpu-1` ist als GPU Node vorbereitet und gelabelt.

Das Label `accelerator=nvidia` bedeutet nur, dass der Node logisch als GPU Node markiert ist.

Für echte GPU Nutzung sind noch weitere Schritte nötig:

```text
GPU Passthrough in die VM
NVIDIA Treiber in der VM
NVIDIA Container Toolkit
NVIDIA Device Plugin oder NVIDIA GPU Operator
```

Erst danach stellt Kubernetes Ressourcen wie `nvidia.com/gpu` bereit.

## Traefik

Traefik wird über einen Wrapper Chart installiert.

Chart:

```text
platform/traefik
```

Traefik läuft auf dem Tools Node:

```text
k3s-agent-tools-1
```

Der Traefik Service ist ein NodePort Service.

Ports:

```text
HTTP   30080
HTTPS  30443
```

Installation:

```bash
helm dependency update platform/traefik

helm upgrade --install traefik platform/traefik \
  --namespace traefik \
  --create-namespace
```

Prüfen:

```bash
kubectl get pods -n traefik -o wide
kubectl get svc -n traefik
kubectl get ingressclass
```

Erwartung:

```text
Traefik Pod läuft auf k3s-agent-tools-1
Service Type ist NodePort
Ports sind 80:30080 und 443:30443
```

## cert-manager

cert-manager wird für TLS Zertifikate verwendet.

Chart:

```text
platform/cert-manager
```

Installation:

```bash
helm dependency update platform/cert-manager

helm upgrade --install cert-manager platform/cert-manager \
  --namespace cert-manager \
  --create-namespace
```

Prüfen:

```bash
kubectl get pods -n cert-manager -o wide
kubectl get crd | grep cert-manager
```

Warten bis alle Pods bereit sind:

```bash
kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=300s
```

## Let’s Encrypt Issuer

Es werden zwei ClusterIssuer verwendet.

```text
letsencrypt-staging
letsencrypt-prod
```

Dateien:

```text
platform/cert-manager/issuers/letsencrypt-staging.yaml
platform/cert-manager/issuers/letsencrypt-prod.yaml
```

Installieren:

```bash
kubectl apply -f platform/cert-manager/issuers/letsencrypt-staging.yaml
kubectl apply -f platform/cert-manager/issuers/letsencrypt-prod.yaml
```

Prüfen:

```bash
kubectl get clusterissuer
```

Erwartung:

```text
letsencrypt-staging   True
letsencrypt-prod      True
```

Für die Zertifikatsvalidierung wird HTTP01 verwendet. Deshalb muss Port 80 öffentlich erreichbar sein.

## Demo Anwendung

Zum Testen gibt es eine whoami Demo.

Datei:

```text
apps/demo/whoami.yaml
```

Der Hostname sollte in der Datei auf die eigene Domain angepasst werden.

Beispiel:

```text
whoami.<DOMAIN>
```

Installieren:

```bash
kubectl apply -f apps/demo/whoami.yaml
```

Prüfen:

```bash
kubectl get pods -n demo -o wide
kubectl get svc -n demo
kubectl get ingress -n demo
kubectl get certificate -n demo
```

Warten bis das Zertifikat bereit ist:

```bash
kubectl wait --for=condition=Ready certificate/whoami-tls -n demo --timeout=300s
```

Testen:

```bash
curl -v http://whoami.<DOMAIN>
curl -v https://whoami.<DOMAIN>
```

Erfolgreicher HTTPS Test:

```text
SSL certificate verified
issuer: C=US; O=Let's Encrypt
HTTP/2 200
X-Forwarded-Proto: https
```

## Installation von Grund auf

Aus dem Repository Root:

```bash
cd ~/Development/k3s-ai-platform
```

Falls `br0` bereits existiert, nicht erneut `host-bridge` ausführen.

VMs erstellen:

```bash
make vm-create
```

SSH prüfen:

```bash
make vm-test
```

Cluster installieren:

```bash
make cluster-create
```

Kubeconfig setzen:

```bash
export KUBECONFIG=$PWD/cluster/ansible/k3s.yaml
```

Traefik installieren:

```bash
make traefik-install
```

cert-manager installieren:

```bash
make cert-manager-install
```

Issuer installieren:

```bash
kubectl apply -f platform/cert-manager/issuers/letsencrypt-staging.yaml
kubectl apply -f platform/cert-manager/issuers/letsencrypt-prod.yaml
```

Demo installieren:

```bash
kubectl apply -f apps/demo/whoami.yaml
```

Validieren:

```bash
make validate
curl -v https://whoami.<DOMAIN>
```

## Redeploy Ablauf

Wenn das Cluster komplett neu aufgebaut werden soll:

```bash
make vm-delete
make vm-create
make vm-test
make cluster-create
```

Danach:

```bash
export KUBECONFIG=$PWD/cluster/ansible/k3s.yaml

make traefik-install
make cert-manager-install

kubectl apply -f platform/cert-manager/issuers/letsencrypt-staging.yaml
kubectl apply -f platform/cert-manager/issuers/letsencrypt-prod.yaml
kubectl apply -f apps/demo/whoami.yaml
```

FRITZ!Box Portfreigaben bleiben bestehen, solange `k3s-lb-1` wieder die IP `192.168.178.50` bekommt.

## Makefile Ziele

Wichtige Ziele:

```text
make host-bridge
make vm-create
make vm-delete
make vm-list
make vm-start
make vm-shutdown
make vm-test
make cluster-create
make cluster-delete
make traefik-install
make traefik-status
make cert-manager-install
make cert-manager-status
make validate
make cleanup
```

Hinweis:

```text
make host-bridge nur verwenden, wenn br0 fehlt.
```

## Validierung

Cluster:

```bash
kubectl get nodes -o wide
kubectl get nodes -L workload-type -L accelerator
kubectl get pods -A
```

Traefik:

```bash
kubectl get pods -n traefik -o wide
kubectl get svc -n traefik
kubectl logs -n traefik deploy/traefik
```

cert-manager:

```bash
kubectl get pods -n cert-manager -o wide
kubectl get clusterissuer
kubectl get certificate -A
kubectl get order -A
kubectl get challenge -A
```

DNS:

```bash
dig @8.8.8.8 <DOMAIN> A
dig @8.8.8.8 whoami.<DOMAIN> A
dig @8.8.8.8 <DOMAIN> AAAA
```

HAProxy:

```bash
ssh k3s-lb-1

sudo systemctl status haproxy --no-pager
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo ss -tulpn | grep -E ':80|:443|:6443'
```

Extern:

```bash
curl -v http://whoami.<DOMAIN>
curl -v https://whoami.<DOMAIN>
```

## Sicherheit

Öffentlich notwendig:

```text
TCP 80
TCP 443
```

Nicht öffentlich freigeben:

```text
TCP 22
TCP 6443
libvirt Ports
Ubuntu Host Management Ports
```

Port 80 wird für Let’s Encrypt HTTP01 benötigt.

Port 443 wird für HTTPS Dienste benötigt.

## Dateien, die nicht nach GitHub dürfen

Nicht committen:

```text
cluster/ansible/k3s.yaml
cluster/ansible/.k3s-bootstrap-token
tmp/
.local-secrets
platform/*/charts/*.tgz
```

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

# Helm Dependency Archive
platform/*/charts/*.tgz

# Logs
*.log

# Editor und OS
.DS_Store
.idea/
.vscode/
```

Vor dem Commit prüfen:

```bash
git status
git ls-files | grep -E 'k3s.yaml|bootstrap-token|tmp/|local-secrets|seed.iso|user-data|meta-data|\.tgz$'
git grep "<PUBLIC_IPV4>"
git grep "109."
```

Wenn kritische Dateien auftauchen, aus dem Git Index entfernen:

```bash
git rm --cached cluster/ansible/k3s.yaml 2>/dev/null || true
git rm --cached cluster/ansible/.k3s-bootstrap-token 2>/dev/null || true
git rm -r --cached tmp 2>/dev/null || true
git rm -r --cached .local-secrets 2>/dev/null || true
git rm -r --cached platform/traefik/charts 2>/dev/null || true
git rm -r --cached platform/cert-manager/charts 2>/dev/null || true
```

## Troubleshooting

### Domain zeigt noch auf alten Anbieter

Prüfen:

```bash
dig <DOMAIN>
dig @8.8.8.8 <DOMAIN>
```

Lokalen DNS Cache leeren:

```bash
sudo resolvectl flush-caches
```

### FRITZ!Box zeigt k3s-lb-1 nicht an

Prüfen:

```bash
ping -c 3 192.168.178.50
ssh k3s-lb-1 hostname
```

Danach FRITZ!Box Seite neu laden.

### SSH nutzt alte IPs

Prüfen:

```bash
grep -n -A4 -B1 "Host k3s" ~/.ssh/config
grep -n "192.168.122" ~/.ssh/config
```

Alte Einträge entfernen und neue Bridge IPs setzen:

```text
k3s-lb-1             192.168.178.50
k3s-server-1         192.168.178.51
k3s-agent-gpu-1      192.168.178.61
k3s-agent-tools-1    192.168.178.62
```

### Traefik antwortet mit 404

Das ist normal, wenn keine passende Ingress Route existiert.

Ein 404 bedeutet:

```text
Traefik ist erreichbar,
aber für diesen Host gibt es keine Route.
```

### HTTPS zeigt falsches Zertifikat

Prüfen:

```bash
curl -v https://whoami.<DOMAIN>
kubectl get certificate -n demo
kubectl describe certificate whoami-tls -n demo
```

### Connection refused

Prüfen:

```bash
ssh k3s-lb-1 "sudo ss -tulpn | grep -E ':80|:443'"
kubectl get svc -n traefik
```

Mögliche Ursachen:

```text
FRITZ!Box Freigabe zeigt auf falsches Gerät
HAProxy läuft nicht
Traefik ist nicht installiert
NodePort Service fehlt
```

## Aktueller Zielzustand

Ein erfolgreicher Zielzustand sieht so aus:

```text
DNS zeigt auf feste öffentliche IPv4
FRITZ!Box leitet 80 und 443 auf k3s-lb-1 weiter
k3s-lb-1 läuft im LAN unter 192.168.178.50
HAProxy leitet an Traefik NodePorts weiter
Traefik routet Ingress Ressourcen
cert-manager erstellt Let’s Encrypt Zertifikate
whoami ist per HTTPS erreichbar
```

Erfolgreicher Test:

```bash
curl -v https://whoami.<DOMAIN>
```

Erwartung:

```text
SSL certificate verified
HTTP/2 200
```
# k3s AI Platform

Lokale Kubernetes Plattform für AI Dienste auf Basis von KVM, libvirt, Ubuntu Cloud Images und K3s.

Das Projekt baut ein lokales Kubernetes Cluster als virtuelle Maschinen auf einem Ubuntu Host auf. Die Plattform stellt zentrale Dienste wie Traefik, cert-manager, Keycloak, PostgreSQL und später Open WebUI im Kubernetes Cluster bereit.

Die eigentliche KI Runtime läuft bewusst direkt auf dem Ubuntu Host. Dadurch kann die lokal verbaute NVIDIA RTX 5080 ohne PCI Passthrough genutzt werden. Auf GPU Passthrough in eine VM wird verzichtet, weil die RTX 5080 gleichzeitig als aktive Grafikkarte des Hosts genutzt wird.

Der externe Zugriff läuft über eine feste öffentliche IPv4 Adresse, eine FRITZ!Box, HAProxy, Traefik und cert-manager.

Öffentliche Werte wie Domain und öffentliche IPv4 Adresse werden in dieser Dokumentation bewusst als Platzhalter beschrieben.

## Ziel

Ziel ist eine lokal betreibbare Plattform für private AI Dienste unter eigener Domain.

Die Plattform deckt aktuell folgende Punkte ab:

```text
lokale VM Umgebung mit KVM und libvirt
K3s Cluster mit getrennten Rollen
LoadBalancer VM als zentraler Einstiegspunkt
HAProxy als vorgelagerter TCP LoadBalancer
Traefik als Kubernetes Ingress Controller
cert-manager für Let’s Encrypt Zertifikate
Keycloak als Identity Provider
PostgreSQL als Datenbank für Keycloak
Vorbereitung für Open WebUI unter ai.<DOMAIN>
Ollama direkt auf dem Ubuntu Host mit RTX 5080
reproduzierbarer Aufbau über Bash, Ansible und Helm Wrapper Charts
```

## Architektur

Das Cluster besteht aus drei virtuellen Maschinen.

| VM | IP | Rolle | RAM | vCPU | Disk |
|---|---:|---|---:|---:|---:|
| k3s-lb-1 | 192.168.178.50 | HAProxy LoadBalancer | 2048 MB | 1 | 20 GB |
| k3s-server-1 | 192.168.178.51 | K3s Server, Control Plane, etcd | 4096 MB | 4 | 60 GB |
| k3s-agent-tools-1 | 192.168.178.62 | Worker Node für Plattformdienste | 4096 MB | 4 | 100 GB |

Die KI Runtime läuft nicht als Kubernetes Pod.

Sie läuft direkt auf dem Ubuntu Host:

| System | Rolle |
|---|---|
| Ubuntu Host | Ollama mit NVIDIA RTX 5080 |

## Zielbild

```text
Internet
  -> feste öffentliche IPv4
  -> FRITZ!Box
  -> Portfreigabe TCP 80 und TCP 443
  -> k3s-lb-1
  -> HAProxy
  -> Traefik
  -> Kubernetes Ingress
  -> Open WebUI
  -> Ollama auf dem Ubuntu Host
  -> RTX 5080
```

## Warum Ollama direkt auf dem Host läuft

Die RTX 5080 wird vom Ubuntu Host als aktive Grafikkarte verwendet.

Ein PCI Passthrough dieser GPU an eine VM würde bedeuten, dass der Host die Karte nicht mehr für die eigene Bildausgabe nutzen kann. Deshalb wird kein GPU Passthrough verwendet.

Stattdessen läuft die KI Runtime direkt auf dem Host.

Vorteile dieses Ansatzes:

```text
kein PCI Passthrough erforderlich
keine VFIO Bindings für die Haupt GPU
kein Risiko für schwarze Bildschirme durch blockierte NVIDIA Treiber
RTX 5080 bleibt normal auf dem Host nutzbar
Open WebUI kann trotzdem im Kubernetes Cluster laufen
```

Nachteile dieses Ansatzes:

```text
Ollama wird nicht durch Kubernetes verwaltet
Ollama läuft als Host Service
Updates und Betrieb der KI Runtime erfolgen außerhalb von Helm
```

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

Beispiele:

```text
https://auth.<DOMAIN>
https://ai.<DOMAIN>
https://whoami.<DOMAIN>
```

## Öffentliche Werte

Beispielhafte DNS Verwendung:

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
auth.<DOMAIN>
ai.<DOMAIN>
```

Für den aktuellen Aufbau wird IPv4 verwendet.

AAAA Records sollten nur gesetzt werden, wenn auch IPv6 sauber auf den eigenen Anschluss und den eigenen Einstiegspunkt zeigt. Andernfalls können Clients über IPv6 an einem falschen Ziel landen.

DNS prüfen:

```bash
dig @8.8.8.8 <DOMAIN> A
dig @8.8.8.8 whoami.<DOMAIN> A
dig @8.8.8.8 auth.<DOMAIN> A
dig @8.8.8.8 ai.<DOMAIN> A
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
Port 11434 für Ollama
```

Port `6443` ist die Kubernetes API und sollte nicht aus dem Internet erreichbar sein.

Port `11434` ist die Ollama API auf dem Host. Dieser Port wird nur intern vom Kubernetes Cluster verwendet und sollte nicht öffentlich erreichbar sein.

## Ubuntu Host

Der Ubuntu Host ist der physische Rechner für die Virtualisierung und für die lokale KI Runtime.

Er stellt bereit:

```text
KVM
libvirt
virt-install
cloud-init
Ansible
kubectl
helm
NVIDIA Treiber
Ollama
```

Die VMs werden mit Ubuntu Cloud Images und cloud-init erstellt.

Wichtige Ordner:

```text
cluster/libvirt
cluster/ansible
platform/traefik
platform/cert-manager
platform/keycloak
platform/postgresql
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
  -> k3s-agent-tools-1:30080
```

HTTPS:

```text
192.168.178.50:443
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

Der Tools Node wird automatisch gelabelt.

Tools Node:

```text
node-role.kubernetes.io/worker=true
workload-type=tools
```

Prüfen:

```bash
kubectl get nodes -L workload-type
kubectl get nodes --show-labels
```

Plattform Workloads werden gezielt auf den Tools Node geplant:

```yaml
nodeSelector:
  workload-type: tools
```

Es gibt keinen Kubernetes GPU Node mehr.

Die KI Runtime läuft direkt auf dem Ubuntu Host und wird nicht über Kubernetes geplant.

## Hinweis zur GPU

Die NVIDIA RTX 5080 wird nicht an eine VM durchgereicht.

Nicht verwendet werden:

```text
PCI Passthrough
VFIO Binding der RTX 5080
NVIDIA Device Plugin im Kubernetes Cluster
nvidia.com/gpu Kubernetes Ressourcen
```

Stattdessen wird Ollama direkt auf dem Ubuntu Host betrieben.

Prüfen, ob die GPU auf dem Host verfügbar ist:

```bash
nvidia-smi
```

Erwartung:

```text
RTX 5080 wird angezeigt
NVIDIA Treiber ist aktiv
```

## Ollama auf dem Host

Ollama läuft direkt auf dem Ubuntu Host.

Installation:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Service prüfen:

```bash
systemctl status ollama
ollama --version
```

Damit Open WebUI aus dem Kubernetes Cluster auf Ollama zugreifen kann, muss Ollama auf der Host IP erreichbar sein.

Systemd Override erstellen:

```bash
sudo systemctl edit ollama
```

Inhalt:

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
```

Service neu laden:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Prüfen:

```bash
ss -tulpen | grep 11434
curl http://127.0.0.1:11434/api/tags
```

Erwartung:

```text
Ollama lauscht auf 0.0.0.0:11434
/api/tags liefert eine JSON Antwort
```

Wichtig:

```text
Port 11434 nicht in der FRITZ!Box freigeben.
Ollama soll nur intern aus dem LAN oder Kubernetes Cluster erreichbar sein.
```

## Ollama aus Kubernetes testen

Host IP ermitteln:

```bash
ip -4 addr
```

Dann aus dem Cluster testen:

```bash
kubectl run ollama-test \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -- curl http://<HOST_LAN_IP>:11434/api/tags
```

Erwartung:

```text
JSON Antwort von Ollama
```

## Modell laden

Kleines Startmodell laden:

```bash
ollama pull llama3.1:8b
```

Modell testen:

```bash
ollama run llama3.1:8b
```

GPU Nutzung prüfen:

```bash
watch -n 1 nvidia-smi
```

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

## Keycloak

Keycloak wird als Identity Provider verwendet.

Host:

```text
auth.<DOMAIN>
```

Chart:

```text
platform/keycloak
```

Keycloak läuft auf dem Tools Node:

```text
k3s-agent-tools-1
```

Keycloak verwendet eine externe PostgreSQL Datenbank im Namespace `keycloak`.

Installation:

```bash
helm dependency update platform/keycloak

helm upgrade --install keycloak platform/keycloak \
  --namespace keycloak \
  --create-namespace
```

Prüfen:

```bash
kubectl get pods -n keycloak -o wide
kubectl get ingress -n keycloak
kubectl get certificate -n keycloak
```

Erwartung:

```text
keycloak-0 läuft auf k3s-agent-tools-1
postgresql-0 läuft auf k3s-agent-tools-1
auth.<DOMAIN> Zertifikat ist Ready
Realm ist vorhanden
Login ist möglich
```

## PostgreSQL

PostgreSQL wird für Keycloak verwendet.

Chart:

```text
platform/postgresql
```

PostgreSQL läuft auf dem Tools Node:

```text
k3s-agent-tools-1
```

Wichtig ist der Node Selector in den Values:

```yaml
primary:
  nodeSelector:
    workload-type: tools
```

Je nach Wrapper Chart kann der Wert unterhalb von `postgresql.primary` liegen.

Prüfen:

```bash
kubectl get pod postgresql-0 -n keycloak -o wide
kubectl get pod postgresql-0 -n keycloak -o jsonpath='{.spec.nodeSelector}'
echo
```

Erwartung:

```text
postgresql-0 läuft auf k3s-agent-tools-1
```

## Open WebUI

Open WebUI soll später unter folgender Adresse laufen:

```text
https://ai.<DOMAIN>
```

Open WebUI läuft im Kubernetes Cluster auf dem Tools Node.

Die KI Runtime wird nicht im Cluster betrieben. Open WebUI verbindet sich stattdessen mit Ollama auf dem Ubuntu Host.

Zielkonfiguration:

```text
Open WebUI:
https://ai.<DOMAIN>

Ollama:
http://<HOST_LAN_IP>:11434
```

OIDC wird über Keycloak vorbereitet.

Keycloak Realm:

```text
tannenberg
```

OIDC Client:

```text
open-webui
```

Redirect URI:

```text
https://ai.<DOMAIN>/oauth/oidc/callback
```

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

PostgreSQL und Keycloak installieren:

```bash
helm dependency update platform/postgresql
helm upgrade --install postgresql platform/postgresql \
  --namespace keycloak \
  --create-namespace

helm dependency update platform/keycloak
helm upgrade --install keycloak platform/keycloak \
  --namespace keycloak \
  --create-namespace
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

## Ollama Installation auf dem Host

Ollama installieren:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Ollama erreichbar machen:

```bash
sudo systemctl edit ollama
```

Inhalt:

```ini
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
```

Neu starten:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Prüfen:

```bash
nvidia-smi
curl http://127.0.0.1:11434/api/tags
```

Modell laden:

```bash
ollama pull llama3.1:8b
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

helm upgrade --install postgresql platform/postgresql \
  --namespace keycloak \
  --create-namespace

helm upgrade --install keycloak platform/keycloak \
  --namespace keycloak \
  --create-namespace

kubectl apply -f apps/demo/whoami.yaml
```

FRITZ!Box Portfreigaben bleiben bestehen, solange `k3s-lb-1` wieder die IP `192.168.178.50` bekommt.

Ollama läuft unabhängig vom Kubernetes Redeploy direkt auf dem Host.

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
kubectl get nodes -L workload-type
kubectl get pods -A -o wide
```

Erwartung:

```text
k3s-lb-1 ist keine Kubernetes Node
k3s-server-1 ist Control Plane
k3s-agent-tools-1 ist Worker Node
kein k3s-agent-gpu-1 vorhanden
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

Keycloak:

```bash
kubectl get pods -n keycloak -o wide
kubectl get ingress -n keycloak
kubectl get certificate -n keycloak
```

Ollama:

```bash
nvidia-smi
systemctl status ollama
curl http://127.0.0.1:11434/api/tags
```

Ollama aus Kubernetes:

```bash
kubectl run ollama-test \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -- curl http://<HOST_LAN_IP>:11434/api/tags
```

DNS:

```bash
dig @8.8.8.8 <DOMAIN> A
dig @8.8.8.8 whoami.<DOMAIN> A
dig @8.8.8.8 auth.<DOMAIN> A
dig @8.8.8.8 ai.<DOMAIN> A
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
curl -v https://auth.<DOMAIN>
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
TCP 11434
libvirt Ports
Ubuntu Host Management Ports
```

Port 80 wird für Let’s Encrypt HTTP01 benötigt.

Port 443 wird für HTTPS Dienste benötigt.

Port 11434 ist die Ollama API und soll nicht öffentlich erreichbar sein.

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

Aktuelle Bridge IPs:

```text
k3s-lb-1             192.168.178.50
k3s-server-1         192.168.178.51
k3s-agent-tools-1    192.168.178.62
```

### Alte GPU VM ist noch vorhanden

Wenn `k3s-agent-gpu-1` aus einem alten Aufbau noch existiert, zuerst prüfen:

```bash
kubectl get pods -A -o wide | grep k3s-agent-gpu-1
kubectl get nodes
virsh list --all
```

Wenn keine produktiven Workloads mehr darauf laufen:

```bash
kubectl cordon k3s-agent-gpu-1
kubectl drain k3s-agent-gpu-1 --ignore-daemonsets --delete-emptydir-data
kubectl delete node k3s-agent-gpu-1
```

Danach VM entfernen:

```bash
virsh shutdown k3s-agent-gpu-1
virsh undefine k3s-agent-gpu-1 --remove-all-storage
```

Bei Longhorn vorher prüfen, ob noch Volumes oder Replicas auf dem Node liegen.

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

### Open WebUI erreicht Ollama nicht

Prüfen, ob Ollama auf dem Host erreichbar ist:

```bash
curl http://127.0.0.1:11434/api/tags
ss -tulpen | grep 11434
```

Prüfen, ob Ollama aus Kubernetes erreichbar ist:

```bash
kubectl run ollama-test \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -- curl http://<HOST_LAN_IP>:11434/api/tags
```

Mögliche Ursachen:

```text
OLLAMA_HOST ist nicht auf 0.0.0.0:11434 gesetzt
Firewall blockiert Port 11434 im LAN
falsche Host IP in Open WebUI konfiguriert
Ollama Service läuft nicht
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
Keycloak ist unter auth.<DOMAIN> erreichbar
Open WebUI ist später unter ai.<DOMAIN> erreichbar
Ollama läuft direkt auf dem Ubuntu Host
Ollama nutzt die RTX 5080 über den Host NVIDIA Treiber
```

Erfolgreicher Test für Kubernetes Ingress:

```bash
curl -v https://whoami.<DOMAIN>
```

Erwartung:

```text
SSL certificate verified
HTTP/2 200
```

Erfolgreicher Test für Ollama:

```bash
curl http://127.0.0.1:11434/api/tags
```

Erwartung:

```text
JSON Antwort von Ollama
```
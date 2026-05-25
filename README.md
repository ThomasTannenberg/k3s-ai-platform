# k3s AI Platform

Lokale Kubernetes Plattform für private AI Dienste.

Dieses Projekt erstellt ein lokales K3s Cluster auf virtuellen Maschinen. Im Cluster laufen Plattformdienste wie Traefik, cert-manager, Keycloak, PostgreSQL und Open WebUI.

Die KI Runtime läuft bewusst direkt auf dem Ubuntu Host. Dadurch kann die lokale NVIDIA GPU ohne PCI Passthrough verwendet werden. Open WebUI läuft im Kubernetes Cluster und verbindet sich intern mit Ollama auf dem Host.

Private Werte wie Domain, öffentliche IP Adresse, lokale IP Adressen, Secrets und Tokens werden in dieser Dokumentation nur als Platzhalter beschrieben.

## Ziel

Ziel ist ein reproduzierbares lokales AI Setup mit eigener Domain, zentralem Login und GPU Nutzung auf dem Host.

Das Setup umfasst:

```text
KVM und libvirt für lokale virtuelle Maschinen
K3s als Kubernetes Distribution
eine LoadBalancer VM als zentraler Einstiegspunkt
HAProxy vor dem Cluster
Traefik als Kubernetes Ingress Controller
cert-manager für TLS Zertifikate
Keycloak als Identity Provider
PostgreSQL als Keycloak Datenbank
Open WebUI als Weboberfläche
Ollama direkt auf dem Ubuntu Host
interner Kubernetes Service für Ollama
UFW Firewall Schutz für die Ollama API
```

## Architektur

Das Cluster besteht aus drei virtuellen Maschinen.

| System | Rolle |
|---|---|
| k3s-lb-1 | HAProxy LoadBalancer |
| k3s-server-1 | K3s Server, Control Plane und etcd |
| k3s-agent-tools-1 | Worker Node für Plattformdienste |

Die KI Runtime läuft nicht in einer VM und nicht als GPU Pod.

| System | Rolle |
|---|---|
| Ubuntu Host | Ollama mit NVIDIA GPU |

## Platzhalter

In dieser README werden keine privaten Werte genannt.

| Platzhalter | Bedeutung |
|---|---|
| `<DOMAIN>` | eigene Domain |
| `<PUBLIC_IPV4>` | öffentliche IPv4 Adresse |
| `<LB_LAN_IP>` | LAN IP der LoadBalancer VM |
| `<K3S_SERVER_LAN_IP>` | LAN IP der K3s Server VM |
| `<TOOLS_NODE_LAN_IP>` | LAN IP der Tools Worker VM |
| `<HOST_LAN_IP>` | LAN IP des Ubuntu Hosts |
| `<POD_CIDR>` | Kubernetes Pod CIDR |
| `<SERVICE_CIDR>` | Kubernetes Service CIDR |
| `<REALM>` | Keycloak Realm für Open WebUI |

Beispiele für Dienste:

```text
https://auth.<DOMAIN>
https://ai.<DOMAIN>
https://whoami.<DOMAIN>
```

## Zielbild

```text
Internet
  -> öffentliche IPv4
  -> Router
  -> TCP 80 und TCP 443
  -> k3s-lb-1
  -> HAProxy
  -> Traefik
  -> Kubernetes Ingress
  -> Open WebUI
  -> Kubernetes Service ollama-host
  -> Ollama auf dem Ubuntu Host
  -> NVIDIA GPU
```

## Warum Ollama auf dem Host läuft

Die lokale NVIDIA GPU wird vom Ubuntu Host verwendet.

Ein PCI Passthrough dieser GPU an eine VM würde bedeuten, dass der Host die GPU nicht mehr regulär nutzen kann. Deshalb wird auf GPU Passthrough verzichtet.

Stattdessen läuft Ollama direkt auf dem Host.

Vorteile:

```text
kein PCI Passthrough notwendig
keine VFIO Konfiguration notwendig
GPU bleibt für den Host nutzbar
Open WebUI kann trotzdem im Kubernetes Cluster laufen
```

Nachteile:

```text
Ollama wird nicht durch Kubernetes verwaltet
Ollama läuft als Host Service
Updates der KI Runtime erfolgen außerhalb von Helm
```

## Nicht verwendete Komponenten

Das aktuelle Zielsetup verwendet bewusst keine GPU VM.

Nicht verwendet werden:

```text
k3s-agent-gpu-1 als VM
PCI Passthrough
VFIO Binding der Haupt GPU
NVIDIA Device Plugin im Kubernetes Cluster
nvidia.com/gpu Kubernetes Ressourcen
```

## Netzwerk

Der öffentliche Zugriff läuft über den Router zur LoadBalancer VM.

```text
Internet
  -> Router
  -> TCP 80 und TCP 443
  -> <LB_LAN_IP>
  -> HAProxy
  -> Traefik NodePorts
  -> Kubernetes Ingress
```

Benötigte öffentliche Portfreigaben:

```text
TCP 80  -> <LB_LAN_IP>:80
TCP 443 -> <LB_LAN_IP>:443
```

Nicht öffentlich freigeben:

```text
TCP 22
TCP 6443
TCP 11434
libvirt Ports
Host Management Ports
```

Port 80 wird für Let’s Encrypt HTTP01 benötigt.

Port 443 wird für HTTPS Dienste benötigt.

Port 11434 ist die Ollama API und darf nicht öffentlich erreichbar sein.

## DNS

Beim DNS Anbieter werden A Records auf die öffentliche IPv4 gesetzt.

Beispiel:

```text
A   @     <PUBLIC_IPV4>
A   *     <PUBLIC_IPV4>
A   www   <PUBLIC_IPV4>
```

Damit zeigen die Hauptdomain, `www` und alle Subdomains auf die öffentliche IPv4 Adresse.

Beispiele:

```text
<DOMAIN>
www.<DOMAIN>
whoami.<DOMAIN>
auth.<DOMAIN>
ai.<DOMAIN>
```

AAAA Records sollten nur gesetzt werden, wenn IPv6 vollständig korrekt eingerichtet ist.

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

## Ubuntu Host

Der Ubuntu Host stellt die Virtualisierung und die lokale KI Runtime bereit.

Benötigt werden:

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

Wichtige Verzeichnisse:

```text
cluster/libvirt
cluster/ansible
platform/traefik
platform/cert-manager
platform/keycloak
platform/postgresql
platform/open-webui
platform/ollama-host
apps/demo
docs
```

## libvirt Bridge

Die VMs laufen im LAN über eine Linux Bridge.

Prüfen:

```bash
ip -br addr
bridge link
```

Erwartung:

```text
Bridge ist vorhanden
Bridge hat eine LAN IP
physisches Interface ist Mitglied der Bridge
```

Das Bridge Setup wird nur benötigt, wenn der Host noch keine passende Bridge hat.

Nicht bei jedem Redeploy ausführen.

## HAProxy

HAProxy läuft auf der LoadBalancer VM.

HAProxy leitet weiter:

```text
TCP 6443 -> K3s Server API
TCP 80   -> Traefik HTTP NodePort
TCP 443  -> Traefik HTTPS NodePort
```

Template:

```text
cluster/ansible/templates/haproxy.cfg.j2
```

Prüfen:

```bash
ssh k3s-lb-1

sudo systemctl status haproxy --no-pager
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo ss -tulpn | grep -E ':80|:443|:6443'
```

## K3s

Das K3s Cluster wird über Ansible installiert.

Wichtige Dateien:

```text
cluster/ansible/inventory.ini
cluster/ansible/group_vars/all.yml
cluster/ansible/k3s.yaml
```

Die Kubeconfig wird erzeugt unter:

```text
cluster/ansible/k3s.yaml
```

Diese Datei darf nicht nach Git.

Kubeconfig setzen:

```bash
export KUBECONFIG=$PWD/cluster/ansible/k3s.yaml
```

Oder lokal kopieren:

```bash
mkdir -p ~/.kube
cp cluster/ansible/k3s.yaml ~/.kube/config
chmod 600 ~/.kube/config
```

Nodes prüfen:

```bash
kubectl get nodes -o wide
kubectl get nodes --show-labels
```

## Node Labels

Der Tools Node wird für Plattform Workloads verwendet.

Beispiel Label:

```text
workload-type=tools
```

Prüfen:

```bash
kubectl get nodes -L workload-type
```

Plattform Workloads können gezielt auf den Tools Node geplant werden:

```yaml
nodeSelector:
  workload-type: tools
```

## Secrets

Lokale Secrets liegen außerhalb von Git.

Beispiel:

```text
.local-secrets/keycloak.env
```

Diese Datei enthält Werte wie:

```text
KEYCLOAK_ADMIN_PASSWORD
KEYCLOAK_POSTGRES_ADMIN_PASSWORD
KEYCLOAK_POSTGRES_USER_PASSWORD
OPENWEBUI_OIDC_CLIENT_SECRET
```

Die Datei darf nicht nach Git.

Das Ansible Playbook erstellt daraus Kubernetes Secrets.

Für Keycloak:

```text
Namespace: keycloak
Secret: keycloak-admin-secret
Secret: keycloak-postgresql-secret
Secret: openwebui-oidc-client-secret
```

Für Open WebUI:

```text
Namespace: open-webui
Secret: open-webui-oidc-secret
Key: OAUTH_CLIENT_SECRET
```

Wichtig:

```text
Kubernetes Secrets sind namespace gebunden.
Open WebUI kann kein Secret aus dem Namespace keycloak direkt lesen.
```

## Traefik

Traefik wird als Kubernetes Ingress Controller verwendet.

Chart:

```text
platform/traefik
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
Traefik läuft auf dem Tools Node
Traefik Service ist als NodePort erreichbar
IngressClass ist vorhanden
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
kubectl get clusterissuer
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

Für HTTP01 muss Port 80 öffentlich erreichbar sein.

## PostgreSQL

PostgreSQL wird für Keycloak verwendet.

Chart:

```text
platform/postgresql
```

Installation:

```bash
helm dependency update platform/postgresql

helm upgrade --install postgresql platform/postgresql \
  --namespace keycloak \
  --create-namespace
```

Prüfen:

```bash
kubectl get pod postgresql-0 -n keycloak -o wide
kubectl get secret keycloak-postgresql-secret -n keycloak
```

## Keycloak

Keycloak wird als Identity Provider verwendet.

Adresse:

```text
https://auth.<DOMAIN>
```

Chart:

```text
platform/keycloak
```

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
Keycloak Pod läuft
PostgreSQL Pod läuft
Zertifikat ist Ready
Login ist möglich
```

## Keycloak Realm und Open WebUI Client

Im Keycloak Realm wird ein OIDC Client für Open WebUI verwendet.

Client:

```text
open-webui
```

Redirect URI:

```text
https://ai.<DOMAIN>/oauth/oidc/callback
```

Das Client Secret wird aus `.local-secrets/keycloak.env` erzeugt und von Ansible als Kubernetes Secret bereitgestellt.

## Ollama auf dem Host

Ollama wird direkt auf dem Ubuntu Host installiert.

Installation:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Service prüfen:

```bash
systemctl status ollama
ollama --version
```

GPU prüfen:

```bash
nvidia-smi
```

Damit Open WebUI aus dem Kubernetes Cluster auf Ollama zugreifen kann, muss Ollama auf der Host IP erreichbar sein.

Systemd Override:

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
curl http://<HOST_LAN_IP>:11434/api/tags
```

Erwartung:

```text
Ollama lauscht auf 0.0.0.0:11434
/api/tags liefert eine JSON Antwort
```

## Modelle laden

Beispiele:

```bash
ollama pull qwen3:14b
ollama pull qwen3.6:27b
```

Modelle anzeigen:

```bash
ollama list
```

Modell testen:

```bash
ollama run qwen3:14b
```

GPU Nutzung beobachten:

```bash
watch -n 1 nvidia-smi
```

## Ollama Host Service im Cluster

Open WebUI soll nicht direkt mit einer IP Adresse konfiguriert werden.

Stattdessen gibt es einen Kubernetes Service mit EndpointSlice.

Datei:

```text
platform/ollama-host/ollama-host-service.yaml
```

Beispiel:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ollama-host
  namespace: open-webui
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 11434
      targetPort: 11434
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ollama-host-1
  namespace: open-webui
  labels:
    kubernetes.io/service-name: ollama-host
addressType: IPv4
ports:
  - name: http
    protocol: TCP
    port: 11434
endpoints:
  - addresses:
      - "<HOST_LAN_IP>"
```

Anwenden:

```bash
kubectl apply -f platform/ollama-host/ollama-host-service.yaml
```

Test:

```bash
kubectl run ollama-test \
  -n open-webui \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -- curl -v --connect-timeout 5 http://ollama-host.open-webui.svc.cluster.local:11434/api/tags
```

Erwartung:

```text
HTTP 200
JSON Antwort mit den installierten Modellen
```

## Open WebUI

Open WebUI läuft im Kubernetes Cluster.

Adresse:

```text
https://ai.<DOMAIN>
```

Helm Chart:

```text
open-webui/open-webui
```

Values:

```text
platform/open-webui/values.yaml
```

Wichtige Konfiguration:

```yaml
ollama:
  enabled: false

pipelines:
  enabled: false

persistence:
  enabled: true
  size: 20Gi

ingress:
  enabled: true
  class: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  host: ai.<DOMAIN>
  tls: true

extraEnvVars:
  - name: WEBUI_URL
    value: "https://ai.<DOMAIN>"

  - name: ENABLE_OLLAMA_API
    value: "true"

  - name: OLLAMA_BASE_URL
    value: "http://ollama-host.open-webui.svc.cluster.local:11434"

  - name: OLLAMA_BASE_URLS
    value: "http://ollama-host.open-webui.svc.cluster.local:11434"

  - name: ENABLE_OAUTH_SIGNUP
    value: "true"

  - name: DEFAULT_USER_ROLE
    value: "user"

  - name: ENABLE_SIGNUP
    value: "false"
  
  - name: BYPASS_MODEL_ACCESS_CONTROL
    value: "true"

  - name: ENABLE_LOGIN_FORM
    value: "false"

  - name: OAUTH_MERGE_ACCOUNTS_BY_EMAIL
    value: "true"

  - name: OAUTH_CLIENT_ID
    value: "open-webui"

  - name: OAUTH_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: open-webui-oidc-secret
        key: OAUTH_CLIENT_SECRET

  - name: OPENID_PROVIDER_URL
    value: "https://auth.<DOMAIN>/realms/<REALM>/.well-known/openid-configuration"

  - name: OAUTH_PROVIDER_NAME
    value: "Keycloak"

  - name: OPENID_REDIRECT_URI
    value: "https://ai.<DOMAIN>/oauth/oidc/callback"
```

Installation:

```bash
helm repo add open-webui https://helm.openwebui.com/
helm repo update

helm upgrade --install open-webui open-webui/open-webui \
  --namespace open-webui \
  --create-namespace \
  -f platform/open-webui/values.yaml
```

Prüfen:

```bash
kubectl get pods -n open-webui
kubectl get svc -n open-webui
kubectl get ingress -n open-webui
kubectl get certificate -n open-webui
helm get values open-webui -n open-webui
```

Logs:

```bash
kubectl logs statefulset/open-webui -n open-webui --tail=150
```

Environment prüfen:

```bash
kubectl exec -n open-webui open-webui-0 -- printenv | grep -E "OLLAMA|OAUTH|OPENID|WEBUI|DEFAULT_USER_ROLE|ENABLE_LOGIN_FORM|ENABLE_SIGNUP"
```

Erwartung:

```text
Login läuft über Keycloak
lokaler Login ist deaktiviert
freie Registrierung ist deaktiviert
neue Keycloak Benutzer werden automatisch als normale Benutzer aktiviert
Open WebUI findet die Ollama Modelle
```

## UFW Firewall auf dem Host

Ollama lauscht auf dem Host auf Port 11434.

Port 11434 darf nicht öffentlich freigegeben werden.

Empfohlene UFW Regeln auf dem Host:

```bash
sudo ufw allow 22/tcp
sudo ufw allow from <POD_CIDR> to any port 11434 proto tcp
sudo ufw allow from <K3S_SERVER_LAN_IP> to any port 11434 proto tcp
sudo ufw allow from <TOOLS_NODE_LAN_IP> to any port 11434 proto tcp
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
```

Status prüfen:

```bash
sudo ufw status verbose
```

Erwartung:

```text
eingehend standardmäßig blockiert
ausgehend erlaubt
SSH erlaubt
Ollama nur für Pod CIDR und K3s Nodes erlaubt
```

Wichtig:

```text
Keine allgemeine Freigabe für Port 11434 setzen.
Keine Portfreigabe für 11434 im Router setzen.
```

Ollama nach aktivierter Firewall testen:

```bash
curl http://127.0.0.1:11434/api/tags

kubectl run ollama-test \
  -n open-webui \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -- curl -v --connect-timeout 5 http://ollama-host.open-webui.svc.cluster.local:11434/api/tags
```

## Demo Anwendung

Zum Testen gibt es eine whoami Demo.

Datei:

```text
apps/demo/whoami.yaml
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

Testen:

```bash
curl -v http://whoami.<DOMAIN>
curl -v https://whoami.<DOMAIN>
```

Erwartung:

```text
HTTPS funktioniert
Zertifikat ist gültig
whoami antwortet
```

## Installation von Grund auf

Aus dem Repository Root:

```bash
cd <REPOSITORY_PATH>
```

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

Secrets erstellen:

```bash
ansible-playbook cluster/ansible/create-secrets.yml
```

PostgreSQL installieren:

```bash
helm dependency update platform/postgresql

helm upgrade --install postgresql platform/postgresql \
  --namespace keycloak \
  --create-namespace
```

Keycloak installieren:

```bash
helm dependency update platform/keycloak

helm upgrade --install keycloak platform/keycloak \
  --namespace keycloak \
  --create-namespace
```

Ollama Host Service installieren:

```bash
kubectl apply -f platform/ollama-host/ollama-host-service.yaml
```

Open WebUI installieren:

```bash
helm upgrade --install open-webui open-webui/open-webui \
  --namespace open-webui \
  --create-namespace \
  -f platform/open-webui/values.yaml
```

Validieren:

```bash
make validate
```

## Redeploy Ablauf

Kompletter Neuaufbau der VMs:

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

ansible-playbook cluster/ansible/create-secrets.yml

helm upgrade --install postgresql platform/postgresql \
  --namespace keycloak \
  --create-namespace

helm upgrade --install keycloak platform/keycloak \
  --namespace keycloak \
  --create-namespace

kubectl apply -f platform/ollama-host/ollama-host-service.yaml

helm upgrade --install open-webui open-webui/open-webui \
  --namespace open-webui \
  --create-namespace \
  -f platform/open-webui/values.yaml
```

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
make host-bridge nur verwenden, wenn die Bridge fehlt.
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
LoadBalancer VM ist keine Kubernetes Node
Server VM ist Control Plane
Tools VM ist Worker Node
kein GPU Worker vorhanden
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

Open WebUI:

```bash
kubectl get pods -n open-webui
kubectl get ingress -n open-webui
kubectl get certificate -n open-webui
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
  -n open-webui \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -- curl -v --connect-timeout 5 http://ollama-host.open-webui.svc.cluster.local:11434/api/tags
```

DNS:

```bash
dig @8.8.8.8 <DOMAIN> A
dig @8.8.8.8 whoami.<DOMAIN> A
dig @8.8.8.8 auth.<DOMAIN> A
dig @8.8.8.8 ai.<DOMAIN> A
dig @8.8.8.8 <DOMAIN> AAAA
```

Extern:

```bash
curl -v https://whoami.<DOMAIN>
curl -v https://auth.<DOMAIN>
curl -v https://ai.<DOMAIN>
```

## Dateien, die nicht nach Git dürfen

Nicht committen:

```text
.local-secrets
.local-secrets/
cluster/ansible/k3s.yaml
cluster/ansible/.k3s-bootstrap-token
tmp/
platform/*/charts/*.tgz
*.log
```

Empfohlene `.gitignore` Einträge:

```gitignore
.local-secrets
.local-secrets/

tmp/

cluster/ansible/k3s.yaml
cluster/ansible/.k3s-bootstrap-token

platform/*/charts/*.tgz

*.log

.DS_Store
.idea/
.vscode/
```

Vor dem Commit prüfen:

```bash
git status
git ls-files | grep -E 'k3s.yaml|bootstrap-token|tmp/|local-secrets|seed.iso|user-data|meta-data|\.tgz$'
git grep "<PUBLIC_IPV4>"
```

Falls sensible Dateien im Git Index liegen:

```bash
git rm --cached cluster/ansible/k3s.yaml 2>/dev/null || true
git rm --cached cluster/ansible/.k3s-bootstrap-token 2>/dev/null || true
git rm -r --cached tmp 2>/dev/null || true
git rm -r --cached .local-secrets 2>/dev/null || true
```

## Troubleshooting

### Open WebUI zeigt keine Modelle

Prüfen:

```bash
kubectl exec -n open-webui open-webui-0 -- printenv | grep OLLAMA
kubectl run ollama-test \
  -n open-webui \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -- curl -v --connect-timeout 5 http://ollama-host.open-webui.svc.cluster.local:11434/api/tags
```

Mögliche Ursachen:

```text
ENABLE_OLLAMA_API ist nicht true
OLLAMA_BASE_URL zeigt auf falsches Ziel
OLLAMA_BASE_URLS fehlt
ollama-host Service oder EndpointSlice fehlt
Ollama läuft nicht
Firewall blockiert Port 11434
```

### Open WebUI Account Activation Pending

Ursache:

```text
DEFAULT_USER_ROLE steht noch auf pending
oder alter Benutzerstatus liegt noch in der Open WebUI Datenbank
```

Lösung:

```text
DEFAULT_USER_ROLE auf user setzen
Open WebUI neu deployen
bei bestehenden Benutzern Status im Admin Panel ändern
oder Open WebUI PVC löschen und neu deployen
```

### Keycloak Login funktioniert nicht

Prüfen:

```bash
kubectl logs statefulset/open-webui -n open-webui --tail=150
kubectl get secret open-webui-oidc-secret -n open-webui
curl https://auth.<DOMAIN>/realms/<REALM>/.well-known/openid-configuration
```

Mögliche Ursachen:

```text
Redirect URI passt nicht exakt
Client Secret fehlt im Namespace open-webui
OPENID_PROVIDER_URL ist falsch
WEBUI_URL ist falsch
Keycloak Realm oder Client fehlt
```

### Traefik antwortet mit 404

Ein 404 bedeutet normalerweise:

```text
Traefik ist erreichbar
aber für diesen Host existiert keine passende Ingress Route
```

Prüfen:

```bash
kubectl get ingress -A
kubectl describe ingress -A
```

### HTTPS Zertifikat wird nicht erstellt

Prüfen:

```bash
kubectl get certificate -A
kubectl get order -A
kubectl get challenge -A
kubectl describe certificate -n <NAMESPACE> <CERTIFICATE_NAME>
```

Mögliche Ursachen:

```text
DNS zeigt nicht auf die öffentliche IPv4
Port 80 ist nicht öffentlich erreichbar
Router Portfreigabe fehlt
ClusterIssuer ist nicht bereit
Ingress Annotation ist falsch
```

### Connection refused

Prüfen:

```bash
ssh k3s-lb-1 "sudo ss -tulpn | grep -E ':80|:443'"
kubectl get svc -n traefik
kubectl get pods -n traefik
```

Mögliche Ursachen:

```text
HAProxy läuft nicht
Router zeigt auf falsches Ziel
Traefik NodePort fehlt
Traefik Pod läuft nicht
```

### Ollama ist aus Kubernetes nicht erreichbar

Prüfen:

```bash
curl http://127.0.0.1:11434/api/tags
curl http://<HOST_LAN_IP>:11434/api/tags
ss -tulpen | grep 11434
sudo ufw status verbose
```

Dann aus Kubernetes:

```bash
kubectl run ollama-test \
  -n open-webui \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -- curl -v --connect-timeout 5 http://ollama-host.open-webui.svc.cluster.local:11434/api/tags
```

Mögliche Ursachen:

```text
OLLAMA_HOST ist nicht auf 0.0.0.0:11434 gesetzt
Host IP im EndpointSlice ist falsch
UFW blockiert das Pod CIDR
Ollama Service läuft nicht
```

## Erfolgreicher Zielzustand

Ein erfolgreicher Zielzustand sieht so aus:

```text
DNS zeigt auf die öffentliche IPv4
Router leitet TCP 80 und TCP 443 auf die LoadBalancer VM weiter
HAProxy leitet an Traefik weiter
Traefik routet Kubernetes Ingress Ressourcen
cert-manager erstellt gültige TLS Zertifikate
Keycloak ist unter auth.<DOMAIN> erreichbar
Open WebUI ist unter ai.<DOMAIN> erreichbar
Login läuft über Keycloak
freie Open WebUI Registrierung ist deaktiviert
neue Keycloak Benutzer werden automatisch als Benutzer aktiviert
Ollama läuft direkt auf dem Ubuntu Host
Open WebUI erreicht Ollama über den Kubernetes Service ollama-host
Ollama nutzt die NVIDIA GPU auf dem Host
Port 11434 ist nicht öffentlich freigegeben
UFW erlaubt Port 11434 nur für Kubernetes und definierte Nodes
``` 
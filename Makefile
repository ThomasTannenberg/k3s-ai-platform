.PHONY: help host-bridge vm-create vm-delete vm-list vm-start vm-shutdown vm-test cluster-create cluster-delete install validate cleanup traefik-deps traefik-install traefik-status traefik-delete cert-manager-deps cert-manager-install cert-manager-status cert-manager-delete

KUBECONFIG_FILE := cluster/ansible/k3s.yaml

VMS := k3s-lb-1 k3s-server-1 k3s-agent-gpu-1 k3s-agent-tools-1

help:
	@echo "Verfügbare Ziele:"
	@echo "  make host-bridge            Host Bridge br0 für LAN VMs erstellen"
	@echo "  make vm-create              Host vorbereiten und VMs erstellen"
	@echo "  make vm-delete              VMs löschen"
	@echo "  make vm-list                VMs anzeigen"
	@echo "  make vm-start               VMs starten"
	@echo "  make vm-shutdown            VMs herunterfahren"
	@echo "  make vm-test                SSH Zugriff auf VMs testen"
	@echo "  make cluster-create         K3s Cluster per Ansible erstellen"
	@echo "  make cluster-delete         K3s Cluster per Ansible entfernen"
	@echo "  make traefik-install        Traefik Wrapper Chart installieren"
	@echo "  make cert-manager-install   cert-manager Wrapper Chart installieren"
	@echo "  make install                VMs erstellen und Cluster erstellen"
	@echo "  make validate               Cluster prüfen"
	@echo "  make cleanup                Cluster und VMs löschen"

host-bridge:
	cd cluster/libvirt && ./02-create-host-bridge.sh

vm-create:
	cd cluster/libvirt && ./00-bootstrap.sh
	cd cluster/libvirt && ./01-deploy-cluster-cloudimg.sh

vm-delete:
	cd cluster/libvirt && ./99-cleanup.sh

vm-list:
	virsh list --all

vm-start:
	@for vm in $(VMS); do \
		echo "==> Starte $$vm"; \
		virsh start $$vm 2>/dev/null || true; \
	done

vm-shutdown:
	@for vm in $(VMS); do \
		echo "==> Fahre $$vm herunter"; \
		virsh shutdown $$vm 2>/dev/null || true; \
	done

vm-test:
	@echo "==> SSH Test zu allen VMs"
	@for vm in $(VMS); do \
		echo -n "$$vm: "; \
		ssh -o ConnectTimeout=5 -o BatchMode=yes $$vm "hostname" 2>/dev/null || echo "FEHLER"; \
	done

cluster-create:
	cd cluster/ansible && ansible-playbook site.yml

cluster-delete:
	cd cluster/ansible && ansible-playbook uninstall.yml

install: host-bridge vm-create cluster-create

validate:
	@echo "------------------------- Nodes ----------------------------"
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -o wide
	@echo "------------------------- Node Labels ----------------------"
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes -L workload-type -L accelerator
	@echo "------------------------- Pods -----------------------------"
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -A
	@echo "------------------------- Helm -----------------------------"
	KUBECONFIG=$(KUBECONFIG_FILE) helm list -A || true
	@echo "------------------------- StorageClass ---------------------"
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get storageclass || true
	@echo "------------------------- PVC ------------------------------"
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pvc -A || true
	@echo "------------------------- PV -------------------------------"
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pv || true
	@echo "------------------------- Services -------------------------"
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get svc -A
	@echo "------------------------- Ingress --------------------------"
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get ingress -A || true
	@echo "------------------------- Certificates ---------------------"
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get certificate -A || true
	@echo "------------------------- ClusterIssuer --------------------"
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get clusterissuer || true

cleanup: cluster-delete vm-delete

traefik-deps:
	helm dependency update platform/traefik

traefik-install: traefik-deps
	KUBECONFIG=$(KUBECONFIG_FILE) helm upgrade --install traefik platform/traefik --namespace traefik --create-namespace

traefik-status:
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -n traefik -o wide
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get svc -n traefik
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get ingressclass

traefik-delete:
	KUBECONFIG=$(KUBECONFIG_FILE) helm uninstall traefik --namespace traefik || true

cert-manager-deps:
	helm dependency update platform/cert-manager

cert-manager-install: cert-manager-deps
	KUBECONFIG=$(KUBECONFIG_FILE) helm upgrade --install cert-manager platform/cert-manager --namespace cert-manager --create-namespace

cert-manager-status:
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -n cert-manager -o wide
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get crd | grep cert-manager || true
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get clusterissuer || true

cert-manager-delete:
	KUBECONFIG=$(KUBECONFIG_FILE) helm uninstall cert-manager --namespace cert-manager || true

cert-manager-issuers:
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl apply -f platform/cert-manager/issuers/letsencrypt-staging.yaml
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl apply -f platform/cert-manager/issuers/letsencrypt-prod.yaml
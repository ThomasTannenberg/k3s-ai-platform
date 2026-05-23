
.PHONY: help vm-create vm-delete vm-list vm-start vm-shutdown vm-test cluster-create cluster-delete install validate cleanup

KUBECONFIG_FILE := cluster/ansible/k3s.yaml

VMS := k3s-lb-1 k3s-server-1 k3s-agent-gpu-1 k3s-agent-tools-1

help:
	@echo "Verfügbare Ziele:"
	@echo "  make vm-create          Host vorbereiten und VMs erstellen"
	@echo "  make vm-delete          VMs löschen"
	@echo "  make vm-list            VMs anzeigen"
	@echo "  make vm-start           VMs starten"
	@echo "  make vm-shutdown        VMs herunterfahren"
	@echo "  make vm-test            SSH Zugriff auf VMs testen"
	@echo "  make cluster-create     K3s Cluster per Ansible erstellen"
	@echo "  make cluster-delete     K3s Cluster per Ansible entfernen"
	@echo "  make install            VMs erstellen und Cluster erstellen"
	@echo "  make validate           Cluster prüfen"
	@echo "  make cleanup            Cluster und VMs löschen"

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

install: vm-create cluster-create

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

cleanup: cluster-delete vm-delete

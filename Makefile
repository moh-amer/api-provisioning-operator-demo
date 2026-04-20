SHELL          := /bin/bash
BINARY_NAME    = apigee-api-operator
IMAGE_NAME     = apigee-api-operator
IMAGE_TAG      ?= latest
KIND_CLUSTER   = operator-demo
NAMESPACE      = apigee-api-operator-system
PROJECT        ?= ""
ENV            ?= eval
REGISTRY       ?= ""           # e.g. gcr.io/my-project  OR  docker.io/myuser
ISSUER         ?= ""

LOCAL_IMAGE    = $(IMAGE_NAME):$(IMAGE_TAG)
REMOTE_IMAGE   = $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  Apigee API Operator — Make Targets"
	@echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Common workflows:"
	@echo "    Local kind:   make kind-create setup-auth PROJECT=xxx run-local"
	@echo "    Any cluster:  make push REGISTRY=gcr.io/xxx PROJECT=xxx"
	@echo "                  make deploy-anywhere REGISTRY=gcr.io/xxx PROJECT=xxx"
	@echo ""

# ── Build ─────────────────────────────────────────────────────────────────────
.PHONY: build
build: ## Compile the operator binary
	CGO_ENABLED=0 go build -ldflags="-s -w" -o $(BINARY_NAME) .

.PHONY: docker-build
docker-build: ## Build Docker image (local tag)
	docker build -t $(LOCAL_IMAGE) .

.PHONY: push
push: docker-build ## Build AND push to registry. Usage: make push REGISTRY=gcr.io/my-project
	@[[ -n "$(REGISTRY)" ]] || (echo "ERROR: REGISTRY is required. Usage: make push REGISTRY=gcr.io/my-project" && exit 1)
	docker tag $(LOCAL_IMAGE) $(REMOTE_IMAGE)
	docker push $(REMOTE_IMAGE)
	@echo "✓ Pushed: $(REMOTE_IMAGE)"

# ── Auth Setup ────────────────────────────────────────────────────────────────
.PHONY: setup-auth
setup-auth: ## Setup GCP auth (auto-detects cluster). Usage: make setup-auth PROJECT=my-project
	@[[ -n "$(PROJECT)" ]] || (echo "ERROR: PROJECT required" && exit 1)
	@chmod +x hack/setup-auth.sh
	@hack/setup-auth.sh --project $(PROJECT) --env $(ENV) --namespace $(NAMESPACE)

.PHONY: setup-auth-adc
setup-auth-adc: ## ADC-only auth: skip GCP IAM, use existing ADC (for GCP VMs). Usage: make setup-auth-adc PROJECT=my-project
	@[[ -n "$(PROJECT)" ]] || (echo "ERROR: PROJECT required" && exit 1)
	@chmod +x hack/setup-auth.sh
	@hack/setup-auth.sh --project $(PROJECT) --namespace $(NAMESPACE) --adc-only

.PHONY: setup-wif
setup-wif: ## Workload Identity Federation for any cluster. Usage: make setup-wif PROJECT=xxx [ISSUER=https://...]
	@[[ -n "$(PROJECT)" ]] || (echo "ERROR: PROJECT required" && exit 1)
	@chmod +x hack/setup-wif.sh
	@if [[ "$(ISSUER)" == "" ]]; then \
		hack/setup-wif.sh --project $(PROJECT) --namespace $(NAMESPACE); \
	else \
		hack/setup-wif.sh --project $(PROJECT) --cluster-issuer $(ISSUER) --namespace $(NAMESPACE); \
	fi

.PHONY: setup-wif-gke
setup-wif-gke: ## GKE built-in Workload Identity. Usage: make setup-wif-gke PROJECT=xxx
	@[[ -n "$(PROJECT)" ]] || (echo "ERROR: PROJECT required" && exit 1)
	@chmod +x hack/setup-wif.sh
	@hack/setup-wif.sh --project $(PROJECT) --gke --namespace $(NAMESPACE)

.PHONY: setup-wif-kind
setup-wif-kind: ## kind cluster ADC auth. Usage: make setup-wif-kind PROJECT=xxx
	@[[ -n "$(PROJECT)" ]] || (echo "ERROR: PROJECT required" && exit 1)
	@chmod +x hack/setup-wif.sh
	@hack/setup-wif.sh --project $(PROJECT) --kind --namespace $(NAMESPACE)

# ── Kind Cluster ──────────────────────────────────────────────────────────────
.PHONY: bootstrap-kind
bootstrap-kind: ## Fresh server setup: Docker + kind + kubectl + cluster + CRDs. Usage: make bootstrap-kind [PROJECT=xxx]
	@chmod +x hack/bootstrap-kind.sh
	@hack/bootstrap-kind.sh --cluster-name $(KIND_CLUSTER)
	@if [[ -n "$(PROJECT)" ]]; then \
		echo "" && echo "Running auth setup for project $(PROJECT)..." && \
		hack/setup-auth.sh --project $(PROJECT) --env $(ENV) --namespace $(NAMESPACE); \
	fi

.PHONY: kind-create
kind-create: ## Create a local kind cluster (assumes kind is installed)
	kind get clusters | grep -q $(KIND_CLUSTER) || kind create cluster --name $(KIND_CLUSTER)

.PHONY: kind-load
kind-load: docker-build ## Build and load Docker image into kind cluster
	@# kind load is broken with overlayfs; pipe directly into containerd k8s.io namespace
	docker save $(LOCAL_IMAGE) | docker exec -i $(KIND_CLUSTER)-control-plane ctr -n k8s.io images import -
	@echo "✓ Image $(LOCAL_IMAGE) loaded into kind cluster $(KIND_CLUSTER)"

# ── Deploy ────────────────────────────────────────────────────────────────────
.PHONY: install
install: ## Install CRDs and RBAC only (no operator pod)
	kubectl apply -f deploy/00-namespace.yaml
	kubectl apply -f deploy/01-crd.yaml
	kubectl apply -f deploy/02-rbac.yaml
	@echo "✓ CRDs and RBAC installed"

.PHONY: deploy
deploy: kind-load install ## Deploy to local kind cluster (builds + loads image locally)
	kubectl apply -f deploy/03-operator.yaml
	kubectl rollout restart deployment/$(BINARY_NAME) -n $(NAMESPACE)
	kubectl rollout status deployment/$(BINARY_NAME) -n $(NAMESPACE) --timeout=90s
	@echo ""
	@echo "  ✅ Operator is running in kind!"
	@echo "  Apply an API: kubectl apply -f deploy/examples/hello-api.yaml"
	@echo "  Watch status: kubectl get aapi -w"

.PHONY: deploy-anywhere
deploy-anywhere: ## Deploy to ANY cluster via registry. Usage: make deploy-anywhere REGISTRY=gcr.io/xxx PROJECT=xxx
	@[[ -n "$(REGISTRY)" ]] || (echo "ERROR: REGISTRY required. Usage: make deploy-anywhere REGISTRY=gcr.io/my-project PROJECT=my-project" && exit 1)
	@[[ -n "$(PROJECT)" ]] || (echo "ERROR: PROJECT required" && exit 1)
	@chmod +x hack/deploy-anywhere.sh
	@hack/deploy-anywhere.sh --project $(PROJECT) --registry $(REGISTRY) --tag $(IMAGE_TAG) --env $(ENV) --namespace $(NAMESPACE)

.PHONY: deploy-wif
deploy-wif: install ## Deploy with WIF projected token manifest (run setup-wif first)
	@[[ -n "$(REGISTRY)" ]] || (echo "ERROR: REGISTRY required for remote deploy" && exit 1)
	sed "s|image: apigee-api-operator:latest|image: $(REMOTE_IMAGE)|g" \
		deploy/03-operator-wif.yaml | kubectl apply -f -
	kubectl rollout status deployment/$(BINARY_NAME) -n $(NAMESPACE) --timeout=90s

.PHONY: run-local
run-local: build install ## Run operator locally (out-of-cluster, uses your gcloud ADC)
	@echo ""
	@echo "Running operator out-of-cluster. Auth: gcloud ADC"
	@echo "Make sure: gcloud auth application-default login"
	@echo ""
	./$(BINARY_NAME) --kubeconfig ~/.kube/config -v=4

# ── Undeploy ──────────────────────────────────────────────────────────────────
.PHONY: undeploy
undeploy: ## Remove the operator from the cluster
	kubectl delete -f deploy/03-operator.yaml --ignore-not-found
	kubectl delete -f deploy/02-rbac.yaml --ignore-not-found
	kubectl delete -f deploy/01-crd.yaml --ignore-not-found
	kubectl delete -f deploy/00-namespace.yaml --ignore-not-found

.PHONY: delete-apis
delete-apis: ## Delete all ApigeeAPI CRs (triggers Apigee cleanup via finalizer)
	kubectl delete apigeeapis --all --all-namespaces --ignore-not-found

# ── Quickstart (after bootstrap-kind) ────────────────────────────────────────
.PHONY: set-project
set-project: ## Stamp your GCP project into all example YAMLs. Usage: make set-project PROJECT=my-project
	@[[ -n "$(PROJECT)" ]] || (echo "ERROR: PROJECT required" && exit 1)
	@OLD=$$(grep -h 'organization:' deploy/examples/*.yaml | head -1 | awk -F'"' '{print $$2}'); \
	 sed -i "s|organization: \"$$OLD\"|organization: \"$(PROJECT)\"|g" deploy/examples/*.yaml; \
	 echo "✓ Examples now use project: $(PROJECT)"

.PHONY: quickstart
quickstart: ## After bootstrap-kind: auth + deploy operator inside kind. Usage: make quickstart PROJECT=my-project
	@[[ -n "$(PROJECT)" ]] || (echo "ERROR: PROJECT required. Usage: make quickstart PROJECT=my-project" && exit 1)
	$(MAKE) set-project PROJECT=$(PROJECT)
	$(MAKE) setup-auth PROJECT=$(PROJECT) ENV=$(ENV)
	$(MAKE) deploy
	@echo ""
	@echo "  ✅ Operator is running inside the kind cluster!"
	@echo ""
	@echo "  Apply an API proxy:"
	@echo "     kubectl apply -f deploy/examples/hello-api.yaml"
	@echo "     kubectl get aapi -w"
	@echo ""
	@echo "  Run the demo:"
	@echo "     BASE_URL=https://YOUR_APIGEE_HOSTNAME ./demo/demo-script.sh"
	@echo ""


# ── Demo ──────────────────────────────────────────────────────────────────────
.PHONY: demo
demo: ## Apply the hello-api example and watch
	kubectl apply -f deploy/examples/hello-api.yaml
	kubectl get aapi -w

.PHONY: demo-full
demo-full: ## Full kind demo: create cluster → auth → deploy → demo. Usage: make demo-full PROJECT=xxx
	@[[ -n "$(PROJECT)" ]] || (echo "ERROR: PROJECT required" && exit 1)
	$(MAKE) kind-create
	$(MAKE) setup-auth PROJECT=$(PROJECT) ENV=$(ENV)
	$(MAKE) deploy
	$(MAKE) demo

# ── Cleanup ───────────────────────────────────────────────────────────────────
.PHONY: clean
clean: ## Remove local build artifacts
	rm -f $(BINARY_NAME)

.PHONY: kind-delete
kind-delete: ## Destroy the kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

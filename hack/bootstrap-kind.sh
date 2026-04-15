#!/usr/bin/env bash
# =============================================================================
# hack/bootstrap-kind.sh — Bootstrap a kind cluster on a fresh server
#
# What this does:
#   1. Detects OS and installs: Docker, kind, kubectl, gcloud CLI (if missing)
#   2. Creates a kind cluster with a sensible config
#   3. Exports and verifies kubeconfig
#   4. Installs the operator CRDs + RBAC into the cluster
#   5. Prints a ready-to-use connection summary
#
# Usage:
#   ./hack/bootstrap-kind.sh
#   ./hack/bootstrap-kind.sh --cluster-name my-cluster --skip-gcloud
#
# Options:
#   --cluster-name NAME   Kind cluster name (default: operator-demo)
#   --skip-gcloud         Skip gcloud CLI installation
#   --skip-docker         Skip Docker installation (assume already running)
#   --reinstall           Delete existing cluster and recreate it
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
CLUSTER_NAME="operator-demo"
SKIP_GCLOUD=false
SKIP_DOCKER=false
REINSTALL=false
NAMESPACE="apigee-api-operator-system"

# ── Colors ────────────────────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0;31m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

step()  { echo -e "\n${B}${BOLD}▶  $1${NC}"; }
ok()    { echo -e "   ${G}✓  $1${NC}"; }
warn()  { echo -e "   ${Y}⚠  $1${NC}"; }
die()   { echo -e "   ${R}✗  $1${NC}"; exit 1; }
info()  { echo -e "   ${DIM}$1${NC}"; }

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --skip-gcloud)  SKIP_GCLOUD=true;  shift ;;
        --skip-docker)  SKIP_DOCKER=true;  shift ;;
        --reinstall)    REINSTALL=true;    shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${B}${BOLD}$(printf '═%.0s' $(seq 1 56))${NC}"
echo -e "${B}${BOLD}  Bootstrap: Apigee API Operator on kind${NC}"
echo -e "${B}${BOLD}$(printf '═%.0s' $(seq 1 56))${NC}"
echo ""
info "Cluster name : $CLUSTER_NAME"
info "Namespace    : $NAMESPACE"
info "Repo root    : $REPO_DIR"
echo ""

# ── Detect OS ─────────────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]]  && ARCH_SUFFIX="amd64"
[[ "$ARCH" == "aarch64" ]] && ARCH_SUFFIX="arm64"
[[ "$ARCH" == "arm64" ]]   && ARCH_SUFFIX="arm64"

if [[ "$OS" != "Linux" && "$OS" != "Darwin" ]]; then
    die "Unsupported OS: $OS. This script supports Linux and macOS."
fi
ok "Detected OS: $OS ($ARCH / $ARCH_SUFFIX)"

# ── Helper: check if command exists ───────────────────────────────────────────
need() {
    if command -v "$1" &>/dev/null; then
        ok "$1 already installed: $(command -v "$1")"
        return 0
    fi
    return 1
}

# ── 1. Docker ─────────────────────────────────────────────────────────────────
step "Docker"
if $SKIP_DOCKER; then
    warn "Skipping Docker installation (--skip-docker)"
elif need docker; then
    if ! docker info &>/dev/null; then
        warn "Docker installed but daemon not running. Attempting to start..."
        if [[ "$OS" == "Linux" ]]; then
            sudo systemctl start docker
            sudo systemctl enable docker
            # Add current user to docker group so we don't need sudo
            sudo usermod -aG docker "$USER" 2>/dev/null || true
            ok "Docker daemon started"
            warn "You may need to log out and back in for group changes to take effect"
            warn "Or run: newgrp docker"
        fi
    else
        ok "Docker daemon is running"
    fi
else
    step "Installing Docker"
    if [[ "$OS" == "Linux" ]]; then
        info "Detected Linux — installing Docker via convenience script"
        curl -fsSL https://get.docker.com | sudo sh
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker "$USER"
        ok "Docker installed"
        warn "Added $USER to docker group. Run: newgrp docker (or re-login)"
    elif [[ "$OS" == "Darwin" ]]; then
        die "On macOS: install Docker Desktop from https://docs.docker.com/desktop/install/mac/"
    fi
fi

# Verify Docker is accessible
if ! docker info &>/dev/null; then
    # Try with sudo as fallback (before group change takes effect)
    if sudo docker info &>/dev/null; then
        warn "Docker requires sudo. Run 'newgrp docker' or re-login for passwordless access."
        DOCKER_CMD="sudo docker"
    else
        die "Docker daemon not accessible. Check installation."
    fi
else
    DOCKER_CMD="docker"
    ok "Docker accessible without sudo"
fi

# ── 2. kubectl ────────────────────────────────────────────────────────────────
step "kubectl"
if ! need kubectl; then
    info "Installing kubectl..."
    K8S_VER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSL "https://dl.k8s.io/release/${K8S_VER}/bin/${OS,,}/${ARCH_SUFFIX}/kubectl" \
        -o /tmp/kubectl
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
    ok "kubectl ${K8S_VER} installed"
fi

# ── 3. kind ───────────────────────────────────────────────────────────────────
step "kind (Kubernetes IN Docker)"
if ! need kind; then
    info "Installing kind..."
    KIND_VER="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)"
    curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VER}/kind-${OS,,}-${ARCH_SUFFIX}" \
        -o /tmp/kind
    chmod +x /tmp/kind
    sudo mv /tmp/kind /usr/local/bin/kind
    ok "kind ${KIND_VER} installed"
fi

# ── 4. gcloud CLI ─────────────────────────────────────────────────────────────
step "gcloud CLI"
if $SKIP_GCLOUD; then
    warn "Skipping gcloud installation (--skip-gcloud)"
elif need gcloud; then
    ok "gcloud already available: $(gcloud version --format='value(Google Cloud SDK)' 2>/dev/null || echo 'version unknown')"
else
    info "Installing gcloud CLI..."
    if [[ "$OS" == "Linux" ]]; then
        curl -fsSL https://sdk.cloud.google.com | bash -s -- --disable-prompts --install-dir="${HOME}"
        # Add to PATH for this session
        export PATH="${HOME}/google-cloud-sdk/bin:${PATH}"
        # Add to shell profile
        SHELL_PROFILE="${HOME}/.bashrc"
        [[ -f "${HOME}/.zshrc" ]] && SHELL_PROFILE="${HOME}/.zshrc"
        echo 'export PATH="${HOME}/google-cloud-sdk/bin:${PATH}"' >> "$SHELL_PROFILE"
        ok "gcloud installed at ${HOME}/google-cloud-sdk"
        info "Added to $SHELL_PROFILE — restart shell or: source $SHELL_PROFILE"
    elif [[ "$OS" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
            brew install --cask google-cloud-sdk
            ok "gcloud installed via Homebrew"
        else
            die "Install gcloud manually: https://cloud.google.com/sdk/docs/install"
        fi
    fi
fi

# ── 5. Create kind cluster ────────────────────────────────────────────────────
step "kind cluster: $CLUSTER_NAME"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    if $REINSTALL; then
        warn "Deleting existing cluster '$CLUSTER_NAME'..."
        kind delete cluster --name "$CLUSTER_NAME"
    else
        ok "Cluster '$CLUSTER_NAME' already exists — skipping creation"
        info "Use --reinstall to delete and recreate it"
    fi
fi

if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "Creating cluster '$CLUSTER_NAME'..."

    # Write a kind config for a single-node cluster with good defaults
    KIND_CONFIG=$(mktemp /tmp/kind-config-XXXXXX.yaml)
    cat > "$KIND_CONFIG" << KINDEOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    # Expose the API server on a stable port
    extraPortMappings:
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      - containerPort: 30443
        hostPort: 30443
        protocol: TCP
KINDEOF

    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
    rm -f "$KIND_CONFIG"
    ok "Cluster '$CLUSTER_NAME' created"
fi

# ── 6. Setup kubeconfig ───────────────────────────────────────────────────────
step "kubeconfig"

kind get kubeconfig --name "$CLUSTER_NAME" > "${HOME}/.kube/config-${CLUSTER_NAME}"
ok "Kubeconfig written to: ~/.kube/config-${CLUSTER_NAME}"

# Merge into default kubeconfig
KUBECONFIG="${HOME}/.kube/config:${HOME}/.kube/config-${CLUSTER_NAME}" \
    kubectl config view --flatten > /tmp/kubeconfig-merged
mv /tmp/kubeconfig-merged "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
ok "Merged into ~/.kube/config"

# Switch to the new cluster context
kubectl config use-context "kind-${CLUSTER_NAME}"
ok "Active context set to: kind-${CLUSTER_NAME}"

# ── 7. Verify cluster ─────────────────────────────────────────────────────────
step "Verifying cluster connectivity"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo ""
kubectl get nodes
ok "Cluster is healthy"

# ── 8. Install operator CRDs and RBAC ────────────────────────────────────────
step "Installing operator CRDs and RBAC"
kubectl apply -f "${REPO_DIR}/deploy/00-namespace.yaml"
kubectl apply -f "${REPO_DIR}/deploy/01-crd.yaml"
kubectl apply -f "${REPO_DIR}/deploy/02-rbac.yaml"
ok "CRDs and RBAC installed"

# Verify CRD is available
kubectl wait --for=condition=Established crd/apigeeapis.apigee.example.com --timeout=30s
ok "ApigeeAPI CRD is Established and ready"

# ── 9. Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${G}${BOLD}$(printf '═%.0s' $(seq 1 56))${NC}"
echo -e "${G}${BOLD}  Cluster ready!${NC}"
echo -e "${G}${BOLD}$(printf '═%.0s' $(seq 1 56))${NC}"
echo ""
echo -e "  ${BOLD}Connection:${NC}"
echo -e "  ${DIM}Context:    kind-${CLUSTER_NAME}${NC}"
echo -e "  ${DIM}Kubeconfig: ~/.kube/config${NC}"
echo ""
echo -e "  ${BOLD}Verify anytime:${NC}"
echo -e "  ${DIM}kubectl cluster-info --context kind-${CLUSTER_NAME}${NC}"
echo -e "  ${DIM}kubectl get nodes${NC}"
echo -e "  ${DIM}kubectl api-resources | grep apigee${NC}"
echo ""
echo -e "  ${BOLD}Next steps for the operator:${NC}"
echo -e "  ${DIM}1. Authenticate with GCP:${NC}"
echo -e "  ${DIM}   gcloud auth application-default login${NC}"
echo -e "  ${DIM}   ./hack/setup-auth.sh --project YOUR_PROJECT${NC}"
echo ""
echo -e "  ${DIM}2. Run the operator locally:${NC}"
echo -e "  ${DIM}   make run-local PROJECT=YOUR_PROJECT${NC}"
echo ""
echo -e "  ${DIM}3. Apply an API proxy:${NC}"
echo -e "  ${DIM}   kubectl apply -f deploy/examples/hello-api.yaml${NC}"
echo -e "  ${DIM}   kubectl get aapi -w${NC}"
echo ""

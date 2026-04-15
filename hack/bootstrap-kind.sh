#!/usr/bin/env bash
# =============================================================================
# hack/bootstrap-kind.sh — Bootstrap a kind cluster on a fresh server
#
# Installs everything needed to clone the repo, run the operator, and
# execute the demo on a brand-new Linux (Ubuntu/Debian/RHEL/Fedora) or macOS server.
#
# Full prerequisite chain:
#   curl · git · Docker · kind · kubectl · Go · gcloud CLI · python3
#   → kind cluster created → kubeconfig merged → CRDs/RBAC installed
#   → operator binary built → ready to run demo
#
# Usage:
#   ./hack/bootstrap-kind.sh
#   ./hack/bootstrap-kind.sh --cluster-name my-cluster --skip-gcloud
#
# Options:
#   --cluster-name NAME   Kind cluster name (default: operator-demo)
#   --skip-gcloud         Skip gcloud CLI installation
#   --skip-docker         Skip Docker installation (assume already running)
#   --skip-go             Skip Go installation (assume already installed)
#   --reinstall           Delete existing cluster and recreate it
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
CLUSTER_NAME="operator-demo"
SKIP_GCLOUD=false
SKIP_DOCKER=false
SKIP_GO=false
REINSTALL=false
NAMESPACE="apigee-api-operator-system"
GO_VERSION="1.22.3"   # minimum required; will skip if newer already installed

# ── Colors ────────────────────────────────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; R='\033[0;31m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

step()  { echo -e "\n${B}${BOLD}▶  $1${NC}"; }
ok()    { echo -e "   ${G}✓  $1${NC}"; }
warn()  { echo -e "   ${Y}⚠  $1${NC}"; }
die()   { echo -e "\n${R}${BOLD}✗  ERROR: $1${NC}\n"; exit 1; }
info()  { echo -e "   ${DIM}$1${NC}"; }
blank() { echo ""; }

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --skip-gcloud)  SKIP_GCLOUD=true;  shift ;;
        --skip-docker)  SKIP_DOCKER=true;  shift ;;
        --skip-go)      SKIP_GO=true;      shift ;;
        --reinstall)    REINSTALL=true;    shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Banner ────────────────────────────────────────────────────────────────────
blank
echo -e "${B}${BOLD}$(printf '═%.0s' $(seq 1 58))${NC}"
echo -e "${B}${BOLD}  Bootstrap: Apigee API Operator on kind              ${NC}"
echo -e "${B}${BOLD}$(printf '═%.0s' $(seq 1 58))${NC}"
blank
info "Cluster : $CLUSTER_NAME"
info "Namespace: $NAMESPACE"
info "Repo    : $REPO_DIR"
blank

# ── Detect OS + arch ──────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  ARCH_GO="amd64"; ARCH_KIND="amd64" ;;
    aarch64) ARCH_GO="arm64"; ARCH_KIND="arm64" ;;
    arm64)   ARCH_GO="arm64"; ARCH_KIND="arm64" ;;
    *) die "Unsupported architecture: $ARCH" ;;
esac

OS_LOWER="${OS,,}"   # linux or darwin
ok "OS: $OS | Arch: $ARCH ($ARCH_GO)"

# ── Detect package manager (Linux) ───────────────────────────────────────────
PKG_INSTALL=""
APT_UPDATED=false
if [[ "$OS" == "Linux" ]]; then
    if command -v apt-get &>/dev/null; then
        PKG_INSTALL="apt-get"
    elif command -v dnf &>/dev/null; then
        PKG_INSTALL="dnf"
    elif command -v yum &>/dev/null; then
        PKG_INSTALL="yum"
    else
        die "Unsupported Linux distro — need apt-get, dnf, or yum."
    fi
fi

# ── Helper: check if command exists ───────────────────────────────────────────
installed() { command -v "$1" &>/dev/null; }

pkg_install() {
    if [[ -z "$PKG_INSTALL" ]]; then
        die "Cannot auto-install '$*' on macOS. Install via brew or manually."
    fi
    # Update package index once before first install
    if [[ "$APT_UPDATED" == false && "$PKG_INSTALL" == "apt-get" ]]; then
        info "Running apt-get update..."
        sudo apt-get update -qq
        APT_UPDATED=true
    fi
    sudo "$PKG_INSTALL" install -y -q "$@"
}

# ── 0. Prerequisites: curl, git, python3 ─────────────────────────────────────
step "System prerequisites: curl, git, python3"

if ! installed curl; then
    info "Installing curl..."
    pkg_install curl ca-certificates
fi
ok "curl: $(curl --version | head -1)"

if ! installed git; then
    info "Installing git..."
    pkg_install git
fi
ok "git: $(git --version)"

if ! installed python3; then
    info "Installing python3..."
    pkg_install python3
fi
ok "python3: $(python3 --version)"

# ── 1. Docker ─────────────────────────────────────────────────────────────────
step "Docker"
if $SKIP_DOCKER; then
    warn "Skipping Docker installation (--skip-docker)"
elif installed docker && docker info &>/dev/null; then
    ok "Docker running: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'version unknown')"
elif installed docker; then
    info "Docker installed but daemon not running — starting..."
    if [[ "$OS" == "Linux" ]]; then
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker "$USER" 2>/dev/null || true
        # Use sg to run remaining Docker commands in the new group without re-login
        ok "Docker daemon started"
        warn "Run 'newgrp docker' or log out/in to use Docker without sudo"
    fi
else
    if [[ "$OS" == "Linux" ]]; then
        info "Installing Docker via get.docker.com..."
        curl -fsSL https://get.docker.com | sudo sh
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker "$USER" 2>/dev/null || true
        ok "Docker installed and started"
        warn "Run 'newgrp docker' or log out/in for passwordless Docker access"
    elif [[ "$OS" == "Darwin" ]]; then
        die "On macOS: install Docker Desktop from https://docs.docker.com/desktop/mac/"
    fi
fi

# Ensure Docker is usable — try with sudo if group not active yet
if installed docker; then
    if docker info &>/dev/null; then
        DOCKER="docker"
    elif sudo docker info &>/dev/null; then
        DOCKER="sudo docker"
        warn "Using 'sudo docker' — run 'newgrp docker' for passwordless access"
    else
        die "Docker installed but not reachable. Try: sudo systemctl start docker"
    fi
    ok "Docker accessible via: $DOCKER"
fi

# ── 2. Go ─────────────────────────────────────────────────────────────────────
step "Go (required to build the operator)"
if $SKIP_GO; then
    warn "Skipping Go installation (--skip-go)"
    installed go || die "Go not found and --skip-go set. Install Go $GO_VERSION+."
elif installed go; then
    CURRENT_GO="$(go version | awk '{print $3}' | tr -d 'go')"
    ok "Go already installed: $CURRENT_GO"
else
    info "Installing Go $GO_VERSION..."
    GO_TAR="go${GO_VERSION}.${OS_LOWER}-${ARCH_GO}.tar.gz"
    curl -fsSL "https://go.dev/dl/${GO_TAR}" -o "/tmp/${GO_TAR}"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "/tmp/${GO_TAR}"
    rm -f "/tmp/${GO_TAR}"

    # Add to PATH for this session
    export PATH="/usr/local/go/bin:${HOME}/go/bin:${PATH}"

    # Persist to shell profile
    PROFILE="${HOME}/.bashrc"
    [[ -f "${HOME}/.zshrc" ]] && PROFILE="${HOME}/.zshrc"
    grep -q '/usr/local/go/bin' "$PROFILE" 2>/dev/null || {
        echo 'export PATH="/usr/local/go/bin:${HOME}/go/bin:${PATH}"' >> "$PROFILE"
        info "Added Go to $PROFILE"
    }
    ok "Go $GO_VERSION installed"
fi

export PATH="/usr/local/go/bin:${HOME}/go/bin:${PATH}"
go version || die "Go installation failed — not in PATH"

# ── 3. kubectl ────────────────────────────────────────────────────────────────
step "kubectl"
if ! installed kubectl; then
    info "Installing kubectl (latest stable)..."
    K8S_VER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSL "https://dl.k8s.io/release/${K8S_VER}/bin/${OS_LOWER}/${ARCH_GO}/kubectl" \
        -o /tmp/kubectl
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
    ok "kubectl ${K8S_VER} installed"
else
    ok "kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
fi

# ── 4. kind ───────────────────────────────────────────────────────────────────
step "kind (Kubernetes IN Docker)"
if ! installed kind; then
    info "Installing kind (latest release)..."
    KIND_VER="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
        | grep '"tag_name"' | head -1 | cut -d'"' -f4)"
    curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VER}/kind-${OS_LOWER}-${ARCH_KIND}" \
        -o /tmp/kind
    chmod +x /tmp/kind
    sudo mv /tmp/kind /usr/local/bin/kind
    ok "kind ${KIND_VER} installed"
else
    ok "kind: $(kind version)"
fi

# ── 5. gcloud CLI ─────────────────────────────────────────────────────────────
step "gcloud CLI"
if $SKIP_GCLOUD; then
    warn "Skipping gcloud installation (--skip-gcloud)"
elif installed gcloud; then
    ok "gcloud already installed: $(gcloud version 2>/dev/null | head -1)"
else
    info "Installing gcloud CLI..."
    if [[ "$OS" == "Linux" ]]; then
        curl -fsSL https://sdk.cloud.google.com \
            | bash -s -- --disable-prompts --install-dir="${HOME}"
        export PATH="${HOME}/google-cloud-sdk/bin:${PATH}"
        PROFILE="${HOME}/.bashrc"
        [[ -f "${HOME}/.zshrc" ]] && PROFILE="${HOME}/.zshrc"
        grep -q 'google-cloud-sdk' "$PROFILE" 2>/dev/null || \
            echo 'export PATH="${HOME}/google-cloud-sdk/bin:${PATH}"' >> "$PROFILE"
        ok "gcloud installed → ${HOME}/google-cloud-sdk"
        info "Added to $PROFILE — restart shell or: source $PROFILE"
    elif [[ "$OS" == "Darwin" ]]; then
        if installed brew; then
            brew install --cask google-cloud-sdk
            ok "gcloud installed via Homebrew"
        else
            die "Install gcloud manually: https://cloud.google.com/sdk/docs/install"
        fi
    fi
fi
export PATH="${HOME}/google-cloud-sdk/bin:${PATH}"

# ── 6. Create kind cluster ────────────────────────────────────────────────────
step "kind cluster: $CLUSTER_NAME"

EXISTING=$(kind get clusters 2>/dev/null || true)
if echo "$EXISTING" | grep -q "^${CLUSTER_NAME}$"; then
    if $REINSTALL; then
        warn "Deleting existing cluster '$CLUSTER_NAME'..."
        kind delete cluster --name "$CLUSTER_NAME"
    else
        ok "Cluster '$CLUSTER_NAME' already exists (use --reinstall to recreate)"
    fi
fi

if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "Creating cluster '$CLUSTER_NAME'..."
    KIND_CONFIG="$(mktemp /tmp/kind-config-XXXXXX.yaml)"
    # shellcheck disable=SC2154
    cat > "$KIND_CONFIG" << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      - containerPort: 30443
        hostPort: 30443
        protocol: TCP
EOF
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
    rm -f "$KIND_CONFIG"
    ok "Cluster '$CLUSTER_NAME' created"
fi

# ── 7. kubeconfig ─────────────────────────────────────────────────────────────
step "kubeconfig"

mkdir -p "${HOME}/.kube"
chmod 700 "${HOME}/.kube"

# Export new cluster's kubeconfig to a dedicated file
kind get kubeconfig --name "$CLUSTER_NAME" > "${HOME}/.kube/config-${CLUSTER_NAME}"
ok "Written: ~/.kube/config-${CLUSTER_NAME}"

# Merge with existing ~/.kube/config (create it if it doesn't exist)
if [[ -f "${HOME}/.kube/config" ]]; then
    KUBECONFIG="${HOME}/.kube/config:${HOME}/.kube/config-${CLUSTER_NAME}" \
        kubectl config view --flatten > /tmp/kubeconfig-merged
else
    cp "${HOME}/.kube/config-${CLUSTER_NAME}" /tmp/kubeconfig-merged
fi
mv /tmp/kubeconfig-merged "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
ok "Merged into: ~/.kube/config"

# Set active context
kubectl config use-context "kind-${CLUSTER_NAME}"
ok "Active context: kind-${CLUSTER_NAME}"

# ── 8. Verify cluster ─────────────────────────────────────────────────────────
step "Verifying cluster"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
blank
kubectl get nodes
ok "Cluster healthy"

# ── 9. Install CRDs and RBAC ──────────────────────────────────────────────────
step "Installing operator CRDs and RBAC"
kubectl apply -f "${REPO_DIR}/deploy/00-namespace.yaml"
kubectl apply -f "${REPO_DIR}/deploy/01-crd.yaml"
kubectl apply -f "${REPO_DIR}/deploy/02-rbac.yaml"

# Wait for CRD to be ready before proceeding
kubectl wait --for=condition=Established \
    crd/apigeeapis.apigee.example.com --timeout=30s
ok "ApigeeAPI CRD established"

# Verify the CRD shortname works
kubectl api-resources | grep -i apigee \
    && ok "Short name 'aapi' registered" \
    || warn "CRD registered but api-resources not updated yet (normal — wait a few seconds)"

# ── 10. Build operator binary ─────────────────────────────────────────────────
step "Building operator binary"
(cd "$REPO_DIR" && go build -o apigee-api-operator . 2>&1)
ok "Binary built: ${REPO_DIR}/apigee-api-operator"

# ── 11. Final summary ─────────────────────────────────────────────────────────
blank
echo -e "${G}${BOLD}$(printf '═%.0s' $(seq 1 58))${NC}"
echo -e "${G}${BOLD}  All done! Cluster is ready.${NC}"
echo -e "${G}${BOLD}$(printf '═%.0s' $(seq 1 58))${NC}"
blank

echo -e "  ${BOLD}What was installed / verified:${NC}"
echo -e "  ${G}✓${NC}  curl, git, python3"
echo -e "  ${G}✓${NC}  Docker  ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'running'))"
echo -e "  ${G}✓${NC}  Go      ($(go version | awk '{print $3}'))"
echo -e "  ${G}✓${NC}  kubectl ($(kubectl version --client --short 2>/dev/null | awk '{print $3}' || echo 'installed'))"
echo -e "  ${G}✓${NC}  kind    ($(kind version | awk '{print $2}'))"
$SKIP_GCLOUD || echo -e "  ${G}✓${NC}  gcloud  ($(gcloud version 2>/dev/null | head -1 || echo 'installed'))"
echo -e "  ${G}✓${NC}  Cluster: kind-${CLUSTER_NAME}"
echo -e "  ${G}✓${NC}  Operator binary built"
blank

echo -e "  ${BOLD}Next steps:${NC}"
blank
echo -e "  ${B}Step 1${NC} — Authenticate with GCP (run this as the current user):"
echo -e "  ${DIM}  gcloud auth application-default login${NC}"
blank
echo -e "  ${B}Step 2${NC} — Set up auth secret in the cluster:"
echo -e "  ${DIM}  cd ${REPO_DIR}${NC}"
echo -e "  ${DIM}  ./hack/setup-auth.sh --project YOUR_GCP_PROJECT${NC}"
blank
echo -e "  ${B}Step 3${NC} — Run the operator (in a separate terminal):"
echo -e "  ${DIM}  cd ${REPO_DIR}${NC}"
echo -e "  ${DIM}  ./apigee-api-operator --kubeconfig ~/.kube/config -v=2${NC}"
blank
echo -e "  ${B}Step 4${NC} — Apply an API and watch it deploy:"
echo -e "  ${DIM}  kubectl apply -f deploy/examples/hello-api.yaml${NC}"
echo -e "  ${DIM}  kubectl get aapi -w${NC}"
blank
echo -e "  ${B}Step 5${NC} — Run the demo:"
echo -e "  ${DIM}  cd ${REPO_DIR}${NC}"
echo -e "  ${DIM}  BASE_URL=https://YOUR_APIGEE_HOSTNAME ./demo/demo-script.sh${NC}"
blank

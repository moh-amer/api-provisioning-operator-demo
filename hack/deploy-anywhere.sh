#!/usr/bin/env bash
# =============================================================================
# deploy-anywhere.sh — Deploy the Apigee Operator to ANY Kubernetes cluster
#
# Handles the full pipeline:
#   1. Build Docker image
#   2. Push to a container registry (GCR / Docker Hub / ECR / any registry)
#   3. Set up GCP authentication (auto-detects cluster type)
#   4. Deploy CRDs, RBAC, and the operator to the cluster
#
# Usage:
#   ./hack/deploy-anywhere.sh --project my-project --registry gcr.io/my-project
#   ./hack/deploy-anywhere.sh --project my-project --registry docker.io/myuser
#   ./hack/deploy-anywhere.sh --project my-project --registry ghcr.io/myuser
#
# Registry auto-options:
#   GCR (Google):   gcr.io/YOUR_PROJECT
#   Artifact Reg:   REGION-docker.pkg.dev/YOUR_PROJECT/REPO
#   Docker Hub:     docker.io/YOUR_DOCKERHUB_USERNAME
#   GitHub:         ghcr.io/YOUR_GITHUB_USERNAME
# =============================================================================
set -euo pipefail
export PATH="${HOME}/.local/bin:${HOME}/bin:/snap/bin:/usr/local/bin:/usr/local/go/bin:${PATH}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}━━ $* ━━${NC}\n"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT_ID=""
REGISTRY=""
IMAGE_TAG="latest"
NAMESPACE="apigee-api-operator-system"
APIGEE_ENV="eval"
SKIP_BUILD=false
SKIP_AUTH=false

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    PROJECT_ID="$2";   shift 2 ;;
    --registry)   REGISTRY="$2";     shift 2 ;;
    --tag)        IMAGE_TAG="$2";    shift 2 ;;
    --env)        APIGEE_ENV="$2";   shift 2 ;;
    --namespace)  NAMESPACE="$2";    shift 2 ;;
    --skip-build) SKIP_BUILD=true;   shift   ;;
    --skip-auth)  SKIP_AUTH=true;    shift   ;;
    --help|-h)
      echo "Usage: $0 --project <GCP_PROJECT> --registry <IMAGE_REGISTRY>"
      echo ""
      echo "Options:"
      echo "  --project     GCP project ID (required)"
      echo "  --registry    Container registry base URL (required)"
      echo "  --tag         Image tag (default: latest)"
      echo "  --env         Apigee environment (default: eval)"
      echo "  --namespace   K8s namespace (default: apigee-api-operator-system)"
      echo "  --skip-build  Skip docker build+push (use existing image)"
      echo "  --skip-auth   Skip GCP auth setup (already done)"
      echo ""
      echo "Registry examples:"
      echo "  gcr.io/my-project                               # Google Container Registry"
      echo "  us-docker.pkg.dev/my-project/apigee-operator    # Google Artifact Registry"
      echo "  docker.io/myusername                            # Docker Hub"
      echo "  ghcr.io/myusername                              # GitHub Container Registry"
      exit 0
      ;;
    *) error "Unknown argument: $1 (run with --help for usage)" ;;
  esac
done

[[ -z "$PROJECT_ID" ]] && error "Required: --project <GCP_PROJECT_ID>"
[[ -z "$REGISTRY"   ]] && error "Required: --registry <IMAGE_REGISTRY>

Registry examples:
  GCR:              gcr.io/${PROJECT_ID}
  Artifact Registry: us-docker.pkg.dev/${PROJECT_ID}/apigee-operator
  Docker Hub:       docker.io/your-username
  GitHub:           ghcr.io/your-username"

FULL_IMAGE="${REGISTRY}/apigee-api-operator:${IMAGE_TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
header "Pre-flight Checks"
command -v docker  &>/dev/null || error "docker not found"
command -v kubectl &>/dev/null || error "kubectl not found"
command -v gcloud  &>/dev/null || error "gcloud not found"

CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
[[ "$CURRENT_CONTEXT" == "none" ]] && error "No kubectl context found. Point kubectl at your cluster first."
success "kubectl context: ${CURRENT_CONTEXT}"
success "Target image:   ${FULL_IMAGE}"
success "Namespace:      ${NAMESPACE}"

# ── Step 1: Build & Push Docker Image ─────────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]]; then
  header "Build & Push Docker Image"
  cd "$REPO_ROOT"

  info "Building image: ${FULL_IMAGE}"
  docker build -t "apigee-api-operator:${IMAGE_TAG}" -t "${FULL_IMAGE}" .
  success "Image built"

  # Auto-configure registry auth based on the registry type
  if echo "$REGISTRY" | grep -qE "gcr.io|pkg.dev"; then
    info "Configuring GCR/Artifact Registry authentication..."
    gcloud auth configure-docker "$(echo "$REGISTRY" | cut -d'/' -f1)" --quiet
  elif echo "$REGISTRY" | grep -q "ghcr.io"; then
    warn "GitHub Container Registry: ensure you are logged in with: echo \$GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin"
  else
    info "Ensure you are logged in with: docker login $(echo "$REGISTRY" | cut -d'/' -f1)"
  fi

  info "Pushing image to registry..."
  docker push "${FULL_IMAGE}"
  success "Image pushed: ${FULL_IMAGE}"
else
  info "Skipping build (--skip-build)"
fi

# ── Step 2: Set Up GCP Authentication ─────────────────────────────────────────
if [[ "$SKIP_AUTH" == "false" ]]; then
  header "GCP Authentication Setup"
  chmod +x "${SCRIPT_DIR}/setup-auth.sh"
  "${SCRIPT_DIR}/setup-auth.sh" \
    --project "$PROJECT_ID" \
    --env "$APIGEE_ENV" \
    --namespace "$NAMESPACE"
else
  info "Skipping auth setup (--skip-auth)"
fi

# ── Step 3: Install CRDs and RBAC ─────────────────────────────────────────────
header "Installing CRDs and RBAC"
cd "$REPO_ROOT"

kubectl apply -f deploy/00-namespace.yaml
kubectl apply -f deploy/01-crd.yaml
kubectl apply -f deploy/02-rbac.yaml
success "CRDs and RBAC installed"

# ── Step 4: Deploy the Operator ───────────────────────────────────────────────
header "Deploying Operator"

# Patch the image reference from local to remote registry
info "Deploying with image: ${FULL_IMAGE}"
sed "s|image: apigee-api-operator:latest|image: ${FULL_IMAGE}|g" \
  deploy/03-operator.yaml | kubectl apply -f -

info "Waiting for operator to become ready..."
kubectl rollout status deployment/apigee-api-operator \
  -n "$NAMESPACE" --timeout=120s
success "Operator is running!"

# ── Step 5: Verify ───────────────────────────────────────────────────────────
header "Verification"
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅  Operator deployed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Cluster:   ${CURRENT_CONTEXT}"
echo "  Image:     ${FULL_IMAGE}"
echo "  Namespace: ${NAMESPACE}"
echo ""
echo "  Next — create your first API proxy:"
echo ""
echo "    # Edit the org and environment first:"
echo "    sed -i 's/your-gcp-project-id/${PROJECT_ID}/' deploy/examples/hello-api.yaml"
echo "    kubectl apply -f deploy/examples/hello-api.yaml"
echo "    kubectl get aapi -w"
echo ""
echo "  View operator logs:"
echo "    kubectl logs -l app=apigee-api-operator -n ${NAMESPACE} -f"
echo ""

#!/usr/bin/env bash
# =============================================================================
# setup-auth.sh — Automates GCP authentication for the Apigee API Operator
#
# Supports two modes automatically:
#   1. GKE Cluster       → Workload Identity (keyless, most secure)
#   2. Any other cluster → SA key injected as K8s Secret, local file auto-deleted
#
# Usage:
#   ./hack/setup-auth.sh --project <GCP_PROJECT_ID> [--env eval] [--namespace apigee-api-operator-system]
# =============================================================================
set -euo pipefail

# Expand PATH to include common user-local install locations
export PATH="${HOME}/.local/bin:${HOME}/bin:/snap/bin:/usr/local/bin:${PATH}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT_ID=""
ENVIRONMENT="eval"
NAMESPACE="apigee-api-operator-system"
SA_NAME="apigee-operator-sa"
K8S_SA_NAME="apigee-api-operator"    # Must match deploy/02-rbac.yaml
SECRET_NAME="apigee-sa-key"
TEMP_KEY_FILE="$(mktemp /tmp/apigee-sa-key-XXXXXX.json)"

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)   PROJECT_ID="$2";   shift 2 ;;
    --env)       ENVIRONMENT="$2";  shift 2 ;;
    --namespace) NAMESPACE="$2";    shift 2 ;;
    *) error "Unknown argument: $1. Usage: $0 --project <PROJECT_ID> [--env eval] [--namespace apigee-api-operator-system]" ;;
  esac
done

[[ -z "$PROJECT_ID" ]] && error "Missing required argument: --project <GCP_PROJECT_ID>"

FULL_SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
info "Running pre-flight checks..."
command -v gcloud  &>/dev/null || error "gcloud CLI not found. Install it: https://cloud.google.com/sdk/docs/install"
command -v kubectl &>/dev/null || error "kubectl not found."

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)
[[ -z "$ACTIVE_ACCOUNT" ]] && error "Not logged in to gcloud. Run: gcloud auth login"
success "Authenticated as: ${ACTIVE_ACCOUNT}"

# ── Detect Cluster Type (GKE vs Other) ───────────────────────────────────────
CLUSTER_TYPE="other"
CLUSTER_NAME=$(kubectl config current-context 2>/dev/null || echo "unknown")
info "Current kube context: ${CLUSTER_NAME}"

if kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -q "gce://"; then
  CLUSTER_TYPE="gke"
  GKE_CLUSTER_NAME=$(kubectl config current-context | sed 's/gke_[^_]*_[^_]*_//')
  GKE_LOCATION=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "")
  info "Detected: GKE cluster — will use Workload Identity (keyless)"
else
  info "Detected: Non-GKE cluster (kind/EKS/AKS/etc.) — will use SA key Secret"
fi

# ── Ensure GCP APIs are enabled ───────────────────────────────────────────────
info "Enabling required GCP APIs..."
gcloud services enable apigee.googleapis.com --project="$PROJECT_ID" --quiet 2>/dev/null || \
  warn "Could not enable Apigee API (may already be enabled)"

# ── Create Service Account ────────────────────────────────────────────────────
info "Setting up GCP Service Account: ${FULL_SA}"
if gcloud iam service-accounts describe "$FULL_SA" --project="$PROJECT_ID" &>/dev/null; then
  success "Service account already exists."
else
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Apigee Kubernetes Operator" \
    --project="$PROJECT_ID"
  success "Created service account."
fi

# ── Grant IAM Roles ───────────────────────────────────────────────────────────
info "Granting IAM roles to ${FULL_SA}..."
for ROLE in "roles/apigee.environmentAdmin" "roles/apigee.apiAdmin"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${FULL_SA}" \
    --role="$ROLE" \
    --quiet 2>/dev/null
  success "Granted: $ROLE"
done

# ── Create K8s Namespace ──────────────────────────────────────────────────────
info "Ensuring namespace: ${NAMESPACE}"
kubectl get namespace "$NAMESPACE" &>/dev/null || \
  kubectl create namespace "$NAMESPACE"
success "Namespace ready."

# ── Mode A: GKE — Workload Identity (Keyless) ────────────────────────────────
if [[ "$CLUSTER_TYPE" == "gke" ]]; then
  echo ""
  info "━━ GKE MODE: Setting up Workload Identity (no keys!) ━━"

  # Allow K8s SA to impersonate GCP SA
  gcloud iam service-accounts add-iam-policy-binding "$FULL_SA" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${K8S_SA_NAME}]" \
    --project="$PROJECT_ID" --quiet

  # Annotate the K8s Service Account
  kubectl annotate serviceaccount "$K8S_SA_NAME" \
    --namespace "$NAMESPACE" \
    "iam.gke.io/gcp-service-account=${FULL_SA}" \
    --overwrite 2>/dev/null || true

  success "Workload Identity configured! The operator will authenticate automatically on GKE."

# ── Mode B: Non-GKE — SA Key Secret (auto-cleanup) ───────────────────────────
else
  echo ""
  info "━━ PORTABLE MODE: Creating SA key → K8s Secret → deleting local file ━━"

  # Check if creating keys is allowed
  if ! gcloud iam service-accounts keys create "$TEMP_KEY_FILE" \
      --iam-account="$FULL_SA" \
      --project="$PROJECT_ID" 2>/dev/null; then
    warn "SA key creation blocked by org policy."
    warn "Falling back to Application Default Credentials (your gcloud login)."
    info "Creating ADC-based secret from your current gcloud session..."

    # Use user's ADC token to create a credentials secret
    gcloud auth application-default print-access-token &>/dev/null || \
      error "ADC not set up. Run: gcloud auth application-default login"

    # Create a credentials.json pointing to ADC
    ADC_FILE="${HOME}/.config/gcloud/application_default_credentials.json"
    [[ -f "$ADC_FILE" ]] || error "ADC file not found. Run: gcloud auth application-default login"

    kubectl create secret generic "$SECRET_NAME" \
      --from-file=key.json="$ADC_FILE" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
    success "Created K8s secret from ADC credentials."
  else
    # SA key was created successfully — load into K8s and delete local file
    kubectl create secret generic "$SECRET_NAME" \
      --from-file=key.json="$TEMP_KEY_FILE" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -

    rm -f "$TEMP_KEY_FILE"
    success "Loaded SA key into K8s secret and deleted local file (no keys on disk!)."
  fi
fi

# ── Final Summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅  Authentication setup complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Project:   ${PROJECT_ID}"
echo "  Env:       ${ENVIRONMENT}"
echo "  Mode:      ${CLUSTER_TYPE^^}"
echo "  Namespace: ${NAMESPACE}"
echo ""
echo "  Next steps:"
echo "    make deploy                   # Deploy the operator"
echo "    kubectl apply -f deploy/examples/hello-api.yaml"
echo "    kubectl get aapi -w           # Watch it in action!"
echo ""

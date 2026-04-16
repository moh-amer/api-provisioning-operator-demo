#!/usr/bin/env bash
# =============================================================================
# setup-auth.sh — GCP authentication for the Apigee API Operator
#
# Modes (auto-detected or forced):
#
#   GKE cluster       → Workload Identity (keyless, most secure)
#   Non-GKE cluster   → SA key injected as K8s Secret, local file deleted
#   --adc-only        → Use existing ADC file only, skip all GCP IAM work.
#                       Use this on GCP VMs or when GCP resources already exist.
#
# Usage:
#   ./hack/setup-auth.sh --project PROJECT_ID
#   ./hack/setup-auth.sh --project PROJECT_ID --adc-only
# =============================================================================
set -euo pipefail

export PATH="${HOME}/.local/bin:${HOME}/bin:/snap/bin:/usr/local/bin:${PATH}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\\033[0;31m'; GREEN='\\033[0;32m'; YELLOW='\\033[1;33m'; BLUE='\\033[0;34m'; NC='\\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT_ID=""
ENVIRONMENT="eval"
NAMESPACE="apigee-api-operator-system"
SA_NAME="apigee-operator-sa"
K8S_SA_NAME="apigee-api-operator"
SECRET_NAME="apigee-sa-key"
ADC_ONLY=false
TEMP_KEY_FILE="$(mktemp /tmp/apigee-sa-key-XXXXXX.json)"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    PROJECT_ID="$2";   shift 2 ;;
    --env)        ENVIRONMENT="$2";  shift 2 ;;
    --namespace)  NAMESPACE="$2";    shift 2 ;;
    --adc-only)   ADC_ONLY=true;     shift ;;
    *) error "Unknown argument: $1
    Usage: $0 --project PROJECT_ID [--env eval] [--namespace NAMESPACE] [--adc-only]" ;;
  esac
done

[[ -z "$PROJECT_ID" ]] && error "Missing required argument: --project PROJECT_ID"

FULL_SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
info "Running pre-flight checks..."
command -v gcloud  &>/dev/null || error "gcloud CLI not found. Run: ./hack/bootstrap-kind.sh"
command -v kubectl &>/dev/null || error "kubectl not found."

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)

# ── Detect Compute Engine service account (GCP VM with no user auth) ──────────
if [[ "$ACTIVE_ACCOUNT" == *"-compute@developer.gserviceaccount.com" ]] || \
   [[ "$ACTIVE_ACCOUNT" == *"@developer.gserviceaccount.com" ]]; then
  warn "Active account is a Compute Engine service account: ${ACTIVE_ACCOUNT}"
  warn "This account cannot create IAM resources or enable GCP APIs."
  echo ""
  echo -e "${YELLOW}  You have two options:${NC}"
  echo ""
  echo -e "  ${BLUE}Option A${NC} — Authenticate as your own user (recommended):"
  echo "    gcloud auth login --no-launch-browser"
  echo "    gcloud auth application-default login --no-launch-browser"
  echo "    Then re-run this script."
  echo ""
  echo -e "  ${BLUE}Option B${NC} — Use existing ADC only (if ADC is already configured):"
  echo "    ./hack/setup-auth.sh --project ${PROJECT_ID} --adc-only"
  echo ""
  if [[ "$ADC_ONLY" == false ]]; then
    error "Re-run with --adc-only or authenticate as a user first."
  fi
fi

if [[ -z "$ACTIVE_ACCOUNT" ]]; then
  error "Not authenticated with gcloud.
  Run: gcloud auth login --no-launch-browser
  Then: gcloud auth application-default login --no-launch-browser"
fi
success "Authenticated as: ${ACTIVE_ACCOUNT}"

# ── Ensure K8s namespace exists ───────────────────────────────────────────────
info "Ensuring namespace: ${NAMESPACE}"
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"
success "Namespace ready."

# ═════════════════════════════════════════════════════════════════════════════
# ADC-ONLY MODE — skip all GCP IAM work, just read existing ADC → K8s Secret
# Use this when: GCP VM, existing GCP setup, org policy blocks SA keys
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$ADC_ONLY" == true ]]; then
  echo ""
  info "━━ ADC-ONLY MODE: Reading existing credentials → K8s Secret ━━"
  echo ""

  ADC_FILE="${HOME}/.config/gcloud/application_default_credentials.json"

  # On a GCP VM the ADC may come from the metadata server (no local file).
  # In that case we write out the ADC-style creds file by calling gcloud.
  if [[ ! -f "$ADC_FILE" ]]; then
    warn "No ADC file found at ${ADC_FILE}"
    info "Attempting to generate credentials from active account..."

    # If running as a Compute Engine SA, write an external_account style credential
    if gcloud auth application-default print-access-token &>/dev/null 2>&1; then
      # GCE metadata server ADC works — write a credential_source pointing to it
      mkdir -p "${HOME}/.config/gcloud"
      cat > "$ADC_FILE" << ADCEOF
{
  "type": "external_account",
  "audience": "//iam.googleapis.com/projects/${PROJECT_ID}",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_url": "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
  "credential_source": {
    "url": "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
    "headers": {"Metadata-Flavor": "Google"},
    "format": {"type": "json", "subject_token_field_name": "access_token"}
  }
}
ADCEOF
      warn "Generated metadata-server ADC file. This works only on GCP VMs."
      warn "For production, use 'gcloud auth application-default login' as a real user."
    else
      error "No ADC available.
  Run: gcloud auth application-default login --no-launch-browser
  Then: ./hack/setup-auth.sh --project ${PROJECT_ID} --adc-only"
    fi
  fi

  [[ -f "$ADC_FILE" ]] || error "ADC file not found: ${ADC_FILE}"
  success "Found ADC credentials: ${ADC_FILE}"

  kubectl create secret generic "$SECRET_NAME" \
    --from-file=key.json="$ADC_FILE" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  success "K8s secret '${SECRET_NAME}' created from ADC."

  echo ""
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}  ✅  Auth setup complete (ADC-only mode)!${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo "  Secret : ${SECRET_NAME} (in ${NAMESPACE})"
  echo "  Source : ADC — ${ADC_FILE}"
  echo ""
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# FULL MODE — create/verify GCP SA, grant IAM roles, create SA key → Secret
# ═════════════════════════════════════════════════════════════════════════════

# ── Detect cluster type ───────────────────────────────────────────────────────
CLUSTER_TYPE="other"
CLUSTER_NAME=$(kubectl config current-context 2>/dev/null || echo "unknown")
info "Current kube context: ${CLUSTER_NAME}"

if kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -q "gce://"; then
  CLUSTER_TYPE="gke"
  info "Detected: GKE cluster — will use Workload Identity (keyless)"
else
  info "Detected: Non-GKE cluster (kind/EKS/etc.) — will use SA key Secret"
fi

# ── Enable required GCP APIs ──────────────────────────────────────────────────
info "Enabling required GCP APIs..."
gcloud services enable apigee.googleapis.com iam.googleapis.com \
  --project="$PROJECT_ID" --quiet 2>/dev/null || \
  warn "Could not enable APIs (may already be enabled, or insufficient permissions)"

# ── Create GCP Service Account ────────────────────────────────────────────────
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

# ── Mode A: GKE — Workload Identity ──────────────────────────────────────────
if [[ "$CLUSTER_TYPE" == "gke" ]]; then
  echo ""
  info "━━ GKE MODE: Setting up Workload Identity (no keys!) ━━"

  gcloud iam service-accounts add-iam-policy-binding "$FULL_SA" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${K8S_SA_NAME}]" \
    --project="$PROJECT_ID" --quiet

  kubectl annotate serviceaccount "$K8S_SA_NAME" \
    --namespace "$NAMESPACE" \
    "iam.gke.io/gcp-service-account=${FULL_SA}" \
    --overwrite 2>/dev/null || true

  success "Workload Identity configured."

# ── Mode B: Non-GKE — SA key → K8s Secret ───────────────────────────────────
else
  echo ""
  info "━━ PORTABLE MODE: SA key → K8s Secret (local file auto-deleted) ━━"

  if ! gcloud iam service-accounts keys create "$TEMP_KEY_FILE" \
      --iam-account="$FULL_SA" \
      --project="$PROJECT_ID" 2>/dev/null; then
    warn "SA key creation blocked (org policy or permissions)."
    warn "Falling back to ADC..."
    ADC_FILE="${HOME}/.config/gcloud/application_default_credentials.json"
    [[ -f "$ADC_FILE" ]] || error "ADC file not found. Run:
  gcloud auth application-default login --no-launch-browser
  or re-run with: ./hack/setup-auth.sh --project ${PROJECT_ID} --adc-only"

    kubectl create secret generic "$SECRET_NAME" \
      --from-file=key.json="$ADC_FILE" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
    success "Created K8s secret from ADC."
  else
    kubectl create secret generic "$SECRET_NAME" \
      --from-file=key.json="$TEMP_KEY_FILE" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
    rm -f "$TEMP_KEY_FILE"
    success "Loaded SA key into K8s secret (local file deleted)."
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅  Authentication setup complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Project:   ${PROJECT_ID}"
echo "  Mode:      ${CLUSTER_TYPE^^}"
echo "  Namespace: ${NAMESPACE}"
echo ""
echo "  Next: make deploy"
echo ""

#!/usr/bin/env bash
# =============================================================================
# setup-wif.sh — Configure Workload Identity Federation for the Apigee Operator
#
# This enables keyless authentication from ANY Kubernetes cluster to GCP.
# No JSON keys. No secrets. A K8s ServiceAccount token is exchanged for a
# short-lived GCP access token at runtime via GCP's Secure Token Service.
#
# Supported clusters:
#   ✅ GKE         — Uses built-in Workload Identity (different, simpler path)
#   ✅ EKS (AWS)   — Full WIF via cluster OIDC issuer
#   ✅ AKS (Azure) — Full WIF via cluster OIDC issuer
#   ✅ Any cluster with a PUBLIC OIDC issuer endpoint
#   ⚠️  kind       — Requires extra setup (see --kind flag)
#
# Usage:
#   ./hack/setup-wif.sh --project MY_PROJECT --cluster-issuer https://oidc.eks.amazonaws.com/id/XXXX
#   ./hack/setup-wif.sh --project MY_PROJECT --gke                    # GKE path
#   ./hack/setup-wif.sh --project MY_PROJECT --kind                   # kind (uses ADC secret)
#
# What it creates in GCP:
#   - Workload Identity Pool: "apigee-operator-pool"
#   - OIDC Provider in the pool pointing to your cluster's issuer
#   - IAM binding: K8s SA → GCP SA (via the pool)
#   - credentials.json config (NOT a key — just config telling ADC how to exchange tokens)
#
# What it creates in Kubernetes:
#   - ConfigMap with credentials.json config
#   - Namespace (if missing)
# =============================================================================
set -euo pipefail
export PATH="${HOME}/.local/bin:${HOME}/bin:/snap/bin:/usr/local/bin:${PATH}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}━━ $* ━━${NC}\n"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT_ID=""
CLUSTER_ISSUER=""
NAMESPACE="apigee-api-operator-system"
SA_NAME="apigee-operator-sa"
K8S_SA_NAME="apigee-api-operator"
POOL_ID="apigee-operator-pool"
PROVIDER_ID="k8s-provider"
MODE="wif"  # wif | gke | kind

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)        PROJECT_ID="$2";      shift 2 ;;
    --cluster-issuer) CLUSTER_ISSUER="$2";  shift 2 ;;
    --namespace)      NAMESPACE="$2";       shift 2 ;;
    --pool-id)        POOL_ID="$2";         shift 2 ;;
    --gke)            MODE="gke";           shift   ;;
    --kind)           MODE="kind";          shift   ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -z "$PROJECT_ID" ]] && error "Required: --project <GCP_PROJECT_ID>"

FULL_SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null) \
  || error "Cannot get project number. Is gcloud logged in and project correct?"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
header "Pre-flight Checks"
command -v gcloud  &>/dev/null || error "gcloud not found"
command -v kubectl &>/dev/null || error "kubectl not found"
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)
[[ -z "$ACTIVE_ACCOUNT" ]] && error "Not logged in. Run: gcloud auth login"
success "gcloud authenticated as: ${ACTIVE_ACCOUNT}"
success "Project: ${PROJECT_ID} (number: ${PROJECT_NUMBER})"

# ── Ensure GCP Service Account exists ────────────────────────────────────────
header "GCP Service Account"
if gcloud iam service-accounts describe "$FULL_SA" --project="$PROJECT_ID" &>/dev/null; then
  success "Service account already exists: ${FULL_SA}"
else
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Apigee Kubernetes Operator" \
    --project="$PROJECT_ID"
  success "Created: ${FULL_SA}"
fi

# ── Grant IAM Roles ───────────────────────────────────────────────────────────
header "IAM Roles"
for ROLE in "roles/apigee.environmentAdmin" "roles/apigee.apiAdmin"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${FULL_SA}" \
    --role="$ROLE" --quiet 2>/dev/null
  success "Granted: $ROLE"
done

# ── Ensure K8s Namespace ──────────────────────────────────────────────────────
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"

# =============================================================================
# MODE: GKE — Built-in Workload Identity
# =============================================================================
if [[ "$MODE" == "gke" ]]; then
  header "GKE Workload Identity (Built-in)"

  # Bind K8s SA → GCP SA
  gcloud iam service-accounts add-iam-policy-binding "$FULL_SA" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${K8S_SA_NAME}]" \
    --project="$PROJECT_ID" --quiet

  # Annotate K8s SA
  kubectl annotate serviceaccount "$K8S_SA_NAME" \
    --namespace "$NAMESPACE" \
    "iam.gke.io/gcp-service-account=${FULL_SA}" \
    --overwrite 2>/dev/null || true

  success "GKE Workload Identity configured!"
  echo ""
  echo "The operator will now authenticate automatically on GKE."
  echo "No secrets, no credentials files needed."
  exit 0
fi

# =============================================================================
# MODE: kind — Local development (ADC secret fallback)
# =============================================================================
if [[ "$MODE" == "kind" ]]; then
  header "kind Cluster — ADC Credentials Secret"
  warn "kind clusters do not expose a public OIDC endpoint — WIF is not possible."
  warn "Using Application Default Credentials (your gcloud login) instead."
  echo ""

  ADC_FILE="${HOME}/.config/gcloud/application_default_credentials.json"
  if [[ ! -f "$ADC_FILE" ]]; then
    error "ADC file not found. Run: gcloud auth application-default login"
  fi

  kubectl create secret generic apigee-sa-key \
    --from-file=key.json="$ADC_FILE" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  success "ADC credentials injected as K8s secret 'apigee-sa-key'"
  echo ""
  echo "Your gcloud login credentials are now available inside the cluster."
  echo "The operator reads them via GOOGLE_APPLICATION_CREDENTIALS env var."
  exit 0
fi

# =============================================================================
# MODE: wif — Workload Identity Federation (any cluster with public OIDC)
# =============================================================================
header "Workload Identity Federation Setup"

# ── Auto-detect OIDC issuer if not provided ───────────────────────────────────
if [[ -z "$CLUSTER_ISSUER" ]]; then
  info "Auto-detecting cluster OIDC issuer..."
  CLUSTER_ISSUER=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])" 2>/dev/null || echo "")

  if [[ -z "$CLUSTER_ISSUER" ]]; then
    error "Could not auto-detect OIDC issuer. Provide it with --cluster-issuer <URL>
    
  How to find your issuer:
    EKS:  kubectl get --raw /.well-known/openid-configuration | python3 -c \"import sys,json;print(json.load(sys.stdin)['issuer'])\"
    AKS:  az aks show -n CLUSTER -g RG --query 'oidcIssuerProfile.issuerUrl'
    kind: kind does not support WIF — use --kind flag instead"
  fi
fi

success "OIDC Issuer: ${CLUSTER_ISSUER}"

# ── Enable required GCP APIs ──────────────────────────────────────────────────
info "Enabling GCP APIs..."
gcloud services enable iamcredentials.googleapis.com sts.googleapis.com \
  --project="$PROJECT_ID" --quiet

# ── Create Workload Identity Pool ─────────────────────────────────────────────
header "Workload Identity Pool"
if gcloud iam workload-identity-pools describe "$POOL_ID" \
    --location="global" --project="$PROJECT_ID" &>/dev/null; then
  success "Pool already exists: ${POOL_ID}"
else
  gcloud iam workload-identity-pools create "$POOL_ID" \
    --location="global" \
    --display-name="Apigee Operator K8s Pool" \
    --description="Allows Kubernetes pods to authenticate to GCP without keys" \
    --project="$PROJECT_ID"
  success "Created pool: ${POOL_ID}"
fi

# ── Create OIDC Provider in Pool ──────────────────────────────────────────────
header "OIDC Provider"
PROVIDER_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"

if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --workload-identity-pool="$POOL_ID" \
    --location="global" --project="$PROJECT_ID" &>/dev/null; then
  success "Provider already exists: ${PROVIDER_ID}"
else
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --workload-identity-pool="$POOL_ID" \
    --location="global" \
    --issuer-uri="$CLUSTER_ISSUER" \
    --attribute-mapping="google.subject=assertion.sub,attribute.namespace=assertion['kubernetes.io']['namespace'],attribute.service_account=assertion['kubernetes.io']['serviceaccount']['name']" \
    --attribute-condition="attribute.namespace == '${NAMESPACE}' && attribute.service_account == '${K8S_SA_NAME}'" \
    --project="$PROJECT_ID"
  success "Created OIDC provider pointing to: ${CLUSTER_ISSUER}"
fi

# ── Bind K8s SA to GCP SA via the pool ───────────────────────────────────────
header "IAM Binding (K8s SA → GCP SA)"
PRINCIPAL="principalSet://iam.googleapis.com/${PROVIDER_NAME}/attribute.service_account/${K8S_SA_NAME}"

gcloud iam service-accounts add-iam-policy-binding "$FULL_SA" \
  --role="roles/iam.workloadIdentityUser" \
  --member="${PRINCIPAL}" \
  --project="$PROJECT_ID" --quiet
success "Bound K8s SA '${K8S_SA_NAME}' → GCP SA '${FULL_SA}'"

# ── Generate credentials.json config (NOT a key — just routing config) ────────
header "Credentials Config"
CREDS_CONFIG_FILE="$(mktemp /tmp/wif-creds-XXXXXX.json)"
cat > "$CREDS_CONFIG_FILE" << CREDSEOF
{
  "type": "external_account",
  "audience": "//iam.googleapis.com/${PROVIDER_NAME}",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_url": "https://sts.googleapis.com/v1/token",
  "credential_source": {
    "file": "/var/run/service-account/token",
    "format": {
      "type": "text"
    }
  },
  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${FULL_SA}:generateAccessToken"
}
CREDSEOF

# ── Inject config into cluster as a ConfigMap ─────────────────────────────────
kubectl create configmap apigee-wif-config \
  --from-file=credentials.json="$CREDS_CONFIG_FILE" \
  --namespace="$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f "$CREDS_CONFIG_FILE"
success "Injected WIF credentials config as K8s ConfigMap 'apigee-wif-config'"

# ── Print next step: apply the WIF-enabled deployment manifest ────────────────
header "Next Steps"
echo -e "${GREEN}✅ Workload Identity Federation is configured!${NC}"
echo ""
echo "  Deploy the operator with WIF support:"
echo "    kubectl apply -f deploy/"
echo "    kubectl apply -f deploy/03-operator-wif.yaml  # WIF-specific deployment"
echo ""
echo "  The operator will now authenticate to GCP using:"
echo "    1. Kubernetes projected ServiceAccount token (mounted at /var/run/service-account/token)"
echo "    2. GCP STS exchanges it for a short-lived GCP access token"
echo "    3. No JSON keys stored anywhere ✓"
echo ""
echo "  Pool:     ${POOL_ID}"
echo "  Provider: ${PROVIDER_ID}"
echo "  Issuer:   ${CLUSTER_ISSUER}"

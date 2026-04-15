#!/usr/bin/env bash
# =============================================================================
# Kubernetes Operators — Fundamentals Demo
# Using: Apigee API Operator as the real-world example
#
# Audience: SRE & DevOps engineers with solid Kubernetes background
# Focus:    Core operator concepts — CRDs, Control Loop, Informers,
#           Workqueue, Finalizers, Idempotency, Level-triggered design
#
# Usage:  ./demo/demo-script.sh
# Config: Set PROJECT and BASE_URL before running
# =============================================================================
set -euo pipefail
export PATH="${HOME}/.local/bin:${HOME}/bin:/snap/bin:/usr/local/bin:/usr/local/go/bin:${PATH}"

# ── Config ────────────────────────────────────────────────────────────────────
KUBECTL="${KUBECTL:-kubectl}"
PROJECT="${PROJECT:-project-710238f0-9aba-4085-903}"
BASE_URL="${BASE_URL:-https://34.149.73.0.nip.io}"
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'
B='\033[0;34m'  C='\033[0;36m'  M='\033[0;35m'
BOLD='\033[1m'  DIM='\033[2m'   NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
type_text() {
    local text="$1"
    local delay="${2:-0.03}"
    echo -en "  "
    while IFS= read -rn1 char; do
        echo -en "$char"
        sleep "$delay"
    done <<< "$text"
    echo ""
}

banner() {
    local msg="$1"
    local color="${2:-$C}"
    local w=58
    echo ""
    echo -e "${color}$(printf '═%.0s' $(seq 1 $w))${NC}"
    printf "${color}${BOLD}  %-$((w-2))s${NC}\n" "$msg"
    echo -e "${color}$(printf '═%.0s' $(seq 1 $w))${NC}"
    echo ""
}

section() {
    echo ""
    echo -e "${B}$(printf '─%.0s' $(seq 1 58))${NC}"
    echo -e "  ${BOLD}${B}$1${NC}"
    echo -e "${B}$(printf '─%.0s' $(seq 1 58))${NC}"
    echo ""
}

say() { echo -e "  ${G}▸  $1${NC}"; }
idea() { echo -e "  ${Y}💡 $1${NC}"; }
warn() { echo -e "  ${R}⚠  $1${NC}"; }
dim()  { echo -e "  ${DIM}$1${NC}"; }

ask() {
    echo ""
    echo -e "  ${M}${BOLD}❓  $1${NC}"
    echo ""
}

run() {
    echo ""
    echo -e "  ${BOLD}\$ $*${NC}"
    echo ""
    eval "$@"
    echo ""
}

pause() {
    local msg="${1:-Press ENTER to continue}"
    echo ""
    echo -e "  ${C}┌──────────────────────────────────────────────────┐${NC}"
    printf  "  ${C}│  %-48s│${NC}\n" "$msg"
    echo -e "  ${C}└──────────────────────────────────────────────────┘${NC}"
    read -r
}

pause_ask() {
    echo ""
    echo -e "  ${M}┌──────────────────────────────────────────────────┐${NC}"
    printf  "  ${M}│  %-48s│${NC}\n" "❓ $1"
    echo -e "  ${M}│  (take answers, then press ENTER)                │${NC}"
    echo -e "  ${M}└──────────────────────────────────────────────────┘${NC}"
    read -r
}

check() { echo -e "  ${G}✓  ${BOLD}$1${NC}"; }
fail()  { echo -e "  ${R}✗  $1${NC}"; }

# =============================================================================
clear
banner "Kubernetes Operators: Core Concepts" "$M"

echo -e "  ${DIM}A hands-on session for SRE & DevOps engineers${NC}"
echo -e "  ${DIM}Example: The Apigee API Operator — a real production use case${NC}"
echo ""
echo -e "  Agenda:"
dim "   1. The Problem Operators Solve"
dim "   2. CRDs — Extending the Kubernetes API"
dim "   3. The Control Loop — The Heart of Every Operator"
dim "   4. Informers & The Workqueue — How Operators Watch Efficiently"
dim "   5. Finalizers — Guaranteed Cleanup of External State"
dim "   6. Idempotency & Level-Triggered Design"
dim "   7. Live: Operator at Scale"
dim "   8. Impact & GitOps Integration"
echo ""

pause "Start the session"

# =============================================================================
# CHAPTER 1 — THE PROBLEM
# =============================================================================
clear
banner "Chapter 1: The Problem Operators Solve" "$Y"

section "What are we replacing?"

say "Before this operator, provisioning an API on Apigee looked like this:"
echo ""

dim "   # Step 1: Create the proxy bundle"
dim "   zip -r my-api.zip apiproxy/"
dim ""
dim "   # Step 2: Upload to Apigee"
dim "   curl -X POST https://apigee.googleapis.com/v1/organizations/\$ORG/apis \\"
dim "     -H 'Authorization: Bearer \$(gcloud auth print-access-token)' \\"
dim "     -F 'file=@my-api.zip'"
dim ""
dim "   # Step 3: Get the revision number from the response"
dim "   # Step 4: Deploy the revision"
dim "   curl -X POST .../environments/eval/apis/my-api/revisions/1/deployments"
dim ""
dim "   # Step 5: Verify. Step 6: Document. Step 7: Hope nobody deletes it."
echo ""

warn "This is a runbook. And runbooks get run at 3am, by tired people, inconsistently."
echo ""

pause_ask "How many of you have a runbook that looks like this for some system you operate?"

section "The operator pattern — encoding the runbook"

say "An Operator is your runbook compiled into a control loop."
say "It runs 24/7, never gets tired, never skips steps."
echo ""

echo -e "  ${BOLD}Operator = Domain Knowledge + Kubernetes API${NC}"
echo ""
echo -e "  ${DIM}\"Operator\" was coined by CoreOS in 2016.${NC}"
echo -e "  ${DIM}Today: 300+ operators on OperatorHub.io${NC}"
echo -e "  ${DIM}Used by: cert-manager, ArgoCD, Prometheus, Strimzi, Vault...${NC}"
echo ""

pause

# =============================================================================
# CHAPTER 2 — CRDs
# =============================================================================
clear
banner "Chapter 2: CRDs — Extending the Kubernetes API" "$C"

section "What is a CRD?"

say "Kubernetes ships with built-in resource types: Pod, Deployment, Service..."
say "CRDs let you add your OWN resource types to the Kubernetes API."
say "They're not just config files — they become FIRST-CLASS API citizens."
echo ""

pause_ask "What's the difference between a CRD and a ConfigMap?"

section "Our CRD: ApigeeAPI"

say "We extended Kubernetes with a new resource that describes an Apigee API proxy."
run "$KUBECTL get crd apigeeapis.apigee.example.com"

say "It has a shortname, printer columns, validation — just like built-in resources:"
run "$KUBECTL api-resources | grep apigee"

section "The CRD schema enforces correctness at the API layer"

say "The spec has validation rules baked into the schema:"
echo ""
dim "   basePath:"
dim "     pattern: '^/.*'          ← MUST start with /"
dim "   targetUrl:"
dim "     pattern: '^https?://.*'  ← MUST be a valid URL"
dim "   organization, environment, basePath, targetUrl:"
dim "     required: [...]           ← CANNOT be omitted"
echo ""

say "Try applying an invalid CR:"
echo ""
echo -e "  ${BOLD}\$ kubectl apply -f - <<EOF${NC}"
echo "  apiVersion: apigee.example.com/v1alpha1"
echo "  kind: ApigeeAPI"
echo "  metadata:"
echo "    name: invalid-test"
echo "  spec:"
echo "    organization: \"my-org\""
echo "    environment: \"eval\""
echo "    basePath: \"no-leading-slash\"   # ← INVALID"
echo "    targetUrl: \"not-a-url\"          # ← INVALID"
echo -e "  EOF"
echo ""

$KUBECTL apply -f - 2>&1 <<'EOF' || true
apiVersion: apigee.example.com/v1alpha1
kind: ApigeeAPI
metadata:
  name: invalid-test
  namespace: default
spec:
  organization: "my-org"
  environment: "eval"
  basePath: "no-leading-slash"
  targetUrl: "not-a-url"
EOF
echo ""

idea "The API server rejected it — the controller never even saw it."
idea "This is validation at the API layer, not in your application code."

pause

# =============================================================================
# CHAPTER 3 — THE CONTROL LOOP
# =============================================================================
clear
banner "Chapter 3: The Control Loop" "$G"

section "The fundamental pattern"

say "Every Kubernetes controller — including operators — runs one loop:"
echo ""

echo -e "${BOLD}"
cat << 'LOOP'
  ┌─────────────────────────────────────────────────────┐
  │                  THE CONTROL LOOP                   │
  │                                                     │
  │   ┌──────────┐    ┌──────────┐    ┌──────────┐     │
  │   │ OBSERVE  │───▶│   DIFF   │───▶│   ACT    │     │
  │   │          │    │          │    │          │     │
  │   │ What is  │    │ Desired  │    │ Make it  │     │
  │   │ the      │    │  minus   │    │ so.      │     │
  │   │ current  │    │ Actual   │    │          │     │
  │   │ state?   │    │ = delta  │    │          │     │
  │   └──────────┘    └──────────┘    └──────────┘     │
  │         ▲                                │          │
  │         └────────────────────────────────┘          │
  │                   repeat forever                    │
  └─────────────────────────────────────────────────────┘
LOOP
echo -e "${NC}"

say "This is NOT new. PID controllers in aerospace. Thermostat in your house."
say "Kubernetes just applied it to infrastructure management."
echo ""

pause_ask "Can anyone name a system they run that works like a control loop?"

section "Our operator's control loop — made concrete"

echo ""
echo -e "${DIM}"
cat << 'CONCRETE'
  OBSERVE:  Read ApigeeAPI CR from K8s cache
                │
                ▼
  DIFF:     Does the proxy exist on Apigee?
            Is the right revision deployed?
            Is observedGeneration == generation?
                │
                ├── All good → return nil (nothing to do)
                │
                └── Delta found → ACT:
                      Upload proxy bundle to Apigee REST API
                      Deploy revision to environment
                      Update status.phase = "Ready"
                      Stamp observedGeneration
CONCRETE
echo -e "${NC}"

section "Watch the loop run right now"

say "Apply a CR and watch each phase of the loop execute:"
echo ""

$KUBECTL delete apigeeapi loop-demo --ignore-not-found 2>/dev/null || true
sleep 1

$KUBECTL apply -f - 2>/dev/null << EOF
apiVersion: apigee.example.com/v1alpha1
kind: ApigeeAPI
metadata:
  name: loop-demo
  namespace: default
spec:
  organization: "${PROJECT}"
  environment: "eval"
  basePath: "/loop-demo"
  targetUrl: "https://httpbin.org"
  description: "Control loop live demo"
EOF

echo -e "  ${C}Watching phases... (Ctrl+C when Ready)${NC}"
echo ""
timeout 60 $KUBECTL get aapi loop-demo -w 2>/dev/null || true
echo ""

say "You just watched: Adding finalizer → Creating → Deploying → Ready"
say "Each transition is a separate iteration of the control loop."

pause

# =============================================================================
# CHAPTER 4 — INFORMERS & WORKQUEUE
# =============================================================================
clear
banner "Chapter 4: Informers & The Workqueue" "$B"

section "The naive approach — and why it fails at scale"

say "The obvious way to watch for changes: poll the API server."
echo ""
dim "   for { resources := kubectl.List(ApigeeAPIs); reconcile(resources); sleep(5) }"
echo ""

warn "Poll 1000 resources every 5 seconds = 200 requests/sec to the API server."
warn "Kubernetes API server would fall over. NOT how operators work."
echo ""

section "Informers — List once, watch forever"

say "Informers use the Kubernetes Watch API:"
echo ""

echo -e "${DIM}"
cat << 'INFORMER'
  Start-up:
    kubectl.List(ApigeeAPIs)    ← One request, populates local cache
         │
         ▼
  Watch loop:
    kubectl.Watch(ApigeeAPIs)   ← One persistent TCP connection
         │
         ├── Event: ADDED    → enqueue "default/hello-api"
         ├── Event: MODIFIED → enqueue "default/hello-api" (if gen changed)
         ├── Event: DELETED  → (finalizer blocks actual delete)
         └── Event: resync   → periodic re-check (every 30s)

  Result: Zero polling. One connection. Local cache served instantly.
INFORMER
echo -e "${NC}"
idea "The operator reads from a LOCAL CACHE, not the API server."
idea "Writing still goes to the API server — reads are free."
echo ""

section "The Workqueue — rate limiting & deduplication"

say "Events go into a rate-limited, deduplicated queue:"
echo ""

echo -e "${DIM}"
cat << 'QUEUE'
  Event: hello-api MODIFIED
  Event: hello-api MODIFIED   ← same key, deduplicated → only 1 sync
  Event: echo-api  ADDED

  Workqueue: [ "default/hello-api", "default/echo-api" ]
             (processed by N worker goroutines in parallel)

  On failure: exponential backoff before retry (5ms → 10ms → 20ms → ... → 1000s)
  On success: item removed from queue
QUEUE
echo -e "${NC}"

say "This is why operators handle thundering herds gracefully."
say "Flood of events → deduped → single sync per object."

run "$KUBECTL get aapi"

pause

# =============================================================================
# CHAPTER 5 — FINALIZERS
# =============================================================================
clear
banner "Chapter 5: Finalizers — Guaranteed External Cleanup" "$R"

section "The problem: external resources can't be garbage-collected by K8s"

say "Built-in K8s resources use OwnerReferences for cascading deletes."
say "Kubernetes GC deletes children when the parent is deleted."
say "But Apigee proxies, AWS S3 buckets, DNS records, TLS certs..."
echo ""

warn "They live OUTSIDE Kubernetes. K8s GC cannot reach them."
warn "Without protection: delete the CR → Kubernetes object gone → Apigee proxy orphaned forever."
echo ""

section "Finalizers — a 'hold' on deletion"

echo -e "${DIM}"
cat << 'FINALIZER'
  kubectl delete apigeeapi hello-api
       │
       ▼
  K8s sets: metadata.deletionTimestamp = "now"
  K8s sees: metadata.finalizers = ["apigee.example.com/cleanup"]
  K8s says: "I can't delete yet. Something has a hold."
       │
       ▼ (operator's UpdateFunc fires — DeletionTimestamp is set)
       │
  Operator runs finalizer:
     1. Apigee REST: DELETE .../revisions/N/deployments  (undeploy)
     2. Apigee REST: DELETE .../apis/hello-api            (delete proxy)
     3. K8s: PATCH metadata.finalizers = []              (release hold)
       │
       ▼
  K8s: "No more finalizers. Permanently deleting." ✓
FINALIZER
echo -e "${NC}"

idea "Finalizers are how ALL production operators handle external state."
idea "cert-manager uses them for TLS certs. Vault operator for secrets. ArgoCD for apps."
echo ""

section "Watch a finalizer in action"

say "Check current finalizer on an existing CR:"
run "$KUBECTL get apigeeapi echo-api -o jsonpath='{.metadata.finalizers}' && echo"

say "Now delete it — watch the finalizer run:"
run "$KUBECTL delete apigeeapi loop-demo"

say "The delete blocked until the operator cleaned up Apigee, then completed."
echo ""

pause_ask "What happens if the operator crashes mid-finalizer? What's your recovery strategy?"

say "Answer: The reconciliation loop IS the recovery."
say "When the operator restarts, it sees DeletionTimestamp still set."
say "It re-runs the finalizer — which must therefore be IDEMPOTENT."

pause

# =============================================================================
# CHAPTER 6 — IDEMPOTENCY & LEVEL-TRIGGERED DESIGN
# =============================================================================
clear
banner "Chapter 6: Idempotency & Level-Triggered Design" "$M"

section "Level-triggered vs Edge-triggered"

say "SREs know this from alerting systems. Kubernetes uses the same model."
echo ""

echo -e "${DIM}"
cat << 'LEVEL'
  EDGE-TRIGGERED  (webhooks, event streams):
    "Notify me when state changes"
    Problem: Miss an event = miss the action. No recovery.

  LEVEL-TRIGGERED (Kubernetes control loops):
    "Continuously check: is the current state = desired state?"
    Problem: None — every loop iteration is a full correctness check.
    Recovery: Automatic. Restart the operator → it re-syncs.
LEVEL
echo -e "${NC}"

idea "This is why Kubernetes is self-healing. It doesn't remember events."
idea "It only knows desired state and current state."
echo ""

section "The idempotency contract"

say "Every sync must produce the same result no matter how many times it runs."
say "Our operator enforces this with two mechanisms:"
echo ""

echo -e "${DIM}"
cat << 'IDEM'
  1. UpdateFunc filter:
     Only re-enqueue if metadata.generation changed (spec changed)
     Status updates do NOT increment generation → no spurious syncs

  2. observedGeneration guard:
     if status.phase == "Ready" &&
        status.observedGeneration == metadata.generation {
         return nil  // Already reconciled — skip Apigee API calls
     }

  Early versions of this operator created 93 revisions in 3 minutes.
  This is the fix.
IDEM
echo -e "${NC}"

section "Live proof: operator is silent when nothing changed"

BEFORE_REV=$($KUBECTL get apigeeapi hello-api -o jsonpath='{.status.proxyRevision}' 2>/dev/null || echo "?")
say "Current revision on hello-api: ${BOLD}$BEFORE_REV"
echo ""
say "Waiting 20 seconds (30s resync will fire in this window)..."
sleep 20

AFTER_REV=$($KUBECTL get apigeeapi hello-api -o jsonpath='{.status.proxyRevision}' 2>/dev/null || echo "?")
say "Revision after 20s:            ${BOLD}$AFTER_REV"
echo ""

if [[ "$BEFORE_REV" == "$AFTER_REV" ]]; then
    check "Revision unchanged. The resync fired but the guard prevented any Apigee call."
else
    fail "Revision changed — check the idempotency guard."
fi

pause

# =============================================================================
# CHAPTER 7 — LIVE DEMO: OPERATOR AT SCALE
# =============================================================================
clear
banner "Chapter 7: Live — Operator at Scale" "$G"

section "Managing 4 APIs simultaneously"

say "This is where operators show their real value."
say "One operator binary manages N resources with zero extra configuration."
echo ""

run "$KUBECTL get aapi"

section "All 4 APIs — live and accessible"

echo ""
echo -e "  ${BOLD}Testing each endpoint:${NC}"
echo ""
for API in hello-api echo-api mock-users-api google-api; do
    URL=$($KUBECTL get apigeeapi $API -o jsonpath='{.status.publicUrl}' 2>/dev/null || echo "")
    PHASE=$($KUBECTL get apigeeapi $API -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    if [[ -n "$URL" && "$PHASE" == "Ready" ]]; then
        TEST_PATH="/get"
        [[ "$API" == "mock-users-api" ]] && TEST_PATH="/users/1"
        [[ "$API" == "google-api" ]] && TEST_PATH=""
        CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${URL}${TEST_PATH}" 2>/dev/null || echo "ERR")
        if [[ "$CODE" =~ ^2|^3 ]]; then
            check "$API → ${URL}${TEST_PATH}  [HTTP $CODE]"
        else
            fail "$API → ${URL}${TEST_PATH}  [HTTP $CODE]"
        fi
    else
        echo -e "  ${Y}⟳  $API → phase=$PHASE${NC}"
    fi
done
echo ""

section "The echo-api shows Apigee is really in the path"

say "Every request through Apigee gets Envoy tracing headers injected:"
echo ""
ECHO_URL=$($KUBECTL get apigeeapi echo-api -o jsonpath='{.status.publicUrl}' 2>/dev/null || echo "$BASE_URL/echo")
echo -e "  ${BOLD}\$ curl -s ${ECHO_URL}/get | python3 -m json.tool${NC}"
echo ""
curl -s "${ECHO_URL}/get" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
apigee_headers = {k: v for k, v in d.get('headers', {}).items()
                  if any(x in k for x in ['X-B3', 'X-Envoy', 'X-Cloud'])}
print('  Apigee-injected headers:')
for k, v in apigee_headers.items():
    print(f'    {k}: {v}')
print()
print(f'  origin: {d.get(\"origin\", \"?\")}')
print('  (shows the Apigee gateway IP in the chain)')
" 2>/dev/null || echo "  [Could not parse response]"
echo ""

idea "X-B3-Traceid, X-Envoy-Attempt-Count — these prove traffic flows through Apigee's Envoy gateway."
idea "This is observable, distributed-tracing-compatible API management — driven by a YAML in K8s."

pause

# =============================================================================
# CHAPTER 8 — IMPACT & GITOPS
# =============================================================================
clear
banner "Chapter 8: Impact & GitOps Integration" "$Y"

section "What this unlocks for your team"

echo ""
echo -e "  ${BOLD}Before the operator:${NC}"
dim "   • API provisioning: 6 CLI commands, 1 runbook, ~15 min"
dim "   • Requires Apigee console access for every developer"
dim "   • No audit trail — who deployed what, when?"
dim "   • Inconsistent across environments (dev/staging/prod)"
dim "   • Can't be reviewed, approved, or rolled back"
echo ""

echo -e "  ${BOLD}After the operator:${NC}"
echo -e "  ${G}  • API provisioning: 1 YAML file, kubectl apply, ~15 seconds${NC}"
echo -e "  ${G}  • No Apigee console access needed${NC}"
echo -e "  ${G}  • Full audit trail: git history, kubectl events, status conditions${NC}"
echo -e "  ${G}  • Identical process for every environment${NC}"
echo -e "  ${G}  • PR review, approval gates, automated rollback${NC}"
echo ""

section "The GitOps model"

echo -e "${DIM}"
cat << 'GITOPS'
  Developer submits PR:
    ─ deploy/apis/payment-api.yaml  (new ApigeeAPI CR)

  Reviewer approves:
    ─ Code review on the YAML spec
    ─ Same workflow as reviewing application code

  Merge to main → ArgoCD / Flux syncs → kubectl apply
    → Operator creates proxy on Apigee
    → Status written back to K8s: phase=Ready, url=...

  Want to promote to prod?
    kubectl apply -f deploy/apis/payment-api.yaml \
      --dry-run=server    ← preview
    # Change environment: "eval" → "prod" → merge to prod branch
GITOPS
echo -e "${NC}"

section "What the operator encodes (from our project)"

say "In the project that inspired this, the operator provisions:"
echo ""
dim "   • API proxies per microservice team — self-service"
dim "   • Per-tenant Apigee environments on provisioning"
dim "   • Automated cleanup when a tenant is offboarded"
dim "   • The same workflow across 3 environments: dev, staging, prod"
echo ""

idea "The operator is the contract between: Platform Team and Product Team."
idea "Platform owns the operator. Product teams own the YAMLs."

pause

# =============================================================================
# SUMMARY & Q&A
# =============================================================================
clear
banner "Summary: Core Operator Concepts" "$C"

echo ""
echo -e "  ${BOLD}1. CRDs — Extending the API${NC}"
dim "     Your domain language becomes a first-class Kubernetes resource type."
dim "     Validation, RBAC, events, status — all built-in."
echo ""

echo -e "  ${BOLD}2. Control Loop — Observe → Diff → Act${NC}"
dim "     Not a daemon. Not a webhook. A reconciliation loop."
dim "     Self-healing because it checks state, not reacts to events."
echo ""

echo -e "  ${BOLD}3. Informers & Workqueue${NC}"
dim "     List once, watch forever. Local cache. Zero polling."
dim "     Rate-limited, deduplicated queue. Handles thundering herds."
echo ""

echo -e "  ${BOLD}4. Finalizers${NC}"
dim "     Guaranteed cleanup of external state before K8s deletes the CR."
dim "     Used by every production operator that touches external systems."
echo ""

echo -e "  ${BOLD}5. Idempotency & Level-Triggered Design${NC}"
dim "     Every sync must be safe to run N times."
dim "     generation + observedGeneration = your idempotency key."
echo ""

echo -e "${G}$(printf '═%.0s' $(seq 1 58))${NC}"
echo -e "  ${BOLD}Questions?${NC}"
echo -e "${G}$(printf '═%.0s' $(seq 1 58))${NC}"
echo ""
echo -e "  ${DIM}Resources:${NC}"
dim "    Operator Pattern:   kubernetes.io/docs/concepts/extend-kubernetes/operator"
dim "    client-go:          github.com/kubernetes/client-go"
dim "    sample-controller:  github.com/kubernetes/sample-controller"
dim "    OperatorHub:        operatorhub.io (300+ production operators)"
echo ""

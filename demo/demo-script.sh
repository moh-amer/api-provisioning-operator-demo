#!/usr/bin/env bash
# =============================================================================
# Kubernetes Operators — 30-Minute Live Demo
# For: SRE & DevOps engineers
# Run: ./demo/demo-script.sh
# =============================================================================
set -euo pipefail
export PATH="${HOME}/.local/bin:${HOME}/bin:/snap/bin:/usr/local/bin:/usr/local/go/bin:${PATH}"

PROJECT="${PROJECT:-project-710238f0-9aba-4085-903}"
BASE_URL="${BASE_URL:-https://34.149.73.0.nip.io}"
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="${KUBECTL:-kubectl}"

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'
C='\033[0;36m'; M='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Core helpers ──────────────────────────────────────────────────────────────

# Show a narration point
say() { echo -e "  ${G}▸  $1${NC}"; }

# Show a question for the audience
ask() {
    echo ""
    echo -e "  ${M}${BOLD}❓  $1${NC}"
    echo ""
    sleep 0.5
}

# Show command, wait for ENTER, then run it
run_step() {
    local cmd="$1"
    local note="${2:-}"
    local width=56

    echo ""
    [[ -n "$note" ]] && echo -e "  ${DIM}${note}${NC}" && echo ""

    # Command box
    echo -e "  ${Y}${BOLD}┌─ Run ─$(printf '─%.0s' $(seq 1 $((width-6))))┐${NC}"
    echo -e "  ${Y}${BOLD}│${NC}  ${BOLD}\$ ${cmd}${NC}"
    echo -e "  ${Y}${BOLD}└$(printf '─%.0s' $(seq 1 $((width-1))))┘${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to run ▶${NC}  "
    read -r
    echo ""
    eval "$cmd"
    echo ""
}

# Show command, wait for ENTER, run it, then wait again for you to comment
run_and_pause() {
    local cmd="$1"
    local note="${2:-}"
    run_step "$cmd" "$note"
    echo -en "  ${C}Press ENTER to continue ▶${NC}  "
    read -r
    echo ""
}

# Like run_and_pause but Ctrl+C only stops the command — NOT the whole script.
# Use this for: kubectl get -w, kubectl logs -f, watch, etc.
run_watch() {
    local cmd="$1"
    local note="${2:-}"
    local width=56

    echo ""
    [[ -n "$note" ]] && echo -e "  ${DIM}${note}${NC}" && echo ""

    echo -e "  ${Y}${BOLD}┌─ Run ─$(printf '─%.0s' $(seq 1 $((width-6))))┐${NC}"
    echo -e "  ${Y}${BOLD}│${NC}  ${BOLD}\$ ${cmd}${NC}"
    echo -e "  ${Y}${BOLD}│${NC}  ${DIM}(Ctrl+C to stop watching)${NC}"
    echo -e "  ${Y}${BOLD}└$(printf '─%.0s' $(seq 1 $((width-1))))┘${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to run ▶${NC}  "
    read -r
    echo ""

    # Trap SIGINT so Ctrl+C kills only the child process, not this script
    trap '' INT
    eval "$cmd" || true
    trap - INT

    echo ""
    echo -en "  ${C}Press ENTER to continue ▶${NC}  "
    read -r
    echo ""
}

# Just a pause between sections
next() {
    echo ""
    echo -e "  ${C}$(printf '·%.0s' $(seq 1 54))${NC}"
    echo -en "  ${C}Press ENTER for next section ▶${NC}  "
    read -r
    clear
}

# Section banner
section() {
    local title="$1"
    local timer="${2:-}"
    echo ""
    echo -e "${B}$(printf '━%.0s' $(seq 1 58))${NC}"
    if [[ -n "$timer" ]]; then
        printf "${B}${BOLD}  %-48s${Y}%6s${NC}\n" "$title" "$timer"
    else
        echo -e "  ${B}${BOLD}$title${NC}"
    fi
    echo -e "${B}$(printf '━%.0s' $(seq 1 58))${NC}"
    echo ""
}

# Big chapter header
chapter() {
    local num="$1"
    local title="$2"
    local timer="${3:-}"
    clear
    echo ""
    echo -e "${C}$(printf '═%.0s' $(seq 1 58))${NC}"
    printf "${C}${BOLD}  %s — %-40s${NC}\n" "$num" "$title"
    [[ -n "$timer" ]] && printf "${DIM}  %-54s${NC}\n" "⏱  $timer"
    echo -e "${C}$(printf '═%.0s' $(seq 1 58))${NC}"
    echo ""
}

# Inline diagram
diagram() {
    echo ""
    echo -e "${DIM}$1${NC}"
    echo ""
}

# =============================================================================
# INTRO
# =============================================================================
clear
echo ""
echo -e "${C}$(printf '═%.0s' $(seq 1 58))${NC}"
echo -e "${C}${BOLD}  Kubernetes Operators — Live Demo                   ${NC}"
echo -e "${DIM}  30 min  •  SRE & DevOps session                    ${NC}"
echo -e "${C}$(printf '═%.0s' $(seq 1 58))${NC}"
echo ""
echo -e "  ${BOLD}Agenda:${NC}"
echo -e "  ${DIM}1. What is an Operator? — CRDs (5 min)${NC}"
echo -e "  ${DIM}2. The Control Loop (8 min)${NC}"
echo -e "  ${DIM}3. Finalizers — External Cleanup (6 min)${NC}"
echo -e "  ${DIM}4. Idempotency (4 min)${NC}"
echo -e "  ${DIM}5. Live Scale Demo (4 min)${NC}"
echo -e "  ${DIM}6. Q&A (3 min)${NC}"
echo ""
echo -en "  ${C}Press ENTER to start ▶${NC}  "
read -r
clear

# =============================================================================
# CHAPTER 1 — WHAT IS AN OPERATOR? CRDs
# =============================================================================
chapter "1" "What is an Operator?" "0:00 → 5:00"

say "An Operator = Domain Knowledge + Kubernetes Control Loop"
say "It encodes your runbook into software that runs 24/7."
echo ""

diagram "  Without operator:                 With operator:
  ─────────────────────────────     ────────────────────────────
  \$ gcloud apigee apis create...    \$ kubectl apply -f api.yaml
  \$ gcloud ... revisions deploy     → proxy created ✓
  \$ verify... document... hope...   → deployed ✓
                                    → status updated ✓
  (6 commands, 15 min, at 3am)      (1 YAML, 15 seconds, always)"

ask "How many of you have a runbook that you wish was automated?"

section "CRDs: Your own resource types in Kubernetes"

say "CRDs let you add custom resources to the Kubernetes API."
say "They're not ConfigMaps — they're first-class API objects."
say "With schema validation, printer columns, RBAC, events."
echo ""

run_and_pause "$K get crd apigeeapis.apigee.example.com" \
    "Our CRD is registered as a real Kubernetes API resource:"

run_and_pause "$K api-resources | grep apigee" \
    "Short name 'aapi' — works exactly like pod, deploy, svc:"

section "CRDs enforce correctness at the API layer"

say "Invalid input is rejected BEFORE the controller even sees it."
echo ""

run_and_pause "cat $DEMO_DIR/deploy/examples/hello-api.yaml" \
    "This is ALL you write to manage an Apigee API proxy:"

next

# =============================================================================
# CHAPTER 2 — THE CONTROL LOOP
# =============================================================================
chapter "2" "The Control Loop" "5:00 → 13:00"

diagram "  THE CONTROL LOOP — every operator runs this forever:

  ┌──────────┐    ┌───────────────┐    ┌──────────┐
  │ OBSERVE  │───▶│     DIFF      │───▶│   ACT    │
  │          │    │               │    │          │
  │ Read CR  │    │ Desired state │    │ Call     │
  │ from K8s │    │ minus current │    │ Apigee   │
  │ cache    │    │ = what to do  │    │ REST API │
  └──────────┘    └───────────────┘    └──────────┘
        ▲                                    │
        └────────────────────────────────────┘
                    (forever)"

say "This is not new. Your thermostat works this way."
say "PID controllers in aerospace. systemd unit restarts."
say "Kubernetes just applied it to infrastructure."
echo ""

ask "What's the difference between this and a webhook or event listener?"

say "Webhooks are EDGE-triggered: miss an event = miss the action."
say "Control loops are LEVEL-triggered: always comparing state."
say "This is why Kubernetes self-heals."

section "Under the hood: Informers & Workqueue"

diagram "  HOW THE OPERATOR WATCHES efficiently:

  Naive (wrong):
    poll every 5s x 1000 objects = API server hammered to death

  Informer (right):
    Startup: List() ──▶ local cache filled   (1 API call, ever)
    Runtime: Watch() ──▶ persistent TCP stream  (0 polling)
             ADDED / MODIFIED event ──▶ enqueue key 'default/hello-api'

  Worker goroutines pop the key and read FRESH state from cache.

  3 things SREs care about:
    1. Reads are FREE   — served from local cache, not the API server
    2. Deduplication    — 100 events same object = 1 sync
    3. Keys not objects — worker reads CURRENT state, not event state
       This is WHY it is level-triggered, not edge-triggered."

section "Live: see the informer startup in operator logs"

say "The operator prints every phase of this sequence on startup:"
echo ""

run_and_pause "grep -iE 'cache|worker|sync' /tmp/operator-test.log | head -8" \
    "Cache populated, workers started — straight from the operator:"

section "Watch the loop run — apply a CR"

say "Apply the CR. Watch: Finalizer → Creating → Deploying → Ready"
echo ""

run_step "kubectl delete apigeeapi hello-api --ignore-not-found 2>/dev/null; sleep 1" \
    "Clean slate first:"

run_step "$K apply -f $DEMO_DIR/deploy/examples/hello-api.yaml" \
    "Create the ApigeeAPI custom resource:"

run_watch "$K get aapi -w" \
    "Watch the phases change in real time (Ctrl+C when Ready):"

section "Check what the operator stored in status"

run_and_pause "$K describe apigeeapi hello-api" \
    "Full status, events, and conditions:"

run_and_pause "$K get apigeeapi hello-api -o jsonpath='{.status.publicUrl}' && echo" \
    "The live public URL:"

section "Live: deduplication in action"

say "Patch the CR twice in rapid succession."
say "The workqueue deduplicates — you should see ONE syncHandler call, not two."
echo ""

run_step "kubectl patch apigeeapi hello-api --type=merge -p '{\"spec\":{\"description\":\"dedup-test-1\"}}' \
  && sleep 0.2 \
  && kubectl patch apigeeapi hello-api --type=merge -p '{\"spec\":{\"description\":\"dedup-test-2\"}}'  " \
    "Fire two patches back to back:"

run_and_pause "sleep 12 && echo 'Total syncs for hello-api:' && grep -c 'Successfully synced.*hello-api' /tmp/operator-test.log" \
    "Count of syncHandler calls — expect 1-2 despite 2 events:"

say "The queue collapses duplicates. Whether it's 2 patches or 200, the"
say "worker only runs once per unique key per drain cycle."
echo ""



section "Hit the live API"

say "The proxy is live on Google Cloud Apigee right now."
say "Traffic: internet → Apigee gateway → httpbin.org"
echo ""

run_and_pause "curl -s ${BASE_URL}/k8s-demo/get | python3 -m json.tool" \
    "Real HTTP request through the Apigee proxy we just created:"

next

# =============================================================================
# CHAPTER 3 — FINALIZERS
# =============================================================================
chapter "3" "Finalizers — Guaranteed External Cleanup" "13:00 → 19:00"

say "Built-in K8s resources use OwnerReferences — K8s GC cleans up children."
say "But Apigee proxies live OUTSIDE Kubernetes."
say "K8s garbage collector cannot reach cloud resources."
echo ""

diagram "  Without Finalizer:
  kubectl delete apigeeapi hello-api
  → K8s object gone ✓
  → Apigee proxy still running on GCP! 💸 (orphaned forever)

  With Finalizer:
  kubectl delete apigeeapi hello-api
  → K8s sets DeletionTimestamp (object paused)
  → Operator sees it → calls Apigee REST API:
      DELETE .../environments/eval/hello-api/deployments
      DELETE .../organizations/.../apis/hello-api
  → Removes finalizer → K8s completes deletion ✓"

ask "What happens if the operator crashes DURING the finalizer?"

say "Answer: the reconciliation loop IS the recovery."
say "Restart → DeletionTimestamp still set → finalizer re-runs."
say "This is why finalizers MUST be idempotent."
echo ""

section "Watch a finalizer in action"

run_step "$K get apigeeapi hello-api -o jsonpath='{.metadata.finalizers}' && echo" \
    "See the finalizer registered on the object:"

run_and_pause "$K delete apigeeapi hello-api" \
    "Delete the CR — watch it block until Apigee is cleaned up:"

run_and_pause "$K get aapi" \
    "Confirm the CR is gone:"

next

# =============================================================================
# CHAPTER 4 — IDEMPOTENCY
# =============================================================================
chapter "4" "Idempotency — The Infinite Loop Bug" "19:00 → 23:00"

say "Early version of this operator had a critical bug."
echo ""

diagram "  syncHandler runs
  → calls updateStatus()
  → triggers Update event on the CR
  → UpdateFunc fires → enqueue()
  → syncHandler runs again
  → createProxy() → NEW REVISION on Apigee
  → updateStatus() → Update event → ...

  Result: 93 revisions created in 3 minutes 🔥"

say "The fix: two mechanisms working together."
echo ""

diagram "  Fix 1 — UpdateFunc filter:
    Only re-enqueue if metadata.generation changed
    Status writes do NOT increment generation
    → status updates no longer cause re-syncs

  Fix 2 — observedGeneration guard:
    if phase=Ready AND observedGeneration == generation:
        return nil   ← skip all Apigee API calls"

section "Prove it's working"

say "Apply the CR, wait for Ready, then watch for 20 seconds."
say "The revision number should NOT change."
echo ""

run_step "$K apply -f $DEMO_DIR/deploy/examples/hello-api.yaml" \
    "Re-create hello-api:"

run_step "sleep 20 && $K get apigeeapi hello-api -o jsonpath='revision={.status.proxyRevision} observedGen={.status.observedGeneration} gen={.metadata.generation}' && echo" \
    "After 20s — revision unchanged = idempotency guard working:"

next

# =============================================================================
# CHAPTER 5 — LIVE SCALE DEMO
# =============================================================================
chapter "5" "One Operator — Many APIs" "23:00 → 27:00"

say "One operator binary manages N resources."
say "No extra configuration per API."
say "GitOps-ready: each API is a YAML file in your repo."
echo ""

section "Deploy 3 more APIs simultaneously"

run_step "$K apply \
  -f $DEMO_DIR/deploy/examples/echo-api.yaml \
  -f $DEMO_DIR/deploy/examples/mock-users-api.yaml \
  -f $DEMO_DIR/deploy/examples/google-api.yaml" \
    "Apply 3 CRs at once:"

run_watch "$K get aapi -w" \
    "Watch all 4 APIs deploy in parallel (Ctrl+C when all Ready):"

section "All 4 APIs — live on Apigee right now"

run_and_pause "$K get aapi" \
    "One operator, 4 proxies, all managed declaratively:"

section "The echo-api proves traffic flows through Apigee"

say "Apigee's Envoy gateway injects tracing headers on every request."
say "These headers prove the traffic went through the gateway."
echo ""

run_and_pause "curl -s ${BASE_URL}/echo/get | python3 -m json.tool" \
    "Apigee injects tracing headers — visible in the response:"

run_and_pause "curl -s ${BASE_URL}/mock-users/users/1 | python3 -m json.tool" \
    "Mock Users API — real JSON through Apigee proxy:"

next

# =============================================================================
# SUMMARY
# =============================================================================
clear
echo ""
echo -e "${C}$(printf '═%.0s' $(seq 1 58))${NC}"
echo -e "${C}${BOLD}  Summary                                            ${NC}"
echo -e "${C}$(printf '═%.0s' $(seq 1 58))${NC}"
echo ""

echo -e "  ${BOLD}1. CRDs${NC}"
echo -e "  ${DIM}     Extend the Kubernetes API with your own resource types${NC}"
echo -e "  ${DIM}     Schema validation, RBAC, events — all built in${NC}"
echo ""

echo -e "  ${BOLD}2. Control Loop${NC}"
echo -e "  ${DIM}     Observe → Diff → Act — runs forever${NC}"
echo -e "  ${DIM}     Level-triggered: self-healing without remembering events${NC}"
echo ""

echo -e "  ${BOLD}3. Finalizers${NC}"
echo -e "  ${DIM}     Guaranteed cleanup of external resources before K8s deletes${NC}"
echo -e "  ${DIM}     Used by: cert-manager, Vault, ArgoCD, AWS Controllers...${NC}"
echo ""

echo -e "  ${BOLD}4. Idempotency${NC}"
echo -e "  ${DIM}     generation + observedGeneration = your idempotency key${NC}"
echo -e "  ${DIM}     Every sync must be safe to run N times${NC}"
echo ""

echo -e "  ${BOLD}5. Scale${NC}"
echo -e "  ${DIM}     One binary, N resources, GitOps-ready${NC}"
echo -e "  ${DIM}     Platform team owns the operator. Dev teams own the YAMLs.${NC}"
echo ""

echo -e "${C}$(printf '═%.0s' $(seq 1 58))${NC}"
echo -e "  ${BOLD}Q&A                                          ⏱  3 min${NC}"
echo -e "${C}$(printf '═%.0s' $(seq 1 58))${NC}"
echo ""

# =============================================================================
# CLEANUP OPTION
# =============================================================================
echo -en "  ${Y}Delete all demo APIs when done? [y/N] ▶${NC}  "
read -r CLEANUP
if [[ "$CLEANUP" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "  ${DIM}Running finalizers — cleaning up Apigee resources...${NC}"
    $K delete apigeeapi --all --ignore-not-found
    echo -e "  ${G}✓  All demo APIs deleted from Kubernetes and Apigee${NC}"
fi
echo ""

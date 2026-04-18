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

# Run everything from repo root so all paths are relative
cd "$DEMO_DIR"

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

_save_dedup_baseline() {
    $K get apigeeapi hello-api -o jsonpath='{.status.proxyRevision}' > /tmp/.dedup-rev-before 2>/dev/null
    wc -l < "$OPERATOR_LOG" > /tmp/.dedup-baseline 2>/dev/null || echo 0 > /tmp/.dedup-baseline
    echo "Current revision: $(cat /tmp/.dedup-rev-before)"
    echo "Log baseline: line $(cat /tmp/.dedup-baseline)"
}

_fire_dedup_patches() {
    for i in 1 2 3 4 5; do
        kubectl patch apigeeapi hello-api --type=merge \
            -p "{\"spec\":{\"description\":\"dedup-test-${i}\"}}" &
    done
    wait
    echo "All 5 patches submitted simultaneously"
}

_dedup_check() {
    local before after
    before=$(cat /tmp/.dedup-rev-before 2>/dev/null || echo '?')
    after=$($K get apigeeapi hello-api -o jsonpath='{.status.proxyRevision}' 2>/dev/null || echo '?')
    echo ""
    echo "  Revision BEFORE patches: ${before}"
    echo "  Revision AFTER patches:  ${after}"
    echo ""
    if [[ "$before" != "?" && "$after" != "?" ]]; then
        local diff=$((after - before))
        if [[ $diff -le 2 ]]; then
            echo -e "  ${G}${BOLD}Result: 5 patches, but only ${diff} Apigee revision(s) created${NC}"
            echo -e "  ${G}${BOLD}=> Deduplication collapsed 5 events into ${diff} sync(s)!${NC}"
        elif [[ $diff -lt 5 ]]; then
            echo -e "  ${G}${BOLD}Result: 5 patches, ${diff} revisions (dedup saved $((5 - diff)) API calls)${NC}"
        else
            echo -e "  ${Y}Result: ${diff} revisions -- worker was fast enough to process each one${NC}"
        fi
    fi
    echo ""
    # Also show what the operator logged
    local baseline
    baseline=$(cat /tmp/.dedup-baseline 2>/dev/null || echo 0)
    echo "  Operator log (new lines only):"
    tail -n +"$baseline" $OPERATOR_LOG 2>/dev/null | grep -m 5 -i -e Created -e Updated -e synced -e proxy || echo "  (waiting for log flush)"
}

# Helper functions for Chapter 5 (drift detection)
# These avoid eval quoting issues by wrapping complex commands in functions.
_save_drift_baseline() {
    wc -l < "$OPERATOR_LOG" > /tmp/.drift-baseline 2>/dev/null || echo 0 > /tmp/.drift-baseline
    echo "Log baseline saved: line $(cat /tmp/.drift-baseline)"
}

_delete_proxy_from_apigee() {
    gcloud apigee apis undeploy --api=hello-api --environment=eval \
        --organization="$PROJECT" --quiet 2>/dev/null || true
    gcloud apigee apis delete hello-api \
        --organization="$PROJECT" --quiet 2>/dev/null \
        && echo "Proxy deleted from Apigee" \
        || echo "Proxy already gone"
}

_watch_drift_logs() {
    local baseline
    baseline=$(cat /tmp/.drift-baseline 2>/dev/null || echo 1)
    tail -n +"$baseline" -f "$OPERATOR_LOG" | grep --line-buffered -i -e DRIFT -e Created -e Deployed -e proxy -e synced -e re-reconcil
}

# =============================================================================
# SETUP: Stream operator pod logs → /tmp/operator-test.log
# All demo grep steps read from this file regardless of how operator runs.
# =============================================================================

OPERATOR_NS="apigee-api-operator-system"
OPERATOR_LOG="/tmp/operator-test.log"
LOG_STREAM_PID=""

_start_log_stream() {
    # Check if operator is running as a pod (in-cluster mode)
    local pod
    pod=$(kubectl get pods -n "$OPERATOR_NS" -l app=apigee-api-operator \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -n "$pod" ]]; then
        echo -e "   ${DIM}Operator pod: ${pod}${NC}"
        echo -e "   ${DIM}Streaming pod logs → ${OPERATOR_LOG}${NC}"
        # Truncate + stream: historical (since 1h) then live
        kubectl logs -n "$OPERATOR_NS" "$pod" --since=1h 2>/dev/null \
            > "$OPERATOR_LOG"
        kubectl logs -n "$OPERATOR_NS" "$pod" --follow 2>/dev/null \
            >> "$OPERATOR_LOG" &
        LOG_STREAM_PID=$!
        echo -e "   ${G}✓  Log stream running (PID ${LOG_STREAM_PID})${NC}"
    elif [[ -f "$OPERATOR_LOG" ]]; then
        echo -e "   ${DIM}Using existing log file: ${OPERATOR_LOG}${NC}"
        echo -e "   ${G}✓  (operator running out-of-cluster)${NC}"
    else
        echo -e "   ${Y}⚠  Operator pod not found and no local log file.${NC}"
        echo -e "   ${Y}   Is the operator deployed? Run: make deploy${NC}"
        echo -e "   ${Y}   Continuing demo — log-inspection steps will be skipped.${NC}"
        touch "$OPERATOR_LOG"   # create empty file so grep doesn't error
    fi
}

# Kill log stream on script exit
trap '[[ -n "$LOG_STREAM_PID" ]] && kill "$LOG_STREAM_PID" 2>/dev/null || true' EXIT

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
echo -e "  ${DIM}5. Self-Healing — Drift Detection (5 min)${NC}"
echo -e "  ${DIM}6. Live Scale Demo (4 min)${NC}"
echo -e "  ${DIM}7. Q&A (3 min)${NC}"
echo ""
echo -en "  ${C}Press ENTER to start ▶${NC}  "
read -r
clear

# Start streaming operator pod logs → /tmp/operator-test.log
# All grep steps in the demo read from this file.
_start_log_stream
sleep 1

# =============================================================================
# CHAPTER 1 — WHAT IS AN OPERATOR? CRDs
# =============================================================================
chapter "1" "What is an Operator?" "0:00 → 5:00"

say "An Operator is a controller that manages a custom resource."
say "Think of it like a thermostat, but for infrastructure:"
echo ""

diagram "  Thermostat:                        Operator:
  ────────────────────────────────  ─────────────────────────────
  Desired: 22C (you set it)         Desired: API proxy on Apigee
  Actual:  18C (sensor reads it)    Actual:  does the proxy exist?
  Action:  turn on heater           Action:  create + deploy proxy
  Loop:    check again in 30s       Loop:    check again in 30s"

say "The thermostat does not remember events. It reads the thermometer."
say "If someone opens a window, it doesn't need an event -- it sees 18C, acts."
say "An operator works the same way. It reads the current state and converges."
echo ""

diagram "  Without operator:                 With operator:
  ─────────────────────────────     ────────────────────────────
  \$ gcloud apigee apis create...    \$ kubectl apply -f api.yaml
  \$ gcloud ... revisions deploy     -> proxy created
  \$ verify... document... hope...   -> deployed
                                    -> status updated
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

run_and_pause "cat ./deploy/examples/hello-api.yaml" \
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

say "Back to the thermostat. This is exactly that loop:"
echo ""
say "OBSERVE: read the ApigeeAPI CR from the Kubernetes cache."
say "DIFF: does the proxy exist on Apigee? Is it the right revision?"
say "ACT: if not -- create it, deploy it, update status."
say "Then wait for the next trigger and do it again."
echo ""

ask "How is this different from a webhook or an event listener?"

say "A webhook is edge-triggered: it fires ONCE when something changes."
say "If you miss the event -- network blip, crash, restart -- the action is lost."
echo ""
say "A control loop is level-triggered: it checks CURRENT state, not events."
say "Like the thermostat -- it doesn't care WHY the room is cold."
say "It reads 18C, desired is 22C, so it acts. Every time."

section "Under the hood: Informers & Workqueue"

diagram "  HOW THE OPERATOR WATCHES efficiently:

  Naive approach:
    poll API server every 5s x 1000 objects = hammered to death

  Informer approach:
    Startup: List all CRs once -> fill local cache  (1 API call, ever)
    Runtime: Watch via TCP stream -> get push notifications  (0 polling)
             ADDED/MODIFIED event -> enqueue key 'default/hello-api'

  Worker goroutines pop the key and read FRESH state from cache.

  Why this matters:
    1. Reads are FREE -- served from cache, not the API server
    2. Deduplication  -- 100 events for same object = 1 sync
    3. Keys not objects -- worker reads CURRENT state, not stale event data
       The worker does not care what CHANGED. It reads what IS.
       This is what makes it level-triggered."

section "Live: see the informer startup in operator logs"

say "The operator prints every phase of this sequence on startup:"
echo ""

run_and_pause "grep -m 8 -i -e cache -e worker -e sync /tmp/operator-test.log" \
    "Cache populated, workers started — straight from the operator:"

section "Watch the loop run — apply a CR"

say "Apply the CR. Watch: Finalizer → Creating → Deploying → Ready"
echo ""

run_step "kubectl delete apigeeapi hello-api --ignore-not-found 2>/dev/null; sleep 1" \
    "Clean slate first:"

run_step "$K apply -f ./deploy/examples/hello-api.yaml" \
    "Create the ApigeeAPI custom resource:"

run_watch "$K get aapi -w" \
    "Watch the phases change in real time (Ctrl+C when Ready):"

section "Check what the operator stored in status"

run_and_pause "$K describe apigeeapi hello-api" \
    "Full status, events, and conditions:"

run_and_pause "$K get apigeeapi hello-api -o jsonpath='{.status.publicUrl}' && echo" \
    "The live public URL:"

section "Live: deduplication in action"

say "The workqueue stores KEYS, not objects."
say "If 5 events arrive for the same key while the worker is busy,"
say "the queue holds just ONE entry. When the worker finishes, it pops"
say "the key, reads CURRENT state from cache, and syncs ONCE."
echo ""
say "The key: events must arrive WHILE the worker is already busy."
say "An Apigee API call takes ~3 seconds. We fire 5 patches simultaneously"
say "so they pile up while the first sync is running."
echo ""

diagram "  Patch 1 ──▶  queue: [default/hello-api]   ← worker pops this
  Patch 2 ──▶  queue: [default/hello-api]   ← arrives while worker busy
  Patch 3 ──▶  queue: [default/hello-api]   ← same key, deduped
  Patch 4 ──▶  queue: [default/hello-api]   ← same key, deduped
  Patch 5 ──▶  queue: [default/hello-api]   ← same key, deduped
                       │
                       ▼
                  Worker finishes sync 1
                  Pops key ONCE more
                  Reads cache: desc=patch-5 (latest)
                  ONE more sync

  Result: 5 patches, but only ~2 Apigee revisions (not 5)"

run_step "_save_dedup_baseline" \
    "Record the current revision and log baseline:"

run_step "_fire_dedup_patches" \
    "Fire 5 patches simultaneously (all in parallel):"

run_and_pause "sleep 20 && _dedup_check" \
    "Compare revisions — proof of deduplication:"

run_and_pause "curl -s ${BASE_URL}/k8s-demo/get | python3 -m json.tool" \
    "Real HTTP request through the Apigee proxy we just created:"

next

# =============================================================================
# CHAPTER 3 — FINALIZERS
# =============================================================================
chapter "3" "Finalizers — Guaranteed External Cleanup" "13:00 → 19:00"

say "When you delete a Pod, Kubernetes garbage-collects its children."
say "But Apigee proxies live OUTSIDE the cluster -- on Google Cloud."
say "Kubernetes GC cannot reach them. Without a finalizer, deleting the CR"
say "leaves the proxy running on Apigee forever -- costing money."
echo ""

diagram "  Without Finalizer:
  kubectl delete apigeeapi hello-api
  -> K8s object gone
  -> Apigee proxy still running on GCP (orphaned, costs money)

  With Finalizer:
  kubectl delete apigeeapi hello-api
  -> K8s sets DeletionTimestamp (object is paused, not deleted)
  -> Operator sees DeletionTimestamp -> calls Apigee REST API:
       DELETE .../environments/eval/hello-api/deployments
       DELETE .../organizations/.../apis/hello-api
  -> Removes finalizer -> K8s completes deletion"

ask "What happens if the operator crashes DURING the finalizer?"

say "The thermostat analogy again: restart the operator, it reads state."
say "DeletionTimestamp is STILL set. The finalizer re-runs."
say "No event was needed. The level-triggered loop IS the recovery."
say "This is why finalizers MUST be idempotent -- they may run more than once."
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

run_step "$K apply -f ./deploy/examples/hello-api.yaml" \
    "Re-create hello-api:"

run_step "sleep 20 && $K get apigeeapi hello-api -o jsonpath='revision={.status.proxyRevision} observedGen={.status.observedGeneration} gen={.metadata.generation}' && echo" \
    "After 20s — revision unchanged = idempotency guard working:"

next

# =============================================================================
# CHAPTER 5 — SELF-HEALING (DRIFT DETECTION)
# =============================================================================
chapter "5" "Self-Healing — When Things Break" "23:00 → 28:00"

say "You have seen the happy path: create, update, delete."
say "But operators prove their value when things BREAK."
echo ""
say "Remember the thermostat: it does not care WHY the room is cold."
say "Window open? Heater broke and restarted? Someone set it to 10C then back?"
say "The thermostat reads the thermometer and acts."
echo ""
say "Same here. What if someone deletes the proxy directly from Apigee?"
say "The Apigee console, a gcloud command, a cleanup script."
echo ""

diagram "  The scenario:

  Kubernetes says:    Phase=Ready   Deployed=true
  Apigee reality:     proxy GONE
  Traffic result:     404 Not Found

  Nobody told Kubernetes. No event was fired.
  An edge-triggered webhook would never catch this.
  But the thermostat does not need an event -- it reads the sensor."

ask "How would you detect this without an operator?"

say "Monitoring jobs, alerts, PagerDuty, a runbook, a human at 3am."
say "With a control loop? Every 30 seconds the operator calls GetProxy."
say "If the proxy is gone, it re-creates and re-deploys. Automatically."
say "No event needed. The level-triggered loop reads actual state and converges."

section "Live: Break it and watch it heal"

run_and_pause "$K get aapi" \
    "Current state -- hello-api is Ready and Deployed:"

say "Now I will switch to the Apigee console and delete the proxy manually."
say "This bypasses Kubernetes entirely -- no kubectl, no YAML."
say "Watch the operator logs here while I do it."
echo ""
say "When the proxy is deleted, the next 30-second resync will detect it."
say "You will see: DRIFT DETECTED, then re-create, then Ready."
echo ""

run_watch "$K logs -n apigee-api-operator-system -l app=apigee-api-operator -f --tail=1" \
    "Operator logs live -- go delete the proxy from Apigee UI, then Ctrl+C when healed:"

section "Verify the self-healing worked"

run_and_pause "$K get aapi" \
    "CR status after self-healing — back to Ready:"

run_and_pause "$K describe apigeeapi hello-api | tail -12" \
    "Events tell the full story — DriftDetected then Synced:"

run_and_pause "curl -s ${BASE_URL}/k8s-demo/get | python3 -m json.tool" \
    "And traffic flows again — the proxy is alive:"

say "What just happened:"
echo ""

diagram "  1. Someone deleted the proxy outside Kubernetes
  2. 30s later: informer periodic resync fired
  3. Operator called GetProxy -- got 404 Not Found
  4. DRIFT DETECTED -- logged + warning event emitted
  5. CreateProxyWithBundle -- uploaded new revision
  6. DeployRevision -- deployed to environment
  7. Status updated: Phase=Ready, Deployed=true

  Total recovery time: ~5 seconds after detection
  Human intervention required: ZERO"

say "No human. No alert. No runbook. The loop IS the recovery."

next

# =============================================================================
# CHAPTER 6 — LIVE SCALE DEMO
# =============================================================================
chapter "6" "One Operator — Many APIs" "28:00 → 32:00"

say "One operator binary manages N resources."
say "No extra configuration per API."
say "GitOps-ready: each API is a YAML file in your repo."
echo ""

section "Deploy 3 more APIs simultaneously"

run_step "$K apply \
  -f ./deploy/examples/echo-api.yaml \
  -f ./deploy/examples/mock-users-api.yaml \
  -f ./deploy/examples/google-api.yaml" \
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

echo -e "  ${BOLD}5. Self-Healing${NC}"
echo -e "  ${DIM}     Drift detection: verify actual state, not just desired${NC}"
echo -e "  ${DIM}     The loop IS the recovery — no human intervention${NC}"
echo ""

echo -e "  ${BOLD}6. Scale${NC}"
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

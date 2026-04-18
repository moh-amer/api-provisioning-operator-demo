#!/usr/bin/env bash
# =============================================================================
# The Life of an API -- A Kubernetes Operator Story
# For: SRE & DevOps engineers (30-minute live demo)
# Run: ./demo/demo-script.sh
# =============================================================================
set -euo pipefail
export PATH="${HOME}/.local/bin:${HOME}/bin:/snap/bin:/usr/local/bin:/usr/local/go/bin:${PATH}"

PROJECT="${PROJECT:-project-710238f0-9aba-4085-903}"
BASE_URL="${BASE_URL:-https://34.149.73.0.nip.io}"
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="${KUBECTL:-kubectl}"
DEMO_EXAMPLES="./demo/examples"
DEMO_IMAGES="./demo/images"

# Run everything from repo root
cd "$DEMO_DIR"

# -- Colors -------------------------------------------------------------------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'
C='\033[0;36m'; M='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# -- Core helpers -------------------------------------------------------------
say()     { echo -e "  ${G}> $1${NC}"; }
ask()     { echo ""; echo -e "  ${M}${BOLD}?  $1${NC}"; echo ""; sleep 0.5; }
narrator(){ echo ""; echo -e "  ${Y}${BOLD}$1${NC}"; echo ""; }

run_step() {
    local cmd="$1" note="${2:-}" width=56
    echo ""
    [[ -n "$note" ]] && echo -e "  ${DIM}${note}${NC}" && echo ""
    echo -e "  ${Y}${BOLD}+-- Run -$(printf -- '-%.0s' $(seq 1 $((width-7))))+${NC}"
    echo -e "  ${Y}${BOLD}|${NC}  ${BOLD}\$ ${cmd}${NC}"
    echo -e "  ${Y}${BOLD}+$(printf -- '-%.0s' $(seq 1 $((width-1))))+${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to run >${NC}  "
    read -r
    echo ""
    eval "$cmd"
    echo ""
}

run_and_pause() {
    local cmd="$1" note="${2:-}"
    run_step "$cmd" "$note"
    echo -en "  ${C}Press ENTER to continue >${NC}  "
    read -r
    echo ""
}

run_watch() {
    local cmd="$1" note="${2:-}" width=56
    echo ""
    [[ -n "$note" ]] && echo -e "  ${DIM}${note}${NC}" && echo ""
    echo -e "  ${Y}${BOLD}+-- Run -$(printf -- '-%.0s' $(seq 1 $((width-7))))+${NC}"
    echo -e "  ${Y}${BOLD}|${NC}  ${BOLD}\$ ${cmd}${NC}"
    echo -e "  ${Y}${BOLD}|${NC}  ${DIM}(Ctrl+C to stop watching)${NC}"
    echo -e "  ${Y}${BOLD}+$(printf -- '-%.0s' $(seq 1 $((width-1))))+${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to run >${NC}  "
    read -r
    echo ""
    trap '' INT
    eval "$cmd" || true
    trap - INT
    echo ""
    echo -en "  ${C}Press ENTER to continue >${NC}  "
    read -r
    echo ""
}

next() {
    echo ""
    echo -e "  ${C}$(printf -- '.%.0s' $(seq 1 54))${NC}"
    echo -en "  ${C}Press ENTER for next act >${NC}  "
    read -r
    clear
}

act() {
    local num="$1" title="$2" timer="${3:-}"
    clear
    echo ""
    echo -e "${C}$(printf '=%.0s' $(seq 1 58))${NC}"
    printf "${C}${BOLD}  Act %s -- %-44s${NC}\n" "$num" "$title"
    [[ -n "$timer" ]] && printf "${DIM}  %-54s${NC}\n" "$timer"
    echo -e "${C}$(printf '=%.0s' $(seq 1 58))${NC}"
    echo ""
}

section() {
    local title="$1"
    echo ""
    echo -e "${B}$(printf -- '-%.0s' $(seq 1 58))${NC}"
    echo -e "  ${B}${BOLD}$title${NC}"
    echo -e "${B}$(printf -- '-%.0s' $(seq 1 58))${NC}"
    echo ""
}

diagram() {
    echo ""
    echo -e "${DIM}$1${NC}"
    echo ""
}

show_image() {
    local img="$1" caption="${2:-}"
    if command -v feh &>/dev/null; then
        feh --scale-down --auto-zoom "$img" &
        local pid=$!
        [[ -n "$caption" ]] && echo -e "  ${DIM}$caption${NC}"
        echo -en "  ${C}Press ENTER to dismiss image >${NC}  "
        read -r
        kill $pid 2>/dev/null || true
    elif command -v xdg-open &>/dev/null; then
        echo -e "  ${DIM}Image: $img${NC}"
        [[ -n "$caption" ]] && echo -e "  ${DIM}$caption${NC}"
        echo -en "  ${C}Press ENTER to continue >${NC}  "
        read -r
    else
        [[ -n "$caption" ]] && echo -e "  ${DIM}$caption${NC}"
    fi
}

# -- Helper functions for complex commands ------------------------------------
_save_dedup_baseline() {
    $K get apigeeapi weather-api -o jsonpath='{.status.proxyRevision}' > /tmp/.dedup-rev-before 2>/dev/null
    wc -l < "$OPERATOR_LOG" > /tmp/.dedup-baseline 2>/dev/null || echo 0 > /tmp/.dedup-baseline
    echo "Current revision: $(cat /tmp/.dedup-rev-before)"
}

_fire_dedup_patches() {
    for i in 1 2 3 4 5; do
        kubectl patch apigeeapi weather-api --type=merge \
            -p "{\"spec\":{\"description\":\"intern-fix-${i}\"}}" &
    done
    wait
    echo "All 5 patches submitted simultaneously"
}

_dedup_check() {
    local before after
    before=$(cat /tmp/.dedup-rev-before 2>/dev/null || echo '?')
    after=$($K get apigeeapi weather-api -o jsonpath='{.status.proxyRevision}' 2>/dev/null || echo '?')
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
    local baseline
    baseline=$(cat /tmp/.dedup-baseline 2>/dev/null || echo 0)
    echo "  Operator log (new lines):"
    tail -n +"$baseline" $OPERATOR_LOG 2>/dev/null | grep -m 5 -i -e Created -e Updated -e synced -e proxy || echo "  (waiting for log flush)"
}

# -- Log streaming setup -----------------------------------------------------
OPERATOR_NS="apigee-api-operator-system"
OPERATOR_LOG="/tmp/operator-test.log"
LOG_STREAM_PID=""

_start_log_stream() {
    local pod
    pod=$(kubectl get pods -n "$OPERATOR_NS" -l app=apigee-api-operator \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$pod" ]]; then
        echo -e "   ${DIM}Operator pod: ${pod}${NC}"
        kubectl logs -n "$OPERATOR_NS" "$pod" --since=1h 2>/dev/null > "$OPERATOR_LOG"
        kubectl logs -n "$OPERATOR_NS" "$pod" --follow 2>/dev/null >> "$OPERATOR_LOG" &
        LOG_STREAM_PID=$!
        echo -e "   ${G}Log stream running (PID ${LOG_STREAM_PID})${NC}"
    elif [[ -f "$OPERATOR_LOG" ]]; then
        echo -e "   ${DIM}Using existing log file: ${OPERATOR_LOG}${NC}"
    else
        echo -e "   ${Y}No operator pod found. Continuing -- log steps will be skipped.${NC}"
        touch "$OPERATOR_LOG"
    fi
}

trap '[[ -n "$LOG_STREAM_PID" ]] && kill "$LOG_STREAM_PID" 2>/dev/null || true' EXIT

# =============================================================================
# PROLOGUE
# =============================================================================
clear
echo ""
echo -e "${C}$(printf '=%.0s' $(seq 1 58))${NC}"
echo -e "${C}${BOLD}  The Life of an API                                 ${NC}"
echo -e "${DIM}  A Kubernetes Operator Story  |  30 min              ${NC}"
echo -e "${C}$(printf '=%.0s' $(seq 1 58))${NC}"
echo ""
echo -e "  ${BOLD}The Story:${NC}"
echo -e "  ${DIM}Act 1. The Birth -- deploying the weather API${NC}"
echo -e "  ${DIM}Act 2. The Eager Intern -- idempotency saves the day${NC}"
echo -e "  ${DIM}Act 3. Growing Pains -- adding rate limiting live${NC}"
echo -e "  ${DIM}Act 4. The Sunset -- decommissioning with finalizers${NC}"
echo -e "  ${DIM}Act 5. The 3am Incident -- drift detection${NC}"
echo -e "  ${DIM}Act 6. The Empire -- scaling to a fleet${NC}"
echo ""
echo -en "  ${C}Press ENTER to begin the story >${NC}  "
read -r
clear

_start_log_stream
sleep 1

# -- Prologue narration -------------------------------------------------------
narrator "Monday morning. 9:17 AM."
say "Slack notification from the product team:"
echo ""
echo -e "  ${BOLD}${R}@channel${NC} ${BOLD}We need a weather API live on Apigee by end of day.${NC}"
echo -e "  ${BOLD}Backend: https://wttr.in  |  Priority: HIGH${NC}"
echo ""

ask "How would you do this manually?"

say "The old way:"
echo ""
diagram "  \$ gcloud apigee apis create weather-api ...
  \$ zip -r proxy-bundle.zip apiproxy/
  \$ curl -X POST .../apis?action=import -F file=@proxy-bundle.zip
  \$ gcloud apigee apis deploy --api=weather-api --revision=1 ...
  \$ curl https://gateway/weather/London   # pray it works
  \$ # ... update the wiki, Slack the team, hope nothing breaks

  6 commands. 15 minutes. Manual verification. Hope."

say "The operator way:"
echo ""
diagram "  \$ kubectl apply -f weather-api.yaml

  1 YAML. 15 seconds. Done."

show_image "$DEMO_IMAGES/prologue.png" "The old way vs the operator way"

next

# =============================================================================
# ACT 1 -- THE BIRTH
# =============================================================================
act "1" "The Birth" "0:00 -> 5:00"

narrator "Let's deploy this API."

say "An operator is a controller that manages a custom resource."
say "Think of it like a thermostat, but for infrastructure:"
echo ""

diagram "  Thermostat:                        Operator:
  --------------------------------  -----------------------------
  Desired: 22C (you set it)         Desired: API proxy on Apigee
  Actual:  18C (sensor reads it)    Actual:  does the proxy exist?
  Action:  turn on heater           Action:  create + deploy proxy
  Loop:    check again in 30s       Loop:    check again in 30s

  The thermostat does not remember events.
  It reads the thermometer. If the room is cold, it acts.
  An operator works the same way."

section "The YAML -- this is ALL you write"

run_and_pause "cat $DEMO_EXAMPLES/weather-api.yaml" \
    "The complete API specification:"

say "5 fields. Organization, environment, basePath, targetUrl, description."
say "Kubernetes validates this BEFORE the operator even sees it."
echo ""

section "Deploy it"

run_step "kubectl delete apigeeapi --all --ignore-not-found 2>/dev/null; sleep 2" \
    "Clean slate:"

run_step "$K apply -f $DEMO_EXAMPLES/weather-api.yaml" \
    "Apply the weather API:"

run_watch "$K get aapi -w" \
    "Watch the phases: Creating -> Deploying -> Ready (Ctrl+C when Ready):"

show_image "$DEMO_IMAGES/act1-launch.png" "The control loop brought our API to life"

section "It's alive -- hit the real weather API"

run_and_pause "curl -s ${BASE_URL}/weather/London?format=3" \
    "Real weather data, routed through Apigee:"

run_and_pause "$K describe apigeeapi weather-api" \
    "Full status -- the operator reports everything:"

section "How did that work? The control loop."

diagram "  OBSERVE -> DIFF -> ACT -> repeat forever

  1. Informer watches the Kubernetes API via TCP stream (not polling)
  2. Your 'kubectl apply' triggers an ADDED event
  3. Event handler enqueues the KEY: 'default/weather-api'
  4. Worker pops the key, reads CURRENT state from cache
  5. Diff: desired=proxy on Apigee, actual=no proxy -> ACT
  6. Creates proxy bundle, uploads to Apigee, deploys, updates status
  7. Done. Loops back. Waits for next trigger."

say "The worker reads CURRENT state -- not the event payload."
say "This is what makes it level-triggered, like the thermostat."
say "It does not care what CHANGED. It reads what IS."

next

# =============================================================================
# ACT 2 -- THE EAGER INTERN
# =============================================================================
act "2" "The Eager Intern" "5:00 -> 12:00"

narrator "The API is live! The team celebrates."
narrator "Then... the intern notices a typo in the description."

say "They patch it. Wait, that was wrong too. Patch again."
say "And again. 5 times in 10 seconds."
echo ""

ask "What happens when you update a CR 5 times in 10 seconds?"

say "In an early version of this operator, each update triggered a full sync."
say "Each sync created a NEW revision on Apigee."
echo ""

diagram "  The bug:
  syncHandler runs -> updateStatus -> triggers Update event
  -> UpdateFunc fires -> enqueue -> syncHandler runs again
  -> createProxy -> NEW revision -> updateStatus -> ...

  Result: 93 proxy revisions created in 3 minutes.
  Apigee was NOT happy."

section "The fix: generation + deduplication"

say "Fix 1: UpdateFunc only re-enqueues if spec changed (generation bump)."
say "Status-only writes do NOT increment generation. Loop broken."
echo ""
say "Fix 2: The workqueue stores KEYS, not objects."
say "If 5 events arrive for the same key while the worker is busy,"
say "the queue holds ONE entry. Worker reads CURRENT state. Syncs ONCE."
echo ""

diagram "  Intern patches 5 times:
  Patch 1 -->  queue: [default/weather-api]   <- worker grabs this
  Patch 2 -->  queue: [default/weather-api]   <- arrives while busy
  Patch 3 -->  queue: [default/weather-api]   <- same key, deduped
  Patch 4 -->  queue: [default/weather-api]   <- same key, deduped
  Patch 5 -->  queue: [default/weather-api]   <- same key, deduped

  Worker finishes sync 1, pops key ONCE more, reads latest state.
  Result: 5 patches, ~2 Apigee API calls (not 5)."

section "Live: let the intern loose"

run_step "_save_dedup_baseline" \
    "Record the current revision:"

run_step "_fire_dedup_patches" \
    "Fire 5 patches simultaneously (the intern goes wild):"

run_and_pause "sleep 20 && _dedup_check" \
    "Compare revisions -- deduplication proof:"

section "Plot twist"

narrator "Wait -- the intern also changed the basePath by accident."

say "But here is the key insight: the operator is LEVEL-TRIGGERED."
say "It reads the CURRENT state, not the event that triggered it."
say "If the intern's last patch had the wrong basePath,"
say "the operator deployed that -- because that IS the desired state now."
echo ""
say "Edge-triggered systems replay events in order."
say "Level-triggered systems read the thermometer. Last state wins."
say "To fix: apply the correct YAML. The operator converges again."

next

# =============================================================================
# ACT 3 -- GROWING PAINS
# =============================================================================
act "3" "Growing Pains" "12:00 -> 17:00"

narrator "Weeks pass. The weather API is a hit."
narrator "10,000 requests per hour are hammering the backend."

say "The backend team calls: 'Our servers are melting. Add rate limiting.'"
echo ""

show_image "$DEMO_IMAGES/act3-ratelimit.png" "We need to protect the backend"

section "This is a Day 2 operation"

say "The API is already running in production."
say "We need to add policies WITHOUT redeploying from scratch."
say "Just update the YAML and re-apply."
echo ""

run_and_pause "cat $DEMO_EXAMPLES/weather-api-ratelimited.yaml" \
    "Same API, now with SpikeArrest + Quota policies:"

say "Two new lines in the spec. That is the ENTIRE change."
echo ""

run_step "$K apply -f $DEMO_EXAMPLES/weather-api-ratelimited.yaml" \
    "Apply the updated spec -- operator handles the rest:"

run_watch "$K get aapi -w" \
    "Watch the operator update the proxy in place (Ctrl+C when Ready):"

section "Prove rate limiting works"

say "Hitting the API rapidly until we get a 429 Too Many Requests..."
echo ""

run_and_pause "for i in 1 2 3 4 5 6 7 8 9 10; do printf \"Request \$i: \"; curl -s -o /dev/null -w \"%{http_code}\" ${BASE_URL}/weather/London?format=3; echo; sleep 0.3; done" \
    "10 rapid requests -- watch for 429 rate limit responses:"

section "Plot twist: the product team is not happy"

narrator "'Why are customers getting 429 errors?!'"

say "You open kubectl describe and show them the policies."
say "SpikeArrest: 30 per minute. Quota: 1000 per day. All in the spec."
say "The YAML is the source of truth. Not a wiki page. Not someone's memory."
echo ""

run_and_pause "$K get apigeeapi weather-api -o jsonpath='{.spec.policies}' | python3 -m json.tool" \
    "The policies, straight from the Kubernetes API:"

say "Crisis averted. Operators handle Day 2 operations, not just Day 1."

next

# =============================================================================
# ACT 4 -- THE SUNSET
# =============================================================================
act "4" "The Sunset" "17:00 -> 22:00"

narrator "Months pass. Weather API v2 is in development."
narrator "Time to decommission v1."

say "When you delete a Pod, Kubernetes garbage-collects its children."
say "But Apigee proxies live OUTSIDE the cluster -- on Google Cloud."
say "Kubernetes GC cannot reach them."
echo ""

diagram "  Without Finalizer:
  kubectl delete apigeeapi weather-api
  -> K8s object gone
  -> Apigee proxy still running on GCP
  -> Orphaned. Costs money. Forever.

  With Finalizer:
  kubectl delete apigeeapi weather-api
  -> K8s sets DeletionTimestamp (object paused, not deleted yet)
  -> Operator sees DeletionTimestamp
  -> Calls Apigee REST API: undeploy + delete proxy
  -> Removes finalizer
  -> K8s completes deletion

  No orphans. No surprise bills."

section "Watch the finalizer in action"

run_and_pause "$K get apigeeapi weather-api -o jsonpath='{.metadata.finalizers}' && echo" \
    "The finalizer is registered on the object:"

run_and_pause "$K delete apigeeapi weather-api" \
    "Delete -- watch it BLOCK until Apigee is cleaned up:"

run_and_pause "$K get aapi" \
    "Gone from Kubernetes AND Apigee:"

ask "What if the operator crashes DURING the finalizer?"

say "The thermostat analogy: restart the operator, it reads state."
say "DeletionTimestamp is STILL set on the object. The finalizer re-runs."
say "No event needed. No crash recovery logic. The loop IS the recovery."
say "This is why finalizers MUST be idempotent -- they may run more than once."

next

# =============================================================================
# ACT 5 -- THE 3AM INCIDENT
# =============================================================================
act "5" "The 3am Incident" "22:00 -> 28:00"

narrator "Weather API v2 is deployed. Secured with API key verification."
narrator "The team goes home. Everything is fine."

run_step "$K apply -f $DEMO_EXAMPLES/weather-api-v2.yaml" \
    "Deploy weather-api-v2 with API key security:"

run_watch "$K get aapi -w" \
    "Wait for Ready (Ctrl+C when Ready):"

run_and_pause "$K get aapi" \
    "Production state -- v2 is live and secured:"

narrator "3:00 AM. A colleague is doing quarterly cleanup."
narrator "They open the Apigee console. They see old proxies."
narrator "They accidentally delete... weather-api-v2."

show_image "$DEMO_IMAGES/act5-3am.png" "The 3am incident"

say "Traffic starts returning 404. Nobody gets paged."
say "Kubernetes still shows Phase=Ready. The status is STALE."
echo ""
say "An edge-triggered webhook would never catch this."
say "Nobody told Kubernetes. No event was fired."
echo ""
say "But the thermostat does not need an event."
say "Every 30 seconds, it reads the sensor: does the proxy exist?"
say "If not -- re-create it. Automatically."

section "Watch it happen live"

say "I am going to switch to the Apigee console and delete the proxy."
say "Watch the operator logs here. Within 30 seconds, you will see:"
say "DRIFT DETECTED -> re-create -> deploy -> Ready."
echo ""

run_watch "$K logs -n apigee-api-operator-system -l app=apigee-api-operator -f --tail=1" \
    "Operator logs live -- I will delete the proxy now. Ctrl+C after self-heal:"

section "Verify the self-healing"

run_and_pause "$K get aapi" \
    "Back to Ready -- the operator healed itself:"

run_and_pause "$K describe apigeeapi weather-api-v2 | tail -15" \
    "Events tell the story -- DriftDetected then Synced:"

section "Plot twist: nobody noticed"

narrator "The colleague wakes up the next morning."
narrator "Checks their email. No PagerDuty alert. No incident report."
narrator "They have no idea they caused an outage."
narrator "Because there WAS no outage. The operator fixed it in 5 seconds."

say "Zero humans. Zero alerts. The loop IS the recovery."
echo ""

diagram "  1. Proxy deleted outside Kubernetes
  2. 30 seconds later: informer periodic resync
  3. Operator calls GetProxy -- 404 Not Found
  4. DRIFT DETECTED -- warning event emitted
  5. CreateProxyWithBundle -- new revision uploaded
  6. DeployRevision -- deployed to environment
  7. Status: Phase=Ready, Deployed=true

  Total recovery time: ~5 seconds after detection
  Human intervention required: ZERO"

next

# =============================================================================
# ACT 6 -- THE EMPIRE
# =============================================================================
act "6" "The Empire" "28:00 -> 32:00"

narrator "The weather API was a success."
narrator "Now the team is building a platform: orders, payments, notifications."

say "One operator binary. N resources. Each API is a YAML file in git."
say "Platform team owns the operator. App teams own the YAMLs."
echo ""

section "Deploy the fleet"

run_step "$K apply \
  -f $DEMO_EXAMPLES/orders-api.yaml \
  -f $DEMO_EXAMPLES/payments-api.yaml \
  -f $DEMO_EXAMPLES/notifications-api.yaml" \
    "Apply 3 new APIs at once:"

run_watch "$K get aapi -w" \
    "Watch all APIs deploy in parallel (Ctrl+C when all Ready):"

run_and_pause "$K get aapi" \
    "The fleet -- all managed by one operator:"

section "Each API has its own policies"

run_and_pause "$K get apigeeapi payments-api -o jsonpath='{.spec.policies}' | python3 -m json.tool" \
    "Payments API -- burst protection with SpikeArrest:"

run_and_pause "$K get apigeeapi notifications-api -o jsonpath='{.spec.policies}' | python3 -m json.tool" \
    "Notifications API -- daily quota cap:"

say "Each team defines their own policies in their own YAML."
say "The operator enforces them uniformly. GitOps-ready."

next

# =============================================================================
# EPILOGUE
# =============================================================================
clear
echo ""
echo -e "${C}$(printf '=%.0s' $(seq 1 58))${NC}"
echo -e "${C}${BOLD}  The Moral of the Story                             ${NC}"
echo -e "${C}$(printf '=%.0s' $(seq 1 58))${NC}"
echo ""

show_image "$DEMO_IMAGES/epilogue.png" "The Life of an API"

echo -e "  ${BOLD}You just watched an API:${NC}"
echo ""
echo -e "  ${G}Act 1${NC}  Be born from a single YAML"
echo -e "  ${Y}Act 2${NC}  Survive an intern's 5 rapid patches"
echo -e "  ${R}Act 3${NC}  Get rate-limited when traffic spiked"
echo -e "  ${M}Act 4${NC}  Be decommissioned with guaranteed cleanup"
echo -e "  ${C}Act 5${NC}  Come back from the dead at 3am"
echo -e "  ${B}Act 6${NC}  Scale to a fleet of services"
echo ""
echo -e "  ${BOLD}All without a single manual step.${NC}"
echo ""
echo -e "  ${DIM}The operator is the thermostat.${NC}"
echo -e "  ${DIM}It reads the sensor. It converges. It does not sleep.${NC}"
echo ""
echo -e "${C}$(printf '=%.0s' $(seq 1 58))${NC}"
echo -e "  ${BOLD}Q&A                                          3 min${NC}"
echo -e "${C}$(printf '=%.0s' $(seq 1 58))${NC}"
echo ""

# -- Cleanup ------------------------------------------------------------------
echo -en "  ${Y}Delete all demo APIs? [y/N] >${NC}  "
read -r CLEANUP
if [[ "$CLEANUP" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "  ${DIM}Running finalizers -- cleaning up Apigee resources...${NC}"
    $K delete apigeeapi --all --ignore-not-found
    echo -e "  ${G}All demo APIs deleted from Kubernetes and Apigee${NC}"
fi
echo ""

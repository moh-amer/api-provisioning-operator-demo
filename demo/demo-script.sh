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
    local title="$1"
    clear
    echo ""
    echo -e "${C}$(printf '=%.0s' $(seq 1 58))${NC}"
    printf "${C}${BOLD}  %-54s${NC}\n" "$title"
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

# -- ASCII Art for story moments -----------------------------------------------
_art_prologue() {
    echo ""
    echo -e "${R}${BOLD}  +---------------------------+  ${G}${BOLD}+---------------------------+${NC}"
    echo -e "${R}${BOLD}  |      THE OLD WAY          |  ${G}${BOLD}|    THE OPERATOR WAY       |${NC}"
    echo -e "${R}${BOLD}  +---------------------------+  ${G}${BOLD}+---------------------------+${NC}"
    echo -e "${R}  |                           |  ${G}|                           |${NC}"
    echo -e "${R}  |  \$ gcloud apis create..   |  ${G}|  \$ kubectl apply -f api   |${NC}"
    echo -e "${R}  |  \$ zip -r bundle.zip ..   |  ${G}|                           |${NC}"
    echo -e "${R}  |  \$ curl -X POST import..  |  ${G}|  apiVersion: v1alpha1     |${NC}"
    echo -e "${R}  |  \$ gcloud apis deploy..   |  ${G}|  kind: ApigeeAPI          |${NC}"
    echo -e "${R}  |  \$ curl ... /weather ..   |  ${G}|  spec:                    |${NC}"
    echo -e "${R}  |  \$ # update wiki, pray..  |  ${G}|    basePath: /weather      |${NC}"
    echo -e "${R}  |                           |  ${G}|    targetUrl: wttr.in      |${NC}"
    echo -e "${R}  |  ${BOLD}6 commands${NC}${R}                |  ${G}|                           |${NC}"
    echo -e "${R}  |  ${BOLD}15 minutes${NC}${R}                |  ${G}|  ${BOLD}1 YAML${NC}${G}                    |${NC}"
    echo -e "${R}  |  ${BOLD}Manual verification${NC}${R}       |  ${G}|  ${BOLD}15 seconds${NC}${G}                |${NC}"
    echo -e "${R}  |  ${BOLD}Hope${NC}${R}                      |  ${G}|  ${BOLD}Automated${NC}${G}                 |${NC}"
    echo -e "${R}  |                           |  ${G}|                           |${NC}"
    echo -e "${R}  +---------------------------+  ${G}+---------------------------+${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to continue >${NC}  "
    read -r
}

_art_launch() {
    echo ""
    echo -e "${C}${BOLD}         .---.                                              ${NC}"
    echo -e "${C}${BOLD}        ( o o )    weather-api                               ${NC}"
    echo -e "${C}${BOLD}        |  >  |                                              ${NC}"
    echo -e "${C}${BOLD}         '---'                                               ${NC}"
    echo -e "${DIM}           |                                                   ${NC}"
    echo -e "${DIM}           v                                                   ${NC}"
    echo -e "${Y}    +-- kubectl apply -f weather-api.yaml --+                  ${NC}"
    echo -e "${DIM}           |                                                   ${NC}"
    echo -e "${DIM}           v                                                   ${NC}"
    echo -e "${Y}    [ Creating... ]${NC} ----> ${B}[ Deploying... ]${NC} ----> ${G}[ Ready! ]${NC}"
    echo -e "${DIM}                                                               ${NC}"
    echo -e "${DIM}      Proxy bundle       Apigee REST API       Traffic flows   ${NC}"
    echo -e "${DIM}      generated           upload + deploy       /weather/London ${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to continue >${NC}  "
    read -r
}

_art_ratelimit() {
    echo ""
    echo -e "${R}${BOLD}  >>>>>>>>>>>>>>>>>>          ${Y}${BOLD}+===========+${NC}          ${G}${BOLD}           ${NC}"
    echo -e "${R}${BOLD}  >>>>>>>>>>>>>>>>>>    ${NC}     ${Y}${BOLD}|           |${NC}          ${G}${BOLD}   __|__   ${NC}"
    echo -e "${R}${BOLD}  >>> 10,000 req/h >    ${NC}     ${Y}${BOLD}|  SHIELD   |${NC}   -----> ${G}${BOLD}  |     |  ${NC}"
    echo -e "${R}${BOLD}  >>>>>>>>>>>>>>>>>>    ${NC}     ${Y}${BOLD}|           |${NC}          ${G}${BOLD}  | API |  ${NC}"
    echo -e "${R}${BOLD}  >>>>>>>>>>>>>>>>>>    ${NC}     ${Y}${BOLD}| Spike:6pm |${NC}          ${G}${BOLD}  |_____|  ${NC}"
    echo -e "${R}${BOLD}  >>>>>>>>>>>>>>>>>>    ${NC}     ${Y}${BOLD}| Quota:5/m |${NC}          ${G}${BOLD}           ${NC}"
    echo -e "${R}${BOLD}  >>>>>>>>>>>>>>>>>>    ${NC}     ${Y}${BOLD}|           |${NC}          ${G}${BOLD}  Backend  ${NC}"
    echo -e "${R}${BOLD}  >>>>>>>>>>>>>>>>>>    ${NC}     ${Y}${BOLD}+===========+${NC}          ${G}${BOLD} Protected ${NC}"
    echo ""
    echo -e "${DIM}  Flood of requests        SpikeArrest + Quota      Only safe traffic${NC}"
    echo -e "${DIM}  hammering backend         blocks the excess         reaches the server${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to continue >${NC}  "
    read -r
}

_art_3am() {
    echo ""
    echo -e "${DIM}  .  *  .    *   .  *  .    *   .  *  .    *   .  *  .  *  ${NC}"
    echo -e "${DIM}     *    .    *    .    *    .    *    .    *    .         ${NC}"
    echo -e "${DIM}  .    *   3:00 AM   *    .    *    .    *    .   *   .    ${NC}"
    echo -e "${DIM}  ........................................................${NC}"
    echo ""
    echo -e "${DIM}     zzZ   zzZ   zzZ              ${C}${BOLD}    +-------+           ${NC}"
    echo -e "${DIM}    __|__ __|__ __|__              ${C}${BOLD}    |  /-\\  |           ${NC}"
    echo -e "${DIM}   | bed || bed || bed |            ${C}${BOLD}    | | K | |           ${NC}"
    echo -e "${DIM}   |_____||_____||_____|            ${C}${BOLD}    |  \\-/  |           ${NC}"
    echo -e "${DIM}    Team sleeping                   ${C}${BOLD}    +---+---+           ${NC}"
    echo -e "${DIM}                                    ${C}${BOLD}        |               ${NC}"
    echo -e "${DIM}                                    ${C}${BOLD}    Operator             ${NC}"
    echo -e "${DIM}                                    ${C}${BOLD}    never sleeps         ${NC}"
    echo ""
    echo -e "${R}    3:00:00  ${BOLD}Proxy deleted${NC}${R}         (someone made a mistake)   ${NC}"
    echo -e "${Y}    3:00:30  ${BOLD}Drift detected${NC}${Y}        (operator reads sensor)    ${NC}"
    echo -e "${G}    3:00:35  ${BOLD}Self-healed${NC}${G}           (proxy re-created + deployed)${NC}"
    echo ""
    echo -e "${G}${BOLD}    Zero humans. Zero alerts. The loop IS the recovery.     ${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to continue >${NC}  "
    read -r
}

_art_epilogue() {
    echo ""
    echo -e "${BOLD}  ================= THE LIFE OF AN API ===================${NC}"
    echo ""
    echo -e "${G}  Birth${NC}     ${Y}Intern${NC}    ${R}Growing${NC}   ${M}Sunset${NC}    ${C}3am${NC}      ${B}Fleet${NC}     ${M}${BOLD}AI${NC}"
    echo -e "${G}   |${NC}  ----->${Y}|${NC}  ----->${R}|${NC}  ----->${M}|${NC}  ----->${C}|${NC}  ----->${B}|${NC}  ----->${M}|${NC}"
    echo -e "${G}   |${NC}        ${Y}|${NC}        ${R}|${NC}        ${M}|${NC}        ${C}|${NC}       ${B}|${NC}       ${M}|${NC}"
    echo -e "${G}  YAML${NC}     ${Y}dedup${NC}    ${R}policies${NC}  ${M}cleanup${NC}  ${C}heal${NC}     ${B}fleet${NC}    ${M}${BOLD}NL→YAML${NC}"
    echo -e "${G}  apply${NC}    ${Y}idmptnt${NC}   ${R}Day 2${NC}    ${M}finalizr${NC} ${C}drift${NC}    ${B}parallel${NC} ${M}${BOLD}English${NC}"
    echo ""
    echo -e "${DIM}  .................................................................${NC}"
    echo -e "${BOLD}  All automated. Zero manual steps. Now AI-assisted too.        ${NC}"
    echo -e "${DIM}  .................................................................${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to continue >  ${NC}"
    read -r
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
echo -e "  ${DIM}1. The Birth -- deploying the weather API${NC}"
echo -e "  ${DIM}2. Growing Pains -- adding rate limiting live${NC}"
echo -e "  ${DIM}3. The Sunset -- decommissioning with finalizers${NC}"
echo -e "  ${DIM}4. The 3am Incident -- drift detection${NC}"
echo -e "  ${DIM}5. The Empire -- scaling to a fleet${NC}"
echo -e "  ${DIM}6. One More Thing... -- AI-powered generation${NC}"
echo ""
echo -en "  ${C}Press ENTER to begin the story >${NC}  "
read -r
clear

_start_log_stream
sleep 1

# -- Prologue narration -------------------------------------------------------
narrator "Monday morning. 9:17 AM."
say "Teams notification from the product team:"
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
  \$ # ... update the wiki, Teams the team, hope nothing breaks

  6 commands. 15 minutes. Manual verification. Hope."

say "The operator way:"
echo ""
diagram "  \$ kubectl apply -f weather-api.yaml

  1 YAML. 15 seconds. Done."

_art_prologue

next

# =============================================================================
# ACT 1 -- THE BIRTH
# =============================================================================
act "The Birth"

narrator "Let's deploy this API."

say "An operator works like a thermostat for infrastructure:"
echo ""

diagram "  Thermostat:                        Operator:
  --------------------------------  -----------------------------
  Desired: 22C (you set it)         Desired: API proxy on Apigee
  Actual:  18C (sensor reads it)    Actual:  does the proxy exist?
  Action:  turn on heater           Action:  create + deploy proxy
  Loop:    check again in 30s       Loop:    check again in 30s

  It reads the sensor. If reality != desired, it acts."

section "The YAML -- this is ALL you write"

run_and_pause "cat $DEMO_EXAMPLES/weather-api.yaml" \
    "The complete API specification:"

say "5 fields. Kubernetes validates this before the operator even sees it."
echo ""

section "Deploy it"

run_step "kubectl delete apigeeapi --all --ignore-not-found 2>/dev/null; sleep 2" \
    "Clean slate:"

run_step "$K apply -f $DEMO_EXAMPLES/weather-api.yaml" \
    "Apply the weather API:"

run_watch "$K get aapi -w" \
    "Watch the phases: Creating -> Deploying -> Ready (Ctrl+C when Ready):"

_art_launch

section "It's alive -- hit the real weather API"

run_and_pause "curl -s --connect-timeout 3 --max-time 5 ${BASE_URL}/weather/London?format=3" \
    "Real weather data, routed through Apigee:"

run_and_pause "$K describe apigeeapi weather-api" \
    "Full status -- the operator reports everything:"

section "How did that work?"

say "Let's look at what the operator actually did:"
echo ""

run_and_pause "$K logs -n apigee-api-operator-system -l app=apigee-api-operator --tail=15" \
    "The operator's own log -- the real story:"

diagram "  You wrote YAML.
  The operator saw it, built the proxy, uploaded it, deployed it.
  If you delete the YAML, it cleans up. If someone breaks it, it fixes it.
  That's the entire pattern: OBSERVE -> DIFF -> ACT -> repeat."

next

# =============================================================================
# ACT 3 -- GROWING PAINS
# =============================================================================
act "Growing Pains"

narrator "10,000 requests/hour. The backend team says: add rate limiting."

_art_ratelimit

section "Day 2 operation"

say "API is in production. Just add policies to the YAML and re-apply."
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

run_and_pause "for i in 1 2 3 4 5 6 7 8 9 10; do printf \"Request \$i: \"; curl -s --connect-timeout 3 --max-time 5 -o /dev/null -w \"%{http_code}\" ${BASE_URL}/weather/London?format=3; echo; sleep 0.3; done" \
    "10 rapid requests -- watch for 429 rate limit responses:"

section "The product team pushes back"

narrator "'Why are customers getting 429 errors?!'"

say "The YAML is the source of truth. Show them the policies:"
echo ""

run_and_pause "$K get apigeeapi weather-api -o yaml" \
    "Full resource -- see the policies in the spec:"

say "Operators handle Day 2, not just Day 1."

next

# =============================================================================
# ACT 4 -- THE SUNSET
# =============================================================================
act "The Sunset"

narrator "Time to decommission v1. But Apigee proxies live outside the cluster."

say "Kubernetes GC can't reach them. Without a finalizer, you get orphans."
echo ""

diagram "  Without Finalizer:               With Finalizer:
  kubectl delete -> K8s gone       kubectl delete -> DeletionTimestamp set
  Apigee proxy still running       Operator: undeploy + delete on Apigee
  Orphaned. Costs money.           Remove finalizer -> K8s completes deletion"

section "Watch the finalizer in action"

run_and_pause "$K get apigeeapi weather-api -o yaml" \
    "Full resource -- notice the finalizer in metadata:"

run_and_pause "$K delete apigeeapi weather-api" \
    "Delete -- watch it BLOCK until Apigee is cleaned up:"

run_and_pause "$K get aapi" \
    "Gone from Kubernetes AND Apigee:"

ask "What if the operator crashes mid-finalizer?"

say "DeletionTimestamp persists. On restart, the finalizer re-runs."
say "The loop IS the recovery. Finalizers must be idempotent."

next

# =============================================================================
# ACT 5 -- THE 3AM INCIDENT
# =============================================================================
act "The 3am Incident"

narrator "V2 deployed. Team goes home."

run_step "$K apply -f $DEMO_EXAMPLES/weather-api-v2.yaml" \
    "Deploy weather-api-v2 with API key security:"

run_watch "$K get aapi -w" \
    "Wait for Ready (Ctrl+C when Ready):"

run_and_pause "$K get aapi" \
    "Production state -- v2 is live:"

narrator "3:00 AM. A colleague accidentally deletes weather-api-v2 from the Apigee console."

_art_3am

say "No event was fired to Kubernetes. An edge-triggered system would never notice."
say "But every 30 seconds, the operator checks: does the proxy exist? If not -- re-create."

section "Watch it happen live"

say "I'll delete the proxy from Apigee. Watch the logs for: DRIFT DETECTED -> re-create -> Ready."
echo ""

run_watch "$K logs -n apigee-api-operator-system -l app=apigee-api-operator -f --tail=1" \
    "Operator logs live -- I will delete the proxy now. Ctrl+C after self-heal:"

section "Verify the self-healing"

run_and_pause "$K get aapi" \
    "Back to Ready -- the operator healed itself:"

run_and_pause "$K describe apigeeapi weather-api-v2 | tail -15" \
    "Events tell the story -- DriftDetected then Synced:"

section "Nobody noticed"

narrator "Next morning. No PagerDuty. No incident report. There was no outage."

say "Zero humans. Zero alerts. The loop IS the recovery."
echo ""

diagram "  Proxy deleted -> resync detects 404 -> re-create -> deploy -> Ready
  Recovery: ~5 seconds. Human intervention: ZERO"

next

# =============================================================================
# ACT 6 -- THE EMPIRE
# =============================================================================
act "The Empire"

narrator "Platform is growing: orders, payments, notifications."

say "One operator. N APIs. Each is a YAML in git. Platform team owns the operator, app teams own the YAMLs."
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

run_and_pause "$K get apigeeapi payments-api -o yaml" \
    "Payments API -- see the SpikeArrest policy in the spec:"

run_and_pause "$K get apigeeapi notifications-api -o yaml" \
    "Notifications API -- see the Quota policy in the spec:"

say "Each team owns their policies. The operator enforces them uniformly. GitOps-ready."

next

# =============================================================================
# ACT 7 -- ONE MORE THING (AI-POWERED GENERATION)
# =============================================================================
act "One More Thing..."

narrator "Everything you've seen so far starts with YAML."
say "You write the YAML. The operator handles the rest."
echo ""
say "But what if you didn't even have to write the YAML?"
echo ""
sleep 1

section "AI meets the Operator"

narrator "Let me just tell the AI what I want... in plain English."

echo ""
echo -e "${M}${BOLD}  ┌──────────────────────────────────────────────────────┐${NC}"
echo -e "${M}${BOLD}  │                                                      │${NC}"
echo -e "${M}${BOLD}  │${NC}  ${BOLD} Human   ${NC}---->  ${M}AI (LLM)${NC}  ---->  ${G}YAML${NC}  ---->  ${C}Operator${NC}  ${M}${BOLD}│${NC}"
echo -e "${M}${BOLD}  │${NC}                                                      ${M}${BOLD}│${NC}"
echo -e "${M}${BOLD}  │${NC}  ${DIM}\"I need a         generates      deploys to    self-heals${NC}  ${M}${BOLD}│${NC}"
echo -e "${M}${BOLD}  │${NC}  ${DIM} weather API       valid CRD      Apigee       + protects${NC}   ${M}${BOLD}│${NC}"
echo -e "${M}${BOLD}  │${NC}  ${DIM} with rate                                              ${NC}  ${M}${BOLD}│${NC}"
echo -e "${M}${BOLD}  │${NC}  ${DIM} limiting\"                                              ${NC}  ${M}${BOLD}│${NC}"
echo -e "${M}${BOLD}  │                                                      │${NC}"
echo -e "${M}${BOLD}  └──────────────────────────────────────────────────────┘${NC}"
echo ""
echo -en "  ${C}Press ENTER to continue >${NC}  "
read -r

section "Live: Natural Language → YAML → Deploy"

say "Watch this. One English sentence. No YAML knowledge needed."
echo ""

# Check if apilot is available
if command -v apilot &>/dev/null; then
    run_and_pause "apilot generate \"weather API at wttr.in with rate limiting at 6 per minute and quota 5 per minute\" --org ${PROJECT} --env eval --apply" \
        "AI generates the YAML from English:"

    say "The AI understood the intent, picked the right policies, set the correct"
    say "config values, and generated a valid Kubernetes CRD. In 3 seconds."
    echo ""

    narrator "Now let's deploy it with kubectl -- same operator, same loop."

    run_step "apilot generate \"secure payments API with API key auth and strict rate limiting\" --org ${PROJECT} --env eval --apply | $K apply -f -" \
        "From English to live API in one command:"

    run_watch "$K get aapi -w" \
        "Watch it deploy (Ctrl+C when Ready):"

    say "English sentence → AI → YAML → Operator → Live API on Apigee."
    say "The entire pipeline. No human wrote a single line of YAML."
else
    # Fallback: show what it would look like
    echo -e "  ${Y}${BOLD}apilot is not installed. Showing what the command looks like:${NC}"
    echo ""
    echo -e "  ${BOLD}\$ apilot generate \"weather API at wttr.in with rate limiting\"${NC}"
    echo ""
    echo -e "  ${DIM}The AI would generate a valid ApigeeAPI YAML, and you'd review + apply.${NC}"
    echo -e "  ${DIM}Install with: make build-cli${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to continue >${NC}  "
    read -r
fi
echo ""

section "The Full Stack"

echo -e "  ${BOLD}What we just demonstrated:${NC}"
echo ""
echo -e "  ${M}1.${NC}  ${BOLD}AI generates${NC}    valid Kubernetes YAML from plain English"
echo -e "  ${G}2.${NC}  ${BOLD}CRD validates${NC}   schema, types, enums before the operator sees it"
echo -e "  ${C}3.${NC}  ${BOLD}Operator deploys${NC} to Apigee via REST API (bundle + deploy)"
echo -e "  ${Y}4.${NC}  ${BOLD}Self-heals${NC}      if anything drifts (3am incident)"
echo -e "  ${B}5.${NC}  ${BOLD}Finalizers${NC}      clean up when you delete"
echo ""
echo -e "  ${DIM}AI → Kubernetes → Operator → Cloud.${NC}"
echo -e "  ${DIM}The full stack of API automation.${NC}"
echo ""
echo -en "  ${C}Press ENTER to continue >${NC}  "
read -r

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

_art_epilogue

echo -e "  ${BOLD}You just watched an API:${NC}"
echo ""
echo -e "  ${G}1.${NC}  Be born from a single YAML"
echo -e "  ${Y}2.${NC}  Get rate-limited when traffic spiked"
echo -e "  ${R}3.${NC}  Be decommissioned with guaranteed cleanup"
echo -e "  ${M}4.${NC}  Come back from the dead at 3am"
echo -e "  ${C}5.${NC}  Scale to a fleet of services"
echo -e "  ${M}6.${NC}  Be generated from plain English by AI"
echo ""
echo -e "  ${BOLD}All without a single manual step. Now with AI superpowers.${NC}"
echo ""
echo -e "  ${DIM}The operator is the thermostat. The AI is the voice assistant.${NC}"
echo -e "  ${DIM}\"Hey operator, I need a weather API\" — and it just happens.${NC}"
echo ""
echo -e "${C}$(printf '=%.0s' $(seq 1 58))${NC}"
echo -e "  ${BOLD}Q&A${NC}"
echo -e "${C}$(printf '=%.0s' $(seq 1 58))${NC}"
echo ""

# -- Cleanup ------------------------------------------------------------------
echo -en "  ${Y}Delete all demo APIs? [y/N] >${NC}  "
read -r CLEANUP
if [[ "$CLEANUP" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "  ${DIM}Running finalizers -- cleaning up Apigee resources...${NC}"
    echo ""

    # Joke: the operator doesn't want to let go
    sleep 0.5
    echo -e "  ${Y}  Operator:  ${BOLD}\"Wait... you're deleting ALL of them?\"${NC}"
    sleep 1
    echo -e "  ${Y}  Operator:  ${BOLD}\"I JUST deployed those!\"${NC}"
    sleep 1
    echo -e "  ${Y}  Operator:  ${BOLD}\"Fine. But I'm cleaning up properly.\"${NC}"
    sleep 0.5
    echo -e "  ${Y}  Operator:  ${BOLD}\"Because THAT'S what finalizers are for.\"${NC}"
    sleep 1
    echo ""

    $K delete apigeeapi --all --ignore-not-found
    echo ""

    sleep 0.5
    echo -e "  ${G}  Operator:  ${BOLD}\"All clean. No orphans. No surprise bills.\"${NC}"
    sleep 1
    echo -e "  ${C}  Operator:  ${BOLD}\"You know I'll just reconcile them back if you apply again...\"${NC}"
    sleep 1
    echo -e "  ${M}  Operator:  ${BOLD}\"I never sleep. I never forget. I always converge.\"${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to continue >${NC}  "
    read -r

    # Dramatic goodbye from the APIs
    echo ""
    echo -e "${DIM}  .  *  .    *   .  *  .    *   .  *  .    *   .  *  .  *  ${NC}"
    echo -e "${DIM}     *    .    *    .    *    .    *    .    *    .         ${NC}"
    echo ""
    echo -e "${R}         weather-api     ${Y}orders-api      ${B}payments-api${NC}"
    echo -e "${R}            __|__       ${Y}    __|__       ${B}    __|__${NC}"
    echo -e "${R}           |     |      ${Y}   |     |      ${B}   |     |${NC}"
    echo -e "${R}           | R.I.|      ${Y}   | R.I.|      ${B}   | R.I.|${NC}"
    echo -e "${R}           | P.  |      ${Y}   | P.  |      ${B}   | P.  |${NC}"
    echo -e "${R}           |_____|      ${Y}   |_____|      ${B}   |_____|${NC}"
    echo -e "${DIM}      Undeployed.       Finalized.       Cleaned up.${NC}"
    echo ""
    echo -e "${DIM}   No proxy was harmed without proper finalization.${NC}"
    echo ""
    echo -en "  ${C}Press ENTER to continue >${NC}  "
    read -r
fi

# -- Thank You ----------------------------------------------------------------
clear
echo ""
echo ""
echo -e "${C}${BOLD}   ╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${C}${BOLD}   ║                                                      ║${NC}"
echo -e "${C}${BOLD}   ║${NC}   ${G}${BOLD} _____ _                 _     __   __           ${C}${BOLD}║${NC}"
echo -e "${C}${BOLD}   ║${NC}   ${G}${BOLD}|_   _| |__   __ _ _ __ | | __ \\ \\ / /__  _   _  ${C}${BOLD}║${NC}"
echo -e "${C}${BOLD}   ║${NC}   ${G}${BOLD}  | | | '_ \\ / _\` | '_ \\| |/ /  \\ V / _ \\| | | | ${C}${BOLD}║${NC}"
echo -e "${C}${BOLD}   ║${NC}   ${G}${BOLD}  | | | | | | (_| | | | |   <    | | (_) | |_| | ${C}${BOLD}║${NC}"
echo -e "${C}${BOLD}   ║${NC}   ${G}${BOLD}  |_| |_| |_|\\__,_|_| |_|_|\\_\\   |_|\\___/ \\__,_| ${C}${BOLD}║${NC}"
echo -e "${C}${BOLD}   ║                                                      ║${NC}"
echo -e "${C}${BOLD}   ╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo ""
echo -e "  ${BOLD}The operator pattern:${NC}"
echo -e "  ${DIM}Write the WHAT. Let the operator handle the HOW.${NC}"
echo ""
echo -e "  ${DIM}┌─────────────────────────────────────────────────────┐${NC}"
echo -e "  ${DIM}│${NC}  ${C}${BOLD}          while true {                           ${NC}  ${DIM}│${NC}"
echo -e "  ${DIM}│${NC}  ${C}${BOLD}              observe()                          ${NC}  ${DIM}│${NC}"
echo -e "  ${DIM}│${NC}  ${C}${BOLD}              diff()                             ${NC}  ${DIM}│${NC}"
echo -e "  ${DIM}│${NC}  ${C}${BOLD}              act()                              ${NC}  ${DIM}│${NC}"
echo -e "  ${DIM}│${NC}  ${C}${BOLD}          }                                      ${NC}  ${DIM}│${NC}"
echo -e "  ${DIM}└─────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  ${Y}${BOLD}  \"The best incident is the one nobody noticed.\"${NC}"
echo -e "  ${DIM}                          — A wise operator said at 3am${NC}"
echo ""
echo ""
echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 54))${NC}"
echo -e "  ${M}${BOLD}  Questions?  Let's talk.${NC}"
echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 54))${NC}"
echo ""

#!/usr/bin/env bash
#
# verify-savant-dataplane.sh
#
# Read-only post-install verifier for the savant-dataplane Helm release.
# Run this AFTER `helm install` to confirm the dataplane is healthy end to
# end: structural readiness of every workload, plus a live probe per service
# (HTTP /health, ZooKeeper ruok, Spark master web UI), plus IRSA / WIF
# wiring sanity checks.
#
# This script only calls kubectl get/describe/exec and decodes data the
# cluster already exposes. It does not create, modify, or delete anything.
#
# It does NOT replace the chart README or the AWS setup guide — refer to
# those for the authoritative install procedure. A green run here means
# "the workloads installed and look healthy from inside the cluster"; it
# does not mean "Savant SaaS sees the agent". After a green run, ping
# your Savant account team to finish control-plane registration.
#
# Requirements: kubectl (configured for the target cluster), jq, curl.
#
# Usage:
#   ./verify-savant-dataplane.sh <config-file> [--no-color]
#
# The config file is a shell-sourced KEY=value file. A template is
# provided alongside this script as `savant-verify.conf.example`.
#
# Exit codes:
#   0  all required checks passed (warnings allowed)
#   1  one or more required checks failed
#   2  usage / preflight error

set -u
set -o pipefail

# ----- args -----------------------------------------------------------------

USE_COLOR=1
CONFIG_FILE=""

usage() {
  sed -n '3,32p' "$0"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-color)  USE_COLOR=0; shift ;;
    -h|--help)   usage ;;
    -*)          echo "unknown flag: $1" >&2; usage ;;
    *)
      if [[ -n "$CONFIG_FILE" ]]; then
        echo "unexpected extra argument: $1" >&2; usage
      fi
      CONFIG_FILE="$1"; shift ;;
  esac
done

if [[ -z "$CONFIG_FILE" ]]; then
  echo "error: config file path is required" >&2
  usage
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "error: config file not found: $CONFIG_FILE" >&2
  exit 2
fi

NAMESPACE=""
RELEASE="savant-dataplane"

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ -z "$NAMESPACE" ]]; then
  echo "error: NAMESPACE is required in $CONFIG_FILE" >&2
  echo "see savant-verify.conf.example for the full template" >&2
  exit 2
fi

# ----- tooling preflight ----------------------------------------------------

for tool in kubectl jq curl; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "$tool not found on PATH" >&2; exit 2; }
done

if ! kubectl version --client >/dev/null 2>&1; then
  echo "kubectl appears installed but failed to run" >&2
  exit 2
fi

if ! kubectl auth can-i get pods -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "kubectl cannot get pods in namespace '$NAMESPACE' — check context and RBAC" >&2
  echo "  current context: $(kubectl config current-context 2>/dev/null || echo '<none>')" >&2
  exit 2
fi

# Probe `helm` separately — it's nice to have for stage 1, but the script
# can fall back to inspecting the Secret directly if helm is missing.
HELM_OK=1
if ! command -v helm >/dev/null 2>&1; then
  HELM_OK=0
fi

# ----- output helpers -------------------------------------------------------

if [[ $USE_COLOR -eq 1 && -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'
  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

PASS=0; FAIL=0; WARN=0; SKIP=0

pass() { printf "  ${C_GREEN}[ ✓ ]${C_RESET} %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  ${C_RED}[ ✗ ]${C_RESET} %s${C_DIM}%s${C_RESET}\n" "$1" "${2:+ — $2}"; FAIL=$((FAIL+1)); }
warn() { printf "  ${C_YELLOW}[ ⚠ ]${C_RESET} %s${C_DIM}%s${C_RESET}\n" "$1" "${2:+ — $2}"; WARN=$((WARN+1)); }
skip() { printf "  ${C_DIM}[ - ] %s — %s${C_RESET}\n" "$1" "$2"; SKIP=$((SKIP+1)); }
section() { printf "\n${C_BOLD}%s${C_RESET}\n" "$1"; }

# kubectl wrapper — namespace pinned, stderr suppressed for cleaner output.
k() { kubectl -n "$NAMESPACE" "$@" 2>/dev/null; }
k_describe() { kubectl -n "$NAMESPACE" describe "$@" 2>/dev/null; }

# Run a command inside a pod, suppress stderr unless we want it. Fails
# silently if the container lacks the tool — caller handles the warn.
k_exec() {
  local target=$1; shift
  kubectl -n "$NAMESPACE" exec "$target" -- "$@" 2>/dev/null
}

# Check if a binary exists inside a pod's first container.
pod_has_binary() {
  local target=$1 bin=$2
  k_exec "$target" sh -c "command -v $bin >/dev/null 2>&1 && echo yes" \
    | grep -q '^yes$'
}

# Workload structural readiness.
# Returns 0 if ready, 1 if not. Echoes a short status string for the caller
# to embed in the pass/fail message.
deployment_ready() {
  local name=$1
  local json
  json=$(k get deploy "$name" -o json) || { echo "not found"; return 1; }
  local desired ready avail
  desired=$(echo "$json" | jq -r '.spec.replicas // 0')
  ready=$(echo "$json" | jq -r '.status.readyReplicas // 0')
  avail=$(echo "$json" | jq -r '.status.conditions[]? | select(.type=="Available") | .status' | head -n1)
  if [[ "$ready" == "$desired" && "$avail" == "True" && "$desired" -gt 0 ]]; then
    echo "$ready/$desired ready"
    return 0
  fi
  echo "$ready/$desired ready, Available=$avail"
  return 1
}

statefulset_ready() {
  local name=$1
  local json
  json=$(k get statefulset "$name" -o json) || { echo "not found"; return 1; }
  local desired ready
  desired=$(echo "$json" | jq -r '.spec.replicas // 0')
  ready=$(echo "$json" | jq -r '.status.readyReplicas // 0')
  if [[ "$ready" == "$desired" && "$desired" -gt 0 ]]; then
    echo "$ready/$desired ready"
    return 0
  fi
  echo "$ready/$desired ready"
  return 1
}

# Sweep pods matching a label selector and report bad states.
# Returns 0 if all pods are Running+Ready or Succeeded; 1 otherwise.
pods_clean() {
  local selector=$1
  local pods
  pods=$(k get pods -l "$selector" -o json) || { echo "no pods"; return 1; }
  local count
  count=$(echo "$pods" | jq -r '.items | length')
  if [[ "$count" == "0" ]]; then
    echo "no pods match selector"
    return 1
  fi
  local bad
  bad=$(echo "$pods" | jq -r '
    .items[]
    | . as $p
    | (.status.containerStatuses // [])[]?
    | select(
        (.state.waiting.reason // "") as $r
        | $r == "CrashLoopBackOff" or $r == "ImagePullBackOff"
          or $r == "ErrImagePull" or $r == "CreateContainerError"
          or $r == "Error"
      )
    | "\($p.metadata.name) (\(.state.waiting.reason): \(.state.waiting.message // ""))"
  ')
  if [[ -n "$bad" ]]; then
    echo "bad pods: $(echo "$bad" | tr '\n' '; ')"
    return 1
  fi
  # Pending pods over 2 minutes — flag the reason.
  local stuck
  stuck=$(echo "$pods" | jq -r '
    .items[]
    | select(.status.phase == "Pending")
    | .metadata.name')
  if [[ -n "$stuck" ]]; then
    echo "pending: $(echo "$stuck" | tr '\n' ',' | sed 's/,$//')"
    return 1
  fi
  return 0
}

# Print high-restart-count warnings for pods matching a selector.
# Doesn't fail; emits warn() for each offender.
warn_high_restarts() {
  local selector=$1 label=$2
  local lines
  lines=$(k get pods -l "$selector" -o json \
    | jq -r '.items[] |
        .metadata.name as $n |
        (.status.containerStatuses // [])[]? |
        select(.restartCount >= 2) |
        "\($n) restartCount=\(.restartCount)"')
  if [[ -n "$lines" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      warn "$label has elevated restarts" "$line"
    done <<< "$lines"
  fi
}

# Pull the values the chart was rendered with. Returns JSON on stdout, or
# an empty string if helm is unavailable / release missing.
RELEASE_VALUES_JSON=""
load_release_values() {
  if [[ $HELM_OK -ne 1 ]]; then
    return
  fi
  RELEASE_VALUES_JSON=$(helm get values "$RELEASE" -n "$NAMESPACE" \
    --all -o json 2>/dev/null) || RELEASE_VALUES_JSON=""
}

values_get() {
  # values_get <jq-path> [default]
  local path=$1 default=${2:-}
  if [[ -z "$RELEASE_VALUES_JSON" ]]; then
    echo "$default"
    return
  fi
  echo "$RELEASE_VALUES_JSON" | jq -r "$path // \"$default\""
}

# ----- header ---------------------------------------------------------------

printf "${C_BOLD}Savant dataplane post-install verifier${C_RESET}\n"
printf "  context   : %s\n" "$(kubectl config current-context 2>/dev/null || echo '<none>')"
printf "  namespace : %s\n" "$NAMESPACE"
printf "  release   : %s\n" "$RELEASE"

# ============================================================================
# 1. Helm release
# ============================================================================
section "1. Helm release"

RELEASE_OK=0
if [[ $HELM_OK -ne 1 ]]; then
  warn "helm CLI not found on PATH" "release status check skipped"
else
  # `helm status -o json` exposes only release-level info. Chart name and
  # version come from `helm list`, where the `chart` field is the
  # combined "<chart>-<version>" string.
  list_json=$(helm list -n "$NAMESPACE" --filter "^${RELEASE}\$" -o json 2>/dev/null) || list_json=""
  entry=$(echo "$list_json" | jq -r '.[0] // empty')
  if [[ -z "$entry" ]]; then
    fail "helm release '$RELEASE' not found in namespace '$NAMESPACE'" \
         "did you set RELEASE in $CONFIG_FILE?"
  else
    rstatus=$(echo "$entry" | jq -r '.status // "unknown"')
    chart_full=$(echo "$entry" | jq -r '.chart // ""')
    # chart_full is e.g. savant-dataplane-0.12.6 — split on the last '-'.
    chart_name="${chart_full%-*}"
    chart_ver="${chart_full##*-}"
    if [[ "$rstatus" == "deployed" ]]; then
      pass "release deployed (chart $chart_name $chart_ver)"
      RELEASE_OK=1
    else
      fail "release status is '$rstatus'" "expected 'deployed'"
    fi
    if [[ -n "$chart_name" && "$chart_name" != "savant-dataplane" ]]; then
      warn "release is chart '$chart_name', not 'savant-dataplane'" \
           "verifier assumes the savant-dataplane chart"
    fi
  fi
  load_release_values
fi

# ============================================================================
# 2. Workloads — infra first, then Savant services
#
# Order: zookeeper → tei → alloy → spark-operator → spark-cluster
#        → analytic-engine → agent
#
# Hard dependency chain: zk → spark-master → spark-worker → analytic-engine
# → agent. If a hard-chain tier's stage A (structural) fails, downstream
# stage-B (live) probes are skipped — they cannot reasonably succeed.
# Soft tiers (tei, alloy, spark-operator) run independently.
# ============================================================================

# Track stage-A pass on the hard chain — used to gate downstream live probes
# and the IRSA/WIF round-trip checks at the end.
ZK_A_OK=0
SPARK_MASTER_A_OK=0
SPARK_WORKER_A_OK=0
ANALYTIC_ENGINE_A_OK=0
AGENT_A_OK=0

# ---- 2.1 ZooKeeper ---------------------------------------------------------
section "2.1 ZooKeeper"

zk_status=$(statefulset_ready zookeeper)
zk_rc=$?
if [[ $zk_rc -eq 0 ]]; then
  pass "StatefulSet zookeeper $zk_status"
  ZK_A_OK=1
  pod_msg=$(pods_clean "app.kubernetes.io/name=zookeeper")
  pod_rc=$?
  if [[ $pod_rc -eq 0 ]]; then
    pass "all zookeeper pods Running and Ready"
  else
    fail "zookeeper pods unhealthy" "$pod_msg"
    ZK_A_OK=0
  fi
  warn_high_restarts "app.kubernetes.io/name=zookeeper" "zookeeper"
else
  fail "StatefulSet zookeeper not ready" "$zk_status"
fi

if [[ $ZK_A_OK -eq 1 ]]; then
  # Stage B: ruok 4lw on each member.
  zk_pods=$(k get pods -l app.kubernetes.io/name=zookeeper \
    -o jsonpath='{.items[*].metadata.name}')
  zk_ok_count=0
  zk_total=0
  for pod in $zk_pods; do
    zk_total=$((zk_total+1))
    if pod_has_binary "$pod" nc; then
      reply=$(k_exec "$pod" sh -c "echo ruok | nc -w 2 localhost 2181" || true)
      if [[ "$reply" == "imok" ]]; then
        zk_ok_count=$((zk_ok_count+1))
      fi
    else
      # nc missing — fall through; we'll warn after the loop.
      :
    fi
  done
  if [[ $zk_total -eq 0 ]]; then
    warn "zookeeper live probe skipped" "no pods to exec into"
  elif [[ $zk_ok_count -eq $zk_total ]]; then
    pass "zookeeper ruok=imok on all $zk_total members"
  elif [[ $zk_ok_count -gt 0 ]]; then
    fail "zookeeper ruok=imok on only $zk_ok_count/$zk_total members"
  else
    warn "zookeeper ruok probe inconclusive" \
         "nc missing in pods or 4lw not whitelisted; trusting structural readiness"
  fi
else
  skip "zookeeper live probe" "structural readiness failed"
fi

# ---- 2.2 TEI ---------------------------------------------------------------
section "2.2 TEI"

tei_status=$(deployment_ready tei)
tei_rc=$?
if [[ $tei_rc -eq 0 ]]; then
  pass "Deployment tei $tei_status"
  pod_msg=$(pods_clean "app.kubernetes.io/component=tei,app.kubernetes.io/instance=$RELEASE")
  pod_rc=$?
  if [[ $pod_rc -eq 0 ]]; then
    pass "all tei pods Running and Ready"
  else
    fail "tei pods unhealthy" "$pod_msg"
    tei_rc=1
  fi
  warn_high_restarts "app.kubernetes.io/component=tei,app.kubernetes.io/instance=$RELEASE" "tei"

  # PVC check (model cache). Only required when persistence is enabled —
  # the chart default. If the PVC doesn't exist at all and persistence was
  # disabled in values, skip silently.
  pvc=$(k get pvc -l app.kubernetes.io/component=tei -o json)
  pvc_count=$(echo "$pvc" | jq -r '.items | length')
  if [[ "$pvc_count" -gt 0 ]]; then
    pvc_status=$(echo "$pvc" | jq -r '.items[0].status.phase')
    pvc_name=$(echo "$pvc" | jq -r '.items[0].metadata.name')
    if [[ "$pvc_status" == "Bound" ]]; then
      pass "tei PVC $pvc_name Bound"
    else
      fail "tei PVC $pvc_name is $pvc_status" "expected Bound"
    fi
  fi
else
  fail "Deployment tei not ready" "$tei_status"
fi

if [[ $tei_rc -eq 0 ]]; then
  if pod_has_binary "deploy/tei" curl; then
    if k_exec "deploy/tei" curl -sf --max-time 5 \
         "http://localhost:80/health" >/dev/null; then
      pass "tei /health 200"
    else
      fail "tei /health probe failed"
    fi
  else
    warn "tei live probe skipped" "curl missing inside the tei container"
  fi
else
  skip "tei live probe" "structural readiness failed"
fi

# ---- 2.3 Alloy (telemetry forwarder) --------------------------------------
section "2.3 Alloy (metrics forwarder)"

# Resolve whether telemetry is enabled in the release values.
alloy_enabled_in_values="$(values_get '.savantConfig.telemetry.remoteWrite.enabled' 'true')"

# Resource name from the alloy subchart: <release>-alloy
alloy_deploy="${RELEASE}-alloy"

alloy_status=$(deployment_ready "$alloy_deploy")
alloy_rc=$?
if [[ $alloy_rc -eq 0 ]]; then
  pass "Deployment $alloy_deploy $alloy_status"
  pod_msg=$(pods_clean "app.kubernetes.io/name=alloy,app.kubernetes.io/instance=$RELEASE")
  pod_rc=$?
  if [[ $pod_rc -eq 0 ]]; then
    pass "all alloy pods Running and Ready"
  else
    fail "alloy pods unhealthy" "$pod_msg"
    alloy_rc=1
  fi
  warn_high_restarts "app.kubernetes.io/name=alloy,app.kubernetes.io/instance=$RELEASE" "alloy"
else
  # Distinguish the two failure modes the design calls out.
  if [[ "$alloy_enabled_in_values" == "false" ]]; then
    fail "alloy disabled in values" \
         "set savantConfig.telemetry.remoteWrite.enabled=true and \`helm upgrade\`; Savant support requires telemetry to operate"
  else
    fail "alloy enabled in values but Deployment $alloy_deploy not found" \
         "chart render bug — contact Savant support"
  fi
fi

if [[ $alloy_rc -eq 0 ]]; then
  if pod_has_binary "deploy/$alloy_deploy" curl; then
    if k_exec "deploy/$alloy_deploy" curl -sf --max-time 5 \
         "http://localhost:12345/-/ready" >/dev/null; then
      pass "alloy /-/ready 200"
    else
      fail "alloy /-/ready probe failed"
    fi
  else
    warn "alloy live probe skipped" "curl missing inside the alloy container"
  fi
else
  skip "alloy live probe" "structural readiness failed"
fi

# ---- 2.4 Spark Operator ---------------------------------------------------
section "2.4 Spark Operator"

# Resource name: <release>-spark-operator-controller (subchart fullname rule).
op_deploy="${RELEASE}-spark-operator-controller"

op_status=$(deployment_ready "$op_deploy")
op_rc=$?
if [[ $op_rc -eq 0 ]]; then
  pass "Deployment $op_deploy $op_status"
  pod_msg=$(pods_clean "app.kubernetes.io/name=spark-operator,app.kubernetes.io/instance=$RELEASE")
  pod_rc=$?
  if [[ $pod_rc -eq 0 ]]; then
    pass "all spark-operator pods Running and Ready"
  else
    fail "spark-operator pods unhealthy" "$pod_msg"
  fi
  warn_high_restarts "app.kubernetes.io/name=spark-operator,app.kubernetes.io/instance=$RELEASE" "spark-operator"
else
  fail "Deployment $op_deploy not ready" "$op_status"
fi

# CRD must exist and be Established. Cluster-scoped — bypass the namespaced k() helper.
crd_json=$(kubectl get crd sparkapplications.sparkoperator.k8s.io -o json 2>/dev/null) || crd_json=""
if [[ -z "$crd_json" ]]; then
  fail "CRD sparkapplications.sparkoperator.k8s.io not installed" \
       "spark-operator subchart did not render the CRD bundle"
else
  established=$(echo "$crd_json" | jq -r '.status.conditions[]? | select(.type=="Established") | .status' | head -n1)
  if [[ "$established" == "True" ]]; then
    pass "CRD sparkapplications.sparkoperator.k8s.io Established"
  else
    fail "CRD sparkapplications.sparkoperator.k8s.io not Established"
  fi
fi

# ---- 2.5 Spark cluster (master + worker) ----------------------------------
section "2.5 Spark cluster"

# StatefulSet names from the vendored spark subchart with fullnameOverride=spark.
master_ss="spark-master"
worker_ss="spark-worker"

# Master: structural
m_status=$(statefulset_ready "$master_ss")
m_rc=$?
if [[ $m_rc -eq 0 ]]; then
  pass "StatefulSet $master_ss $m_status"
  SPARK_MASTER_A_OK=1
  pod_msg=$(pods_clean "app.kubernetes.io/component=master,app.kubernetes.io/instance=$RELEASE")
  pod_rc=$?
  if [[ $pod_rc -eq 0 ]]; then
    pass "all spark-master pods Running and Ready"
  else
    fail "spark-master pods unhealthy" "$pod_msg"
    SPARK_MASTER_A_OK=0
  fi
  warn_high_restarts "app.kubernetes.io/component=master,app.kubernetes.io/instance=$RELEASE" "spark-master"
else
  fail "StatefulSet $master_ss not ready" "$m_status"
fi

# Worker: structural — gated on master since worker registration depends on master quorum.
if [[ $SPARK_MASTER_A_OK -eq 1 ]]; then
  w_status=$(statefulset_ready "$worker_ss")
  w_rc=$?
  if [[ $w_rc -eq 0 ]]; then
    pass "StatefulSet $worker_ss $w_status"
    SPARK_WORKER_A_OK=1
    pod_msg=$(pods_clean "app.kubernetes.io/component=worker,app.kubernetes.io/instance=$RELEASE")
    pod_rc=$?
    if [[ $pod_rc -eq 0 ]]; then
      pass "all spark-worker pods Running and Ready"
    else
      fail "spark-worker pods unhealthy" "$pod_msg"
      SPARK_WORKER_A_OK=0
    fi
    warn_high_restarts "app.kubernetes.io/component=worker,app.kubernetes.io/instance=$RELEASE" "spark-worker"
  else
    fail "StatefulSet $worker_ss not ready" "$w_status"
  fi
else
  skip "spark-worker structural check" "spark-master not ready"
fi

# Stage B: query each master's web UI. In HA mode exactly one is ALIVE,
# the others STANDBY — and only the ALIVE master sees workers.
if [[ $SPARK_MASTER_A_OK -eq 1 ]]; then
  master_replicas=$(k get statefulset "$master_ss" -o jsonpath='{.spec.replicas}')
  alive_master=""
  alive_count=0
  standby_count=0
  unreachable_count=0
  curl_missing=0
  for i in $(seq 0 $((master_replicas-1))); do
    pod="spark-master-$i"
    if ! pod_has_binary "$pod" curl; then
      curl_missing=$((curl_missing+1))
      continue
    fi
    body=$(k_exec "$pod" curl -sf --max-time 5 "http://localhost:8080/json/" || true)
    if [[ -z "$body" ]]; then
      unreachable_count=$((unreachable_count+1))
      continue
    fi
    state=$(echo "$body" | jq -r '.status // ""')
    case "$state" in
      ALIVE)
        alive_count=$((alive_count+1))
        alive_master="$pod"
        alive_body="$body"
        ;;
      STANDBY)
        standby_count=$((standby_count+1))
        ;;
      *)
        unreachable_count=$((unreachable_count+1))
        ;;
    esac
  done

  if [[ $curl_missing -eq $master_replicas ]]; then
    warn "spark-master live probe skipped" "curl missing in all master containers"
  elif [[ $alive_count -eq 1 ]]; then
    pass "spark-master HA: $alive_master ALIVE, $standby_count STANDBY"
    if [[ $SPARK_WORKER_A_OK -eq 1 ]]; then
      worker_replicas=$(k get statefulset "$worker_ss" -o jsonpath='{.status.readyReplicas}')
      registered=$(echo "$alive_body" | jq -r '[.workers[]? | select(.state=="ALIVE")] | length')
      if [[ "$registered" -ge "$worker_replicas" ]]; then
        pass "ALIVE master sees $registered/$worker_replicas workers registered"
      else
        fail "ALIVE master sees only $registered/$worker_replicas workers registered" \
             "workers are running as pods but not joined to the cluster"
      fi
    fi
  elif [[ $alive_count -eq 0 ]]; then
    fail "spark-master HA: 0 ALIVE masters" \
         "$standby_count STANDBY, $unreachable_count unreachable — quorum lost"
  else
    fail "spark-master HA: $alive_count ALIVE masters" \
         "expected exactly 1 ALIVE in HA standalone mode"
  fi
else
  skip "spark-master live probe" "structural readiness failed"
fi

# ---- 2.6 Analytic engine ---------------------------------------------------
section "2.6 Analytic engine"

ae_status=$(statefulset_ready analytic-engine)
ae_rc=$?
if [[ $ae_rc -eq 0 ]]; then
  pass "StatefulSet analytic-engine $ae_status"
  ANALYTIC_ENGINE_A_OK=1
  pod_msg=$(pods_clean "app.kubernetes.io/component=analytic-engine,app.kubernetes.io/instance=$RELEASE")
  pod_rc=$?
  if [[ $pod_rc -eq 0 ]]; then
    pass "all analytic-engine pods Running and Ready"
  else
    fail "analytic-engine pods unhealthy" "$pod_msg"
    ANALYTIC_ENGINE_A_OK=0
  fi
  warn_high_restarts "app.kubernetes.io/component=analytic-engine,app.kubernetes.io/instance=$RELEASE" "analytic-engine"
else
  fail "StatefulSet analytic-engine not ready" "$ae_status"
fi

if [[ $ANALYTIC_ENGINE_A_OK -eq 1 ]]; then
  ae_pod="analytic-engine-0"
  if pod_has_binary "$ae_pod" curl; then
    if k_exec "$ae_pod" curl -sf --max-time 5 "http://localhost:8080/health" >/dev/null; then
      pass "analytic-engine /health 200"
    else
      fail "analytic-engine /health probe failed"
    fi
  else
    warn "analytic-engine live probe skipped" "curl missing inside the analytic-engine container"
  fi
else
  skip "analytic-engine live probe" "structural readiness failed"
fi

# ---- 2.7 Agent ------------------------------------------------------------
section "2.7 Agent"

agent_status=$(deployment_ready agent)
agent_rc=$?
if [[ $agent_rc -eq 0 ]]; then
  pass "Deployment agent $agent_status"
  AGENT_A_OK=1
  pod_msg=$(pods_clean "app.kubernetes.io/component=agent,app.kubernetes.io/instance=$RELEASE")
  pod_rc=$?
  if [[ $pod_rc -eq 0 ]]; then
    pass "all agent pods Running and Ready"
  else
    fail "agent pods unhealthy" "$pod_msg"
    AGENT_A_OK=0
  fi
  warn_high_restarts "app.kubernetes.io/component=agent,app.kubernetes.io/instance=$RELEASE" "agent"
else
  fail "Deployment agent not ready" "$agent_status"
fi

if [[ $AGENT_A_OK -eq 1 ]]; then
  if pod_has_binary "deploy/agent" curl; then
    if k_exec "deploy/agent" curl -sf --max-time 5 "http://localhost:8080/agent/health" >/dev/null; then
      pass "agent /agent/health 200"
    else
      fail "agent /agent/health probe failed"
    fi
  else
    warn "agent live probe skipped" "curl missing inside the agent container"
  fi
else
  skip "agent live probe" "structural readiness failed"
fi

# ============================================================================
# Hard-chain gate for sections 3–5.
# ============================================================================
HARD_CHAIN_OK=1
if [[ $ZK_A_OK -ne 1 || $SPARK_MASTER_A_OK -ne 1 \
      || $SPARK_WORKER_A_OK -ne 1 \
      || $ANALYTIC_ENGINE_A_OK -ne 1 \
      || $AGENT_A_OK -ne 1 ]]; then
  HARD_CHAIN_OK=0
fi

# ============================================================================
# 3. ServiceAccount + IRSA wiring
# ============================================================================
section "3. ServiceAccount + IRSA wiring"

if [[ $HARD_CHAIN_OK -ne 1 ]]; then
  skip "IRSA wiring checks" "hard dependency chain not all-green"
else
  sa_json=$(k get sa savant-agent -o json) || sa_json=""
  if [[ -z "$sa_json" ]]; then
    fail "ServiceAccount savant-agent not found"
  else
    pass "ServiceAccount savant-agent exists"
    role_arn=$(echo "$sa_json" \
      | jq -r '.metadata.annotations["eks.amazonaws.com/role-arn"] // ""')
    if [[ -n "$role_arn" ]]; then
      pass "savant-agent annotated with IRSA role: $role_arn"
    else
      fail "savant-agent missing eks.amazonaws.com/role-arn annotation" \
           "the IRSA webhook will not inject AWS_ROLE_ARN into pods"
    fi

    # Pod-side: AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE must be injected
    # by the EKS pod-identity webhook. Their absence means the webhook didn't
    # fire (e.g. the SA was annotated after pod start).
    pod_env=$(k_exec "deploy/agent" env || true)
    if echo "$pod_env" | grep -q '^AWS_ROLE_ARN=' \
       && echo "$pod_env" | grep -q '^AWS_WEB_IDENTITY_TOKEN_FILE='; then
      pass "agent pod has AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE injected"
    else
      fail "agent pod missing AWS_ROLE_ARN / AWS_WEB_IDENTITY_TOKEN_FILE" \
           "EKS IRSA webhook did not inject — restart the agent pod after annotating the SA"
    fi
  fi
fi

# ============================================================================
# 4. Configuration artifacts
# ============================================================================
section "4. Configuration artifacts"

# savant-config — non-sensitive agent config.
cfg_json=$(k get cm savant-config -o json) || cfg_json=""
if [[ -z "$cfg_json" ]]; then
  fail "ConfigMap savant-config not found"
else
  pass "ConfigMap savant-config exists"
  for key in SAVANT_AGENT_ID SAVANT_AGENT_CLOUD_PROVIDER \
             AWS_DEFAULT_REGION SAVANT_AGENT_BUCKET; do
    val=$(echo "$cfg_json" | jq -r ".data[\"$key\"] // \"\"")
    if [[ -n "$val" ]]; then
      pass "$key=$val"
    else
      fail "savant-config.$key is empty"
    fi
  done
fi

# gcp-credential-config — WIF descriptor.
ccm_json=$(k get cm gcp-credential-config -o json) || ccm_json=""
if [[ -z "$ccm_json" ]]; then
  fail "ConfigMap gcp-credential-config not found"
  WIF_AUDIENCE=""
else
  pass "ConfigMap gcp-credential-config exists"
  cred_json=$(echo "$ccm_json" | jq -r '.data["credential-config.json"] // ""')
  if [[ -z "$cred_json" ]]; then
    fail "gcp-credential-config.credential-config.json is empty"
    WIF_AUDIENCE=""
  elif ! echo "$cred_json" | jq empty 2>/dev/null; then
    fail "gcp-credential-config.credential-config.json is not valid JSON"
    WIF_AUDIENCE=""
  else
    type=$(echo "$cred_json" | jq -r '.type // ""')
    aud=$(echo "$cred_json" | jq -r '.audience // ""')
    impurl=$(echo "$cred_json" | jq -r '.service_account_impersonation_url // ""')
    if [[ "$type" == "external_account" ]]; then
      pass "credential-config type=external_account"
    else
      fail "credential-config type='$type'" "expected 'external_account'"
    fi
    if [[ -n "$aud" ]]; then
      pass "credential-config audience present"
      WIF_AUDIENCE="$aud"
    else
      fail "credential-config audience missing"
      WIF_AUDIENCE=""
    fi
    if [[ -n "$impurl" ]]; then
      pass "credential-config service_account_impersonation_url present"
    else
      fail "credential-config service_account_impersonation_url missing"
    fi
  fi
fi

# savant-secrets — only required when externalId is set in values.
external_id_set="$(values_get '.savantConfig.aws.externalId' '')"
if [[ -n "$external_id_set" && "$external_id_set" != "null" ]]; then
  if k get secret savant-secrets >/dev/null 2>&1; then
    pass "Secret savant-secrets exists (externalId in values)"
  else
    fail "Secret savant-secrets not found" \
         "savantConfig.aws.externalId is set but the rendered Secret is missing"
  fi
fi

# ============================================================================
# 5. WIF token round-trip
# ============================================================================
section "5. WIF token round-trip"

if [[ $AGENT_A_OK -ne 1 ]]; then
  skip "WIF token round-trip" "agent not ready"
elif [[ -z "${WIF_AUDIENCE:-}" ]]; then
  skip "WIF token round-trip" "audience missing from gcp-credential-config"
else
  token=$(k_exec "deploy/agent" cat /var/run/secrets/gcp/token || true)
  if [[ -z "$token" ]]; then
    fail "agent pod has no projected GCP token at /var/run/secrets/gcp/token" \
         "the SA token volume is not mounted — chart render bug"
  else
    # JWT shape: header.payload.signature, all base64url
    if [[ "$(echo "$token" | tr -cd '.' | wc -c)" != "2" ]]; then
      fail "projected GCP token is not a JWT" "got $(echo "$token" | wc -c) bytes, no 3-segment shape"
    else
      pass "projected GCP token mounted at /var/run/secrets/gcp/token"
      payload_b64=$(echo "$token" | cut -d. -f2)
      # base64url → base64 with padding
      pad=$(( (4 - ${#payload_b64} % 4) % 4 ))
      payload_b64_padded="${payload_b64}$(printf '%.0s=' $(seq 1 $pad))"
      payload=$(echo "$payload_b64_padded" | tr '_-' '/+' | base64 -d 2>/dev/null || true)
      if ! echo "$payload" | jq empty 2>/dev/null; then
        warn "could not decode JWT payload" "skipping aud / exp check"
      else
        # Kubernetes projected SA tokens encode aud as a JSON array (the
        # spec allows multiple audiences). Match WIF_AUDIENCE against any
        # element if it's an array, or against the value directly if string.
        token_exp=$(echo "$payload" | jq -r '.exp // 0')
        aud_match=$(echo "$payload" \
          | jq --arg want "$WIF_AUDIENCE" -r '
              (.aud // "") as $a
              | if ($a | type) == "array" then
                  if ($a | index($want)) != null then "yes" else "no" end
                else
                  if $a == $want then "yes" else "no" end
                end')
        token_aud_summary=$(echo "$payload" | jq -c '.aud // ""')
        # Pure-bash "now" in epoch seconds.
        now=$(date +%s)
        if [[ "$aud_match" == "yes" ]]; then
          pass "JWT aud matches gcp-credential-config audience"
        else
          fail "JWT aud does not match gcp-credential-config audience" \
               "token aud=$token_aud_summary expected=$WIF_AUDIENCE — pods will get WebIdentityErr against GCP"
        fi
        if [[ "$token_exp" -gt "$now" ]]; then
          remaining=$((token_exp - now))
          pass "JWT exp is in the future (${remaining}s remaining)"
        else
          fail "JWT exp is in the past" "token expired or clock skew"
        fi
      fi
    fi
  fi
fi

# ============================================================================
# Summary
# ============================================================================
section "Summary"

printf "  ${C_GREEN}%d passed${C_RESET},  ${C_RED}%d failed${C_RESET},  ${C_YELLOW}%d warned${C_RESET},  %d skipped\n" \
  "$PASS" "$FAIL" "$WARN" "$SKIP"

cat <<'EOF'

What this verifier did NOT check:
  - AWS API connectivity from inside the cluster (S3, STS) — preflight covers this
  - End-to-end Spark job submission (too slow for a verify pass)
  - That the IAM role's policy actually grants S3 reads on your bucket
  - KMS / BYOK key access from the dataplane role
  - Savant SaaS-side registration of this agent

After a green run, notify your Savant account team — they finish
control-plane registration within one business day, after which the
agent appears in the Savant web app.
EOF

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0

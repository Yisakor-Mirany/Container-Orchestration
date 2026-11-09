#!/usr/bin/env bash
# =============================================================================
# Container-Orchestration - automated QA test suite
# ContainerOps Dashboard (Docker + Docker Compose + Nginx)
#
# Usage:
#   bash tests/qa-test.sh               # build, start, test, tear down
#   bash tests/qa-test.sh --keep        # leave the stack running afterwards
#   bash tests/qa-test.sh --skip-build  # reuse an already-built image
#   bash tests/qa-test.sh --help
#
# Requirements on the host: docker (with the compose plugin), curl, and one
# JSON parser: jq, python3 or node.
#
# Raw output of every run is written to qa-output/<timestamp>/ so that you
# can copy real evidence into tests/QA_RESULTS.md. This script never
# invents results: every PASS/FAIL below comes from a real command.
# =============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}" || exit 1

# Pick up HOST_PORT / WEB_REPLICAS etc. from .env if present (not required).
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

HOST_PORT="${HOST_PORT:-8080}"
BASE_URL="${BASE_URL:-http://localhost:${HOST_PORT}}"
IMAGE="containerops-dashboard:1.0.0"
EXPECTED_USER="appuser:appgroup"
EXPECTED_UID="10001"
REPLICAS=3
HEALTH_TIMEOUT=120        # seconds to wait for replicas to become healthy
RESTART_TIMEOUT=60        # seconds to wait for a crashed replica to recover
CURL_OPTS=(--silent --show-error --max-time 5)

KEEP=false
SKIP_BUILD=false
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=true ;;
    --skip-build) SKIP_BUILD=true ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)"; exit 2 ;;
  esac
done

RUN_ID="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${PROJECT_DIR}/qa-output/${RUN_ID}"
mkdir -p "${OUT_DIR}"
LOG="${OUT_DIR}/qa-test.log"

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_RESET=$'\e[0m'
else
  C_GREEN=''; C_RED=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi

PASS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS=()

log()     { printf '%s\n' "$*" | tee -a "${LOG}"; }
section() { log ""; log "${C_BLUE}=== $* ===${C_RESET}"; }
info()    { log "  ${C_YELLOW}INFO${C_RESET}  $*"; }
pass()    { PASS_COUNT=$((PASS_COUNT + 1)); RESULTS+=("PASS | $1"); log "  ${C_GREEN}PASS${C_RESET}  $1"; }
fail()    { FAIL_COUNT=$((FAIL_COUNT + 1)); RESULTS+=("FAIL | $1"); log "  ${C_RED}FAIL${C_RESET}  $1${2:+ -- $2}"; }

# Run a command, append its output to the log, return its exit code.
run() {
  log "  \$ $*"
  "$@" >>"${LOG}" 2>&1
}

# ----------------------------------------------------------------------------
# JSON helper: json_get '<json>' 'dotted.path'  -> prints value ('' if missing)
# Exit status 1 if the input is not valid JSON.
# ----------------------------------------------------------------------------
JSON_TOOL=""
if command -v jq >/dev/null 2>&1; then JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1; then JSON_TOOL=python3
elif command -v node >/dev/null 2>&1; then JSON_TOOL=node
fi

json_get() {
  local json="$1" path="$2"
  case "${JSON_TOOL}" in
    jq)
      printf '%s' "${json}" | jq -r --arg p "${path}" 'getpath($p | split(".")) // "" | tostring' 2>/dev/null ;;
    python3)
      printf '%s' "${json}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for k in sys.argv[1].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else (str(d).lower() if isinstance(d, bool) else d))
' "${path}" ;;
    node)
      printf '%s' "${json}" | node -e '
let s = ""; process.stdin.on("data", c => s += c).on("end", () => {
  let d; try { d = JSON.parse(s); } catch { process.exit(1); }
  for (const k of process.argv[1].split(".")) d = d && typeof d === "object" ? d[k] : undefined;
  console.log(d === undefined || d === null ? "" : String(d));
});' "${path}" ;;
  esac
}

# http_code URL -> prints the HTTP status code (000 on connection failure)
http_code() { curl "${CURL_OPTS[@]}" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true; }

web_ids()          { docker compose ps -q web 2>/dev/null; }
count_running()    { web_ids | wc -l | tr -d ' '; }
count_healthy()    {
  local n=0 id
  for id in $(web_ids); do
    [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id" 2>/dev/null)" == "healthy" ]] && n=$((n + 1))
  done
  echo "$n"
}

# wait_for_healthy N TIMEOUT -> 0 when N web replicas are healthy
wait_for_healthy() {
  local want="$1" timeout="$2" start now healthy
  start=$(date +%s)
  while true; do
    healthy=$(count_healthy)
    [[ "${healthy}" -ge "${want}" ]] && return 0
    now=$(date +%s)
    if (( now - start >= timeout )); then
      info "Timed out after ${timeout}s: ${healthy}/${want} replicas healthy"
      return 1
    fi
    sleep 2
  done
}

# distinct_hostnames N -> prints the number of distinct hostnames seen in N requests
distinct_hostnames() {
  local n="$1" i body host
  local -A seen=()
  for ((i = 0; i < n; i++)); do
    body=$(curl "${CURL_OPTS[@]}" "${BASE_URL}/api/instances" 2>/dev/null) || continue
    host=$(json_get "${body}" instance.hostname) || continue
    [[ -n "${host}" ]] && seen["${host}"]=$(( ${seen["${host}"]:-0} + 1 ))
  done
  for host in "${!seen[@]}"; do echo "    ${host}: ${seen[$host]} request(s)" >>"${LOG}"; done
  echo "${#seen[@]}"
}

cleanup() {
  if [[ "${KEEP}" == "true" ]]; then
    info "--keep set: stack left running. Stop it with: docker compose down"
  else
    section "Teardown"
    run docker compose down --remove-orphans || true
  fi
}

# ----------------------------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------------------------
section "Prerequisites"
log "  Run ID:     ${RUN_ID}"
log "  Base URL:   ${BASE_URL}"
log "  Output dir: ${OUT_DIR}"

for bin in docker curl; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    log "${C_RED}ERROR${C_RESET}: '${bin}' is required but not installed."; exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  log "${C_RED}ERROR${C_RESET}: the Docker Compose v2 plugin ('docker compose') is required."; exit 1
fi
if ! docker info >/dev/null 2>&1; then
  log "${C_RED}ERROR${C_RESET}: cannot reach the Docker daemon. Is Docker running?"; exit 1
fi
if [[ -z "${JSON_TOOL}" ]]; then
  log "${C_RED}ERROR${C_RESET}: install jq, python3 or node for JSON validation."; exit 1
fi
info "Docker:   $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
info "Compose:  $(docker compose version --short 2>/dev/null)"
info "JSON via: ${JSON_TOOL}"
run docker compose config --quiet && pass "compose.yaml is valid" || fail "compose.yaml is valid"

trap cleanup EXIT

# ----------------------------------------------------------------------------
# 1. Image and build verification
# ----------------------------------------------------------------------------
section "1. Image and build verification"

if [[ "${SKIP_BUILD}" == "true" ]]; then
  info "--skip-build set: not rebuilding"
else
  if run docker compose build web; then
    pass "Docker image builds successfully (docker compose build)"
  else
    fail "Docker image builds successfully" "see ${LOG}"
  fi
fi

if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  pass "Image is tagged as ${IMAGE}"
else
  fail "Image is tagged as ${IMAGE}" "image not found; cannot continue"
  exit 1
fi

IMG_USER=$(docker image inspect -f '{{.Config.User}}' "${IMAGE}")
if [[ "${IMG_USER}" == "${EXPECTED_USER}" ]]; then
  pass "Image USER is ${EXPECTED_USER}"
else
  fail "Image USER is ${EXPECTED_USER}" "got '${IMG_USER:-<empty = root>}'"
fi

IMG_UID=$(docker run --rm --entrypoint id "${IMAGE}" -u 2>>"${LOG}")
if [[ "${IMG_UID}" == "${EXPECTED_UID}" ]]; then
  pass "Default container user has UID ${EXPECTED_UID} (non-root)"
else
  fail "Default container user has UID ${EXPECTED_UID}" "got '${IMG_UID}'"
fi

IMG_SIZE=$(docker image inspect -f '{{.Size}}' "${IMAGE}" 2>/dev/null)
if [[ -n "${IMG_SIZE}" ]]; then
  pass "Image size can be inspected: $((IMG_SIZE / 1024 / 1024)) MiB (docker image inspect .Size)"
  docker images "${IMAGE%%:*}" | tee -a "${LOG}" >/dev/null
else
  fail "Image size can be inspected"
fi

if docker run --rm --entrypoint sh "${IMAGE}" -c 'command -v npm' >/dev/null 2>&1; then
  fail "npm is not present in the runtime image" "npm found"
else
  pass "npm is not present in the runtime image"
fi

IMG_HC=$(docker image inspect -f '{{if .Config.Healthcheck}}{{join .Config.Healthcheck.Test " "}}{{end}}' "${IMAGE}")
if [[ "${IMG_HC}" == *healthcheck.js* ]]; then
  pass "Image defines a HEALTHCHECK (${IMG_HC})"
else
  fail "Image defines a HEALTHCHECK" "got '${IMG_HC}'"
fi

# ----------------------------------------------------------------------------
# 2. Orchestration: start, scale, health
# ----------------------------------------------------------------------------
section "2. Orchestration"

if run docker compose up -d --scale "web=${REPLICAS}"; then
  pass "docker compose up -d --scale web=${REPLICAS} starts the services"
else
  fail "docker compose up starts the services" "see ${LOG}"; exit 1
fi

RUNNING=$(count_running)
[[ "${RUNNING}" -eq "${REPLICAS}" ]] \
  && pass "Web service has ${REPLICAS} replicas (found ${RUNNING})" \
  || fail "Web service has ${REPLICAS} replicas" "found ${RUNNING}"

if wait_for_healthy "${REPLICAS}" "${HEALTH_TIMEOUT}"; then
  pass "All ${REPLICAS} web replicas report healthy"
else
  fail "All ${REPLICAS} web replicas report healthy" "$(count_healthy)/${REPLICAS} healthy"
fi

NGINX_ID=$(docker compose ps -q nginx)
for _ in $(seq 1 30); do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "${NGINX_ID}" 2>/dev/null)" == "healthy" ]] && break
  sleep 2
done
NGINX_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "${NGINX_ID}" 2>/dev/null)
[[ "${NGINX_HEALTH}" == "healthy" ]] \
  && pass "Nginx container reports healthy" \
  || fail "Nginx container reports healthy" "status '${NGINX_HEALTH}'"

docker compose ps >>"${LOG}" 2>&1

# Running process UID inside every replica (reads /proc of the node process).
UID_OK=true
for id in $(web_ids); do
  puid=$(docker exec "${id}" sh -c 'awk "/^Uid:/{print \$2}" /proc/$(pgrep -o -x node)/status' 2>>"${LOG}")
  log "    ${id:0:12}: node process UID=${puid}"
  [[ "${puid}" == "${EXPECTED_UID}" ]] || UID_OK=false
done
${UID_OK} && pass "Node.js process runs as UID ${EXPECTED_UID} in every replica" \
          || fail "Node.js process runs as UID ${EXPECTED_UID} in every replica"

# Runtime hardening reported by Docker.
HARDEN_OK=true
for id in $(web_ids); do
  ro=$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "${id}")
  caps=$(docker inspect -f '{{.HostConfig.CapDrop}}' "${id}")
  mem=$(docker inspect -f '{{.HostConfig.Memory}}' "${id}")
  cpu=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "${id}")
  rp=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${id}")
  log "    ${id:0:12}: readonly=${ro} capDrop=${caps} memory=${mem} nanoCpus=${cpu} restart=${rp}"
  [[ "${ro}" == "true" && "${caps}" == *ALL* && "${mem}" -gt 0 && "${cpu}" -gt 0 && "${rp}" == "unless-stopped" ]] || HARDEN_OK=false
done
${HARDEN_OK} && pass "Replicas have read-only rootfs, cap_drop ALL, CPU/memory limits and a restart policy" \
             || fail "Replicas have hardening, limits and restart policy" "see ${LOG}"

# ----------------------------------------------------------------------------
# 3. Functional testing (through Nginx)
# ----------------------------------------------------------------------------
section "3. Functional testing via ${BASE_URL}"

# Wait until Nginx answers (it may still be resolving replicas).
for _ in $(seq 1 15); do [[ "$(http_code "${BASE_URL}/healthz")" == "200" ]] && break; sleep 1; done

for path in / /healthz /readyz /api/info /api/instances; do
  code=$(http_code "${BASE_URL}${path}")
  [[ "${code}" == "200" ]] && pass "GET ${path} returns HTTP 200" || fail "GET ${path} returns HTTP 200" "got ${code}"
done

HEALTH=$(curl "${CURL_OPTS[@]}" "${BASE_URL}/healthz" 2>/dev/null)
echo "${HEALTH}" >"${OUT_DIR}/healthz.json"
if [[ "$(json_get "${HEALTH}" status)" == "healthy" && -n "$(json_get "${HEALTH}" hostname)" && -n "$(json_get "${HEALTH}" timestamp)" ]]; then
  pass "/healthz JSON contains status=healthy, hostname, timestamp"
else
  fail "/healthz JSON contains status, hostname, timestamp" "${HEALTH}"
fi

INFO=$(curl "${CURL_OPTS[@]}" "${BASE_URL}/api/info" 2>/dev/null)
echo "${INFO}" >"${OUT_DIR}/api-info.json"
if json_get "${INFO}" hostname >/dev/null; then
  missing=""
  for key in hostname nodeVersion uptimeSeconds timestamp requestCount status; do
    [[ -n "$(json_get "${INFO}" "${key}")" ]] || missing+=" ${key}"
  done
  [[ -z "${missing}" ]] && pass "/api/info returns valid JSON with all required fields" \
                        || fail "/api/info returns all required fields" "missing:${missing}"
else
  fail "/api/info returns valid JSON" "${INFO:0:200}"
fi

INST=$(curl "${CURL_OPTS[@]}" "${BASE_URL}/api/instances" 2>/dev/null)
echo "${INST}" >"${OUT_DIR}/api-instances.json"
if json_get "${INST}" instance.hostname >/dev/null && [[ -n "$(json_get "${INST}" instance.hostname)" && -n "$(json_get "${INST}" instance.nodeVersion)" ]]; then
  pass "/api/instances returns container metadata (hostname=$(json_get "${INST}" instance.hostname))"
else
  fail "/api/instances returns container metadata" "${INST:0:200}"
fi

# Dashboard assets referenced by index.html must all load.
INDEX=$(curl "${CURL_OPTS[@]}" "${BASE_URL}/" 2>/dev/null)
ASSETS=$(printf '%s' "${INDEX}" | grep -oE '(href|src)="/[^"#]*"' | sed -E 's/^(href|src)="//; s/"$//' | sort -u)
ASSET_FAIL=""
for asset in ${ASSETS}; do
  code=$(http_code "${BASE_URL}${asset}")
  log "    ${asset} -> ${code}"
  [[ "${code}" == "200" ]] || ASSET_FAIL+=" ${asset}(${code})"
done
if [[ -n "${ASSETS}" && -z "${ASSET_FAIL}" ]]; then
  pass "Dashboard loads without missing assets ($(echo "${ASSETS}" | wc -w | tr -d ' ') local assets)"
else
  fail "Dashboard loads without missing assets" "${ASSET_FAIL:-no assets found}"
fi

code=$(http_code "${BASE_URL}/does-not-exist")
[[ "${code}" == "404" ]] && pass "Unknown path returns 404" || fail "Unknown path returns 404" "got ${code}"

code=$(curl "${CURL_OPTS[@]}" -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/api/info" 2>/dev/null)
[[ "${code}" == "405" ]] && pass "POST is rejected with 405" || fail "POST is rejected with 405" "got ${code}"

# ----------------------------------------------------------------------------
# 4. Load balancing
# ----------------------------------------------------------------------------
section "4. Load balancing"

log "  Hostnames seen in 30 requests:"
DISTINCT=$(distinct_hostnames 30)
if [[ "${DISTINCT}" -ge "${REPLICAS}" ]]; then
  pass "Requests were served by ${DISTINCT} different replicas"
elif [[ "${DISTINCT}" -ge 2 ]]; then
  pass "Requests were served by ${DISTINCT} different replicas (fewer than ${REPLICAS}; see notes)"
else
  fail "Requests are distributed across multiple replicas" "only ${DISTINCT} hostname(s) seen"
fi

# Dynamic discovery: scale up, Nginx must find the new replica via DNS.
info "Scaling to $((REPLICAS + 1)) replicas to test DNS re-resolution..."
run docker compose up -d --no-recreate --scale "web=$((REPLICAS + 1))"
if wait_for_healthy "$((REPLICAS + 1))" "${HEALTH_TIMEOUT}"; then
  found=0
  for _ in $(seq 1 10); do
    sleep 3
    found=$(distinct_hostnames 24)
    [[ "${found}" -ge "$((REPLICAS + 1))" ]] && break
  done
  [[ "${found}" -ge "$((REPLICAS + 1))" ]] \
    && pass "Nginx discovered the added replica without a reload (${found} hostnames)" \
    || fail "Nginx discovered the added replica" "saw ${found} hostnames"
else
  fail "Scaled-up replica became healthy"
fi
run docker compose up -d --no-recreate --scale "web=${REPLICAS}"
wait_for_healthy "${REPLICAS}" "${HEALTH_TIMEOUT}" >/dev/null
[[ "$(count_running)" -eq "${REPLICAS}" ]] \
  && pass "Scaled back to ${REPLICAS} replicas" \
  || fail "Scaled back to ${REPLICAS} replicas" "running: $(count_running)"
sleep 6   # let Nginx's DNS cache (valid=5s) drop the removed replica

# ----------------------------------------------------------------------------
# 5. Failure recovery
# ----------------------------------------------------------------------------
section "5. Failure recovery"

VICTIM=$(web_ids | head -n 1)
VICTIM_NAME=$(docker inspect -f '{{.Name}}' "${VICTIM}" | sed 's#^/##')
RESTARTS_BEFORE=$(docker inspect -f '{{.RestartCount}}' "${VICTIM}")
info "Victim: ${VICTIM_NAME} (restart count ${RESTARTS_BEFORE})"

# Background availability probe while the replica fails.
PROBE_FILE="${OUT_DIR}/availability.txt"
: >"${PROBE_FILE}"
(
  end=$(( $(date +%s) + 20 ))
  while (( $(date +%s) < end )); do
    curl --silent --max-time 3 -o /dev/null -w '%{http_code}\n' "${BASE_URL}/api/instances" >>"${PROBE_FILE}" 2>/dev/null \
      || echo "000" >>"${PROBE_FILE}"
    sleep 0.2
  done
) &
PROBE_PID=$!
sleep 1

# Simulate a crash: SIGKILL the Node.js process inside the container.
# (Unlike `docker kill`, this is an unexpected exit, so Docker's restart
# policy applies. See README "Self-healing verification".)
log "  \$ docker exec ${VICTIM_NAME} sh -c 'kill -KILL \$(pgrep -o -x node)'"
docker exec "${VICTIM}" sh -c 'kill -KILL $(pgrep -o -x node)' >>"${LOG}" 2>&1

RECOVERED=false
start=$(date +%s)
while (( $(date +%s) - start < RESTART_TIMEOUT )); do
  rc=$(docker inspect -f '{{.RestartCount}}' "${VICTIM}" 2>/dev/null || echo 0)
  hs=$(docker inspect -f '{{.State.Health.Status}}' "${VICTIM}" 2>/dev/null)
  if [[ "${rc}" -gt "${RESTARTS_BEFORE}" && "${hs}" == "healthy" ]]; then RECOVERED=true; break; fi
  sleep 2
done
RESTARTS_AFTER=$(docker inspect -f '{{.RestartCount}}' "${VICTIM}")
if ${RECOVERED}; then
  pass "Crashed replica was restarted by its restart policy (RestartCount ${RESTARTS_BEFORE} -> ${RESTARTS_AFTER}) and is healthy"
else
  fail "Crashed replica was restarted by its restart policy" "RestartCount ${RESTARTS_BEFORE} -> ${RESTARTS_AFTER}"
fi

wait "${PROBE_PID}" 2>/dev/null
TOTAL=$(grep -c . "${PROBE_FILE}" || true)
OK=$(grep -c '^200$' "${PROBE_FILE}" || true)
BAD=$((TOTAL - OK))
LAST10_BAD=$(tail -n 10 "${PROBE_FILE}" | grep -vc '^200$' || true)
info "Availability during failure: ${OK}/${TOTAL} requests returned 200 (${BAD} failed)"
if [[ "${TOTAL}" -gt 0 && "${BAD}" -le 2 && "${LAST10_BAD}" -eq 0 ]]; then
  pass "Application stayed available during a single replica failure (${OK}/${TOTAL} OK)"
else
  fail "Application stayed available during a single replica failure" "${OK}/${TOTAL} OK, last-10 failures: ${LAST10_BAD}"
fi

# Informational: docker kill is treated by Docker as a MANUAL stop.
info "Demonstrating 'docker kill' semantics (informational, not scored)..."
VICTIM2=$(web_ids | tail -n 1)
docker kill "${VICTIM2}" >>"${LOG}" 2>&1
sleep 5
st=$(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' "${VICTIM2}")
info "After 'docker kill': ${st}  (Docker does not apply restart policies to manual kill/stop)"
info "Recovering it with: docker compose up -d --scale web=${REPLICAS}"
run docker compose up -d --no-recreate --scale "web=${REPLICAS}"
wait_for_healthy "${REPLICAS}" "${HEALTH_TIMEOUT}" \
  && pass "docker compose up restored ${REPLICAS} healthy replicas after a manual kill" \
  || fail "docker compose up restored ${REPLICAS} healthy replicas"

docker compose ps >>"${LOG}" 2>&1
docker compose logs --no-color >"${OUT_DIR}/compose-logs.txt" 2>&1

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
section "Summary"
for r in "${RESULTS[@]}"; do log "  ${r}"; done
log ""
log "  Passed: ${PASS_COUNT}   Failed: ${FAIL_COUNT}"
log "  Evidence written to: ${OUT_DIR}"

[[ "${FAIL_COUNT}" -eq 0 ]]

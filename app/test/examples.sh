#!/usr/bin/env bash

set -euo pipefail

# ANSI color codes
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

logfg() { printf "\n${GREEN}${1}${NC}\n"; }
logfy() { printf "${YELLOW}${1}${NC}\n"; }
logf()  { printf "${1}\n"; }

# Resolve script directory so test files can be found regardless of cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Constants - all traffic via the Envoy frontend proxy
readonly ALERTSTACK_HOST="${ALERTSTACK_HOST:-alertstack.org}"
readonly ENVOY_PORT_TLS="${ENVOY_PORT_TLS:-8443}"
readonly ENVOY_PORT="${ENVOY_PORT:-8080}"
readonly ALERTSTACK_HTTPS="https://${ALERTSTACK_HOST}:${ENVOY_PORT_TLS}"
readonly ALERTSTACK_HTTP="http://${ALERTSTACK_HOST}:${ENVOY_PORT}"
readonly CURL_COMMON_OPTS="--fail-with-body --retry 3 --retry-delay 2 --max-time 30 --silent --show-error --insecure"

send_metric() {
    local endpoint=$1
    local data=$2
    local format=${3:-"text"}
    echo
    if [[ "$format" == "json" ]]; then
        echo "$data" | prom2json | curl $CURL_COMMON_OPTS \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json' \
            --data-binary @- "${endpoint}"
    else
        echo "$data" | curl $CURL_COMMON_OPTS \
            -H 'Content-Type: text/plain' \
            --data-binary @- "${endpoint}"
    fi
}

check_metric_format() {
    local metric=$1
    echo
    echo "$metric" | prom2json | jq . || {
        echo "Error: invalid metric format"
        exit 1
    }
}

logfy "Prerequisite: ${ALERTSTACK_HOST} must resolve to 127.0.0.1 in /etc/hosts"
logfy "  sudo sh -c 'echo \"127.0.0.1 ${ALERTSTACK_HOST}\" >> /etc/hosts'"

logfy "Prerequisite: prom2json must be on PATH"
logfy "  go install github.com/prometheus/prom2json/cmd/prom2json@latest"

logfy "Prerequisite: stack must be running"
logfy "  make stack-up   (from project root)"

echo
logfg "Waiting for stack to be ready..."
for i in $(seq 1 10); do
    echo "${ALERTSTACK_HTTPS}/time" 
    curl --silent --insecure --max-time 2 "${ALERTSTACK_HTTPS}/time" >/dev/null 2>&1 && break
    printf "  ... waiting (${i}/10)\n"
    sleep 2
done

# Basic test metric
read -r -d '' METRICLINE <<-EOM || true
envoy_cluster_upstream_rq_total{cluster_name="frontend",\
envoy_response_code="503",envoy_response_code_class="5xx",\
job="envoy",severity="critical",extra_slack_recipient_god="#alert-receiver",\
pd_group="sre",instance="alertstack1.ams",cluster="eu-marley",deployment="marley",\
network_region="EMEA",edge_loc="ams",region="eu-central-1",servergroup="proxy",\
pop_name="alertstack1.ams",alertstack_host="${ALERTSTACK_HOST}"} 6
EOM

logfg "Validating test metric format..."
check_metric_format "$METRICLINE"

logfg "Testing metric creation (HTTPS via proxy, prom text format)..."
send_metric "${ALERTSTACK_HTTPS}/create" "$METRICLINE"

logfg "Testing metric creation (HTTPS via proxy, JSON format via prom2json)..."
send_metric "${ALERTSTACK_HTTPS}/create" "$METRICLINE" "json"

logfg "Processing prom format test files..."
for test_file in "${SCRIPT_DIR}"/*.prom; do
    [[ -f "$test_file" ]] || continue
    logfg "  Creating metrics from ${test_file##*/}..."
    send_metric "${ALERTSTACK_HTTPS}/create" "$(sed "s/alertstack_host=\"alertstack\.org\"/alertstack_host=\"${ALERTSTACK_HOST}\"/g" "$test_file")"
done

logfg "Testing multi-metric creation..."
if [[ -f "${SCRIPT_DIR}/multi_metric.prom" ]]; then
    send_metric "${ALERTSTACK_HTTPS}/create" "$(sed "s/alertstack_host=\"alertstack\.org\"/alertstack_host=\"${ALERTSTACK_HOST}\"/g" "${SCRIPT_DIR}/multi_metric.prom")" "json"
fi

logfg "Testing a metric with no labels..."
send_metric "${ALERTSTACK_HTTPS}/create" "metric_with_no_labels 1"

logfg "Checking Envoy admin stats endpoint (direct, port 9901)..."
curl --silent --max-time 5 "http://localhost:9901/stats/prometheus" | head -5 || \
    logfy "  Envoy admin not reachable -- stack may not be running"

logfg "Checking /metrics endpoint (HTTPS via proxy)..."
curl $CURL_COMMON_OPTS --head "${ALERTSTACK_HTTPS}/metrics"

logfg "Checking /ping endpoint..."
curl $CURL_COMMON_OPTS "${ALERTSTACK_HTTPS}/ping"

logfg "Checking /time endpoint..."
curl $CURL_COMMON_OPTS "${ALERTSTACK_HTTPS}/time"

logfg "Checking /echo endpoint..."
curl $CURL_COMMON_OPTS "${ALERTSTACK_HTTPS}/echo"

logfg "Listing known metric names..."
curl $CURL_COMMON_OPTS "${ALERTSTACK_HTTPS}/metrics" | \
    prom2json | \
    jq ".[].name"

logfg "Testing metric update (inline metric, delta +1)..."
send_metric "${ALERTSTACK_HTTPS}/update" "$METRICLINE"

logfg "Updating prom format test files (adds prom file values as deltas)..."
for test_file in "${SCRIPT_DIR}"/*.prom; do
    [[ -f "$test_file" ]] || continue
    logfg "  Updating metrics from ${test_file##*/}..."
    send_metric "${ALERTSTACK_HTTPS}/update" \
        "$(sed "s/alertstack_host=\"alertstack\.org\"/alertstack_host=\"${ALERTSTACK_HOST}\"/g" "$test_file")" \
        "text"
done

logfg "Testing notification enqueue (v2/enqueue)..."
curl $CURL_COMMON_OPTS "${ALERTSTACK_HTTPS}/metrics" | \
    prom2json | \
    curl $CURL_COMMON_OPTS \
    -H 'Content-Type: application/json' \
    --data-binary @- "${ALERTSTACK_HTTPS}/v2/enqueue"

logfg "All tests completed successfully"

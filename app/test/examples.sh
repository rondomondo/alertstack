#!/usr/bin/env bash

#set -euo pipefail

# ANSI color codes
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

function logfg() {
    local l=$1
    printf "\n${GREEN}${l}${NC}\n"
}

function logfy() {
    local l=$1
    printf "${YELLOW}${l}${NC}\n"
}


function logf() {
    local l=$1
    printf "${l}\n"
}

# Constants
readonly ALERTSTACK_HTTP="http://alertstack.io:8090"
readonly ALERTSTACK_HTTPS="https://alertstack.io:8443"
readonly CURL_COMMON_OPTS="--fail-with-body --retry 3 --retry-delay 2 --max-time 30 --silent --show-error"

# Helper functions
send_metric() {
    local endpoint=$1
    local data=$2
    local format=${3:-"text"} # default to text format
    echo
    if [[ "$format" == "json" ]]; then
        echo "$data" | prom2json | curl $CURL_COMMON_OPTS \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json' \
            --data-binary @- "${endpoint}"
    else
        echo "$data" | curl $CURL_COMMON_OPTS \
            --data-binary @- "${endpoint}"
    fi
}

check_metric_format() {
    local metric=$1
    echo
    echo "$metric" | prom2json | jq . || {
        echo "Error: Invalid metric format"
        exit 1
    }
}

# Start the pingpong service
logfg "Starting pingpong service..."
./pingpong &
PINGPONG_PID=$!

# Ensure cleanup on script exit
trap 'kill $PINGPONG_PID 2>/dev/null' EXIT

# Wait for service to start
logfg "Waiting for service to initialize..."
sleep 3

# Basic test metric
read -r -d '' METRICLINE <<-EOM
bgp_neighbors_status{cluster="eu-data",alertname="BGP_down",\
extra_slack_recipient_sre="#alert-receiver",deployment="default",\
instance="i-service.syd",job="defaultTargetsWithAuth",\
network_region="APAC",peer_asn="1234",peer_ip="124.123.1.1",\
peer_name="SYD-DAVE",peer_type="Pipe",pop="syd",\
region="eu-central-1-data",servergroup="default",\
receiver="slack-receiver-sre",severity="critical"} 1
EOM

logfg "Validating test metric format..."
check_metric_format "$METRICLINE"

logfg "Testing metric creation..."
# Create metrics (in JSON format)
send_metric "${ALERTSTACK_HTTP}/create" "$METRICLINE" "json"

# Create metrics (in prom text exposition/text format)
send_metric "${ALERTSTACK_HTTPS}/create" "$METRICLINE"

# Process test files
logfg "Processing prom format test files..."
for test_file in test/*.prom; do
    if [[ -f "$test_file" ]]; then
        logfg "Processing metric(s) creation from prom file $test_file..."
        send_metric "${ALERTSTACK_HTTPS}/create" "$(cat "$test_file")"
    fi
done

# Multi-metric test
logfg "Testing multi-metric creation..."
if [[ -f "test/multi_metric.prom" ]]; then
    send_metric "${ALERTSTACK_HTTPS}/create" "$(cat test/multi_metric.prom)" "json"
fi

# Test simple metric
logfg "Testing a super simple metric..."
send_metric "${ALERTSTACK_HTTPS}/create" "metric_with_no_labels 1"

# Check metrics endpoint
logfg "Checking the metrics endpoint..."
curl --head $CURL_COMMON_OPTS "${ALERTSTACK_HTTPS}/metrics"

# Check ping endpoint
logfg "Checking the ping endpoint..."
curl  $CURL_COMMON_OPTS "${ALERTSTACK_HTTPS}/ping"

# Check time endpoint
logfg "Checking the time endpoint..."
curl $CURL_COMMON_OPTS "${ALERTSTACK_HTTPS}/time"

# Check echo endpoint
logfg "Checking the echo endpoint..."
curl $CURL_COMMON_OPTS "${ALERTSTACK_HTTPS}/echo"

# Get metric names
logfg "Getting the list of known test metric names..."
curl $CURL_COMMON_OPTS "${ALERTSTACK_HTTPS}/metrics" | \
    prom2json | \
    jq ".[].name"

# Update test
logfg "Testing the metric update process..."
send_metric "${ALERTSTACK_HTTPS}/update" "$METRICLINE"

# Enqueue notifications
logfg "Testing notification enqueue to slack/pagerduty ..."
curl $CURL_COMMON_OPTS "${ALERTSTACK_HTTPS}/metrics" | \
    prom2json | \
    curl $CURL_COMMON_OPTS \
    -H 'Content-Type: application/json' \
    --data-binary @- "${ALERTSTACK_HTTPS}/v2/enqueue"

logfg "All tests and examples completed successfully"
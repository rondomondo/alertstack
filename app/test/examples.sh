echo 'bgp_neighbors_status{cluster="eu-data", alertname="BGP_down", extra_slack_recipient_test="#alert-receiver", \
receiver="slack-receiver-sre",deployment="default1", instance="i-service.syd", job="default1TargetsWithAuth", \
network_region="APAC", peer_asn="1234", peer_ip="128.166.10.1", peer_name="SYD-DAVE", peer_type="Pipe", pop="syd", \ 
region="eu-central-1-data", servergroup="default", severity="critical"} 8' 
| prom2json |  curl  -H 'Content-Type: application/json' --data-binary @- http://alertstack.io:8090/create


read -r -d '' METRICLINE <<-EOM
bgp_neighbors_status{cluster="eu-data", alertname="BGP_down", extra_slack_recipient_test="#alert-receiver", \
deployment="default1", instance="i-service.syd", job="default1TargetsWithAuth", \
network_region="APAC", peer_asn="1234", peer_ip="128.166.10.1", peer_name="SYD-DAVE", peer_type="Pipe", pop="syd", \
region="eu-central-1-data", servergroup="default", receiver="slack-receiver-sre", severity="critical"} 1
EOM

# To check if the format is ok quickly use prom2json
echo "$METRICLINE" | prom2json | jq


## CREATE ##
# Create an exact lable copy of the metric we want to test in alertstack.
# Basically just pipe it via curl to the create endpoint. We will stick with json format here...

echo "$METRICLINE" | prom2json | curl  -H 'Content-Type: application/json' --data-binary @- http://alertstack.io:8090/create
# The metric is returned on success

cat  <<-EOM
bgp_neighbors_status{cluster="eu-data", alertname="BGP_down", extra_slack_recipient_test="#alert-receiver", \
deployment="default1", instance="i-service.syd", job="default1TargetsWithAuth", \
network_region="APAC", peer_asn="1234", peer_ip="128.166.10.1", peer_name="SYD-DAVE", peer_type="Pipe", pop="syd", \
region="eu-central-1-data", servergroup="default", pd_group="noc", receiver="pagerduty-receiver-sre", severity="critical"} 1
EOM

# Lets create another one but this time text format - not json
echo "$METRICLINE" | curl --data-binary @- https://alertstack.io/create

# BGP_down
echo "$(cat test/BGP_down.slack.prom)" | curl --data-binary @- https://alertstack.io/create

echo "$(cat test/BGP_down.slack.prom)" | curl --data-binary @- https://alertstack.io/update

# This creates metrics one at a time. We can also do as many metrics at the same time as we like. HTTP or HTTPS.

echo "$(cat test/multi_metric.prom)"| prom2json | curl -H 'Content-Type: application/json' --data-binary @- https://alertstack.io/create

echo "$(cat test/bgp_neighbors_status_test.prom)" | curl --data-binary @- https://alertstack.io/create

echo "$(cat test/bgp_neighbors_status.prom)" | curl --data-binary @- https://alertstack.io/create

# warning slack
echo "$(cat test/node_directory_size_bytes.slack.prom)" | curl --data-binary @- https://alertstack.io/create

# critical slack and pagerduty
echo "$(cat test/node_directory_size_bytes.page.prom)" | curl --data-binary @- https://alertstack.io/create



echo "metric_with_no_labels 1" | curl --data-binary @- https://alertstack.io/create

# notice how the .prom files are in perfect order

# Access the metrics endpoint with proper cert
curl https://alertstack.io/metrics

# Get all created metrics
curl --silent  https://alertstack.io/metrics | prom2json | jq ".[].name"

## UPDATE ##
# Same input as the create but replace create with update.  Each metric will be increated by 1
echo "$METRICLINE" | curl --data-binary @- https://alertstack.io/update


# Notifiers/Notifications to pagerduty/slack
#Add 
receiver="pagerduty-receiver-sre" # label for pagerduty notification, and
receiver="slack-receiver-sre" # label for slack notification, and

# Test Pagerduty Service is https://incapsula.pagerduty.com/service-directory/P46DZ5S

curl --silent  https://alertstack.io/metrics | prom2json |  curl -H 'Content-Type: application/json' --data-binary @- https://alertstack.io/v2/enqueue

aws s3 cp prometheus/ s3://alertstack-io/alertstack.io/prometheus/ --recursive \
  --exclude "*" --include "*.yml" --content-type "text/plain"

aws s3 cp prometheus/ s3://alertstack-io/alertstack.io/prometheus/ --recursive \
  --exclude "*.yml"

aws s3 cp alertmanager/ s3://alertstack-io/alertstack.io/alertmanager/ --recursive \                                                  
  --exclude "*" --include "*.yml" --content-type "text/plain"

aws s3 cp alertmanager/ s3://alertstack-io/alertstack.io/alertmanager/ --recursive \
  --exclude "*.yml"




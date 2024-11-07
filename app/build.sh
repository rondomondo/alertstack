#!/usr/bin/env bash

# the directory of the script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd $DIR

cp -r ../letsencrypt/certs .
echo "#######"
echo
echo "build: install prom2json libs..."
GO111MODULE=on go install github.com/prometheus/prom2json/cmd/prom2json@latest
echo "built: install prom2json libs..."
echo

echo "#######"
echo
# build a container version of the pingpong server
echo "build: image abcdef/pingpong ..."
docker build --tag abcdef/pingpong .
echo
echo "built: image abcdef/pingpong"

echo
echo "# to run this container do..."
echo
echo "docker run -p 8090:8090 -p 8443:8443 --detach --rm --name pingpong abcdef/pingpong"
echo
echo "#######"
echo
echo "build: ./pingpong locally ..."
# build a local go executable
go mod init pingpong
go mod tidy
go build -o pingpong
echo 
echo "built: ./pingpong locally"
echo
# lets run it locally then call two of the endpoints...

./pingpong -h

echo
echo "#######"
echo
echo "# to run locally do..."
echo

cat <<EOM
./pingpong &

sleep 3

# sample endpoints to call
# /ping will increase the ping_request_count counter by 1
curl http://localhost:8090/ping

# /metrics returns the metrics from the prometheus go client built in to pingpong
curl http://localhost:8090/metrics

# /time just returns a time string
curl http://localhost:8090/time
EOM


#!/usr/bin/env bash
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

REGION="${region}"
DEPLOY_BUCKET="${deploy_bucket}"
APP_DIR="/opt/alertstack"
REPO_URL="https://github.com/rondomondo/alertstack.git"

echo "export APP_DIR=$APP_DIR" >> /home/ubuntu/.bashrc
echo "export APP_DIR=$APP_DIR" >> /root/.bashrc

# Install system packages (mirrors: make install-ubuntu)
apt-get update -y
apt-get upgrade -y
apt-get install -y amazon-ec2-utils
apt-get install -y make docker.io htop lsof docker-compose golang locate awscli

snap install astral-uv --classic
updatedb

export GOPATH="/root/go"
export GOCACHE="/root/.cache/go-build"
export PATH="$GOPATH:$GOPATH/bin:$PATH"

# Enable and start Docker
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# Clone alertstack repo
git clone "$REPO_URL" "$APP_DIR"
chown -R ubuntu:ubuntu "$APP_DIR"

echo "export PATH=$PATH" >> /home/ubuntu/.bashrc
echo "export PATH=$PATH" >> /root/.bashrc


ALERTSTACK_HOST=alertstack.link

echo "export ALERTSTACK_HOST=$ALERTSTACK_HOST" >> /home/ubuntu/.bashrc
echo "export ALERTSTACK_HOST=$ALERTSTACK_HOST" >> /root/.bashrc
echo "$(ec2-metadata --public-ipv4 | sed 's/public-ipv4: //') $ALERTSTACK_HOST" >> /etc/hosts

# Download redeploy script from S3
aws s3 cp "s3://$DEPLOY_BUCKET/scripts/redeploy.sh" /usr/local/bin/redeploy.sh \
  --region "$REGION"

chmod +x /usr/local/bin/redeploy.sh

GOTOOLCHAIN=auto go install github.com/prometheus/prom2json/cmd/prom2json@latest && /bin/cp /root/go/bin/* /usr/local/bin/ &

GOTOOLCHAIN=auto go install github.com/prometheus/alertmanager/cmd/amtool@latest && /bin/cp /root/go/bin/* /usr/local/bin/ &

# Start the stack — sg docker ensures the group is active even in the same session
sudo -u ubuntu sg docker -c "cd $APP_DIR && make stack-up" && echo "Bootstrap complete." \
  || echo "WARNING: initial stack-up failed -- run: cd $APP_DIR && sudo -u ubuntu sg docker -c 'make stack-up'"


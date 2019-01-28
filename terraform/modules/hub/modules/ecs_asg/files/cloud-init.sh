#!/usr/bin/env bash
set -ueo pipefail

CURL="curl"
if [ -n "${egress_proxy_url_with_protocol}" ]; then
  CURL="curl --proxy ${egress_proxy_url_with_protocol}"
fi

# Apt
echo 'Configuring apt'
mkdir -p /etc/apt/apt.conf.d
if [ -n "${egress_proxy_url_with_protocol}" ]; then
  cat << EOF > /etc/apt/apt.conf.d/egress.conf
Acquire::http::Proxy "${egress_proxy_url_with_protocol}/";
Acquire::https::Proxy "${egress_proxy_url_with_protocol}/";
EOF
fi
apt-get update  --yes
apt-get upgrade --yes

# AWS SSM Agent
# Installed by default on Ubuntu Bionic AMIs via Snap
echo 'Configuring AWS SSM'
mkdir -p /etc/systemd/system/snap.amazon-ssm-agent.amazon-ssm-agent.service.d
if [ -n "${egress_proxy_url_with_protocol}" ]; then
cat <<EOF > /etc/systemd/system/snap.amazon-ssm-agent.amazon-ssm-agent.service.d/override.conf
[Service]
Environment="http_proxy=${egress_proxy_url_with_protocol}"
Environment="https_proxy=${egress_proxy_url_with_protocol}"
Environment="no_proxy=169.254.169.254"
EOF
fi
mkdir -p /etc/amazon/ssm
cat <<EOF > /etc/amazon/ssm/seelog.xml
<seelog type="adaptive" mininterval="2000000" maxinterval="100000000" critmsgcount="500" minlevel="warn">
    <exceptions>
        <exception filepattern="test*" minlevel="error"/>
    </exceptions>
    <outputs formatid="fmtinfo">
        <console formatid="fmtinfo"/>
    </outputs>
    <formats>
        <format id="fmterror" format="%Date %Time %LEVEL [%FuncShort @ %File.%Line] %Msg%n"/>
        <format id="fmtdebug" format="%Date %Time %LEVEL [%FuncShort @ %File.%Line] %Msg%n"/>
    </formats>
</seelog>
EOF
systemctl stop snap.amazon-ssm-agent.amazon-ssm-agent
systemctl daemon-reload
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent

# Use Amazon NTP
echo 'Installing and configuring chrony'
apt-get install --yes chrony
sed '/pool/d' /etc/chrony/chrony.conf \
| cat <(echo "server 169.254.169.123 prefer iburst") - > /tmp/chrony.conf
echo "allow 127/8" >> /tmp/chrony.conf
mv /tmp/chrony.conf /etc/chrony/chrony.conf
systemctl restart chrony

# Docker
echo 'Installing and configuring docker'
mkdir -p /etc/systemd/system/docker.service.d
apt-get install --yes docker.io
cat <<EOF > /etc/systemd/system/docker.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --log-driver journald --dns 10.0.0.2
EOF
if [ -n "${egress_proxy_url_with_protocol}" ]; then
cat <<EOF >> /etc/systemd/system/docker.service.d/override.conf
Environment="HTTP_PROXY=${egress_proxy_url_with_protocol}"
Environment="HTTPS_PROXY=${egress_proxy_url_with_protocol}"
EOF
fi

# Reload systemctl daemon to pick up new override files
systemctl stop docker
systemctl daemon-reload
systemctl start docker

# Journalbeat for log shipping
echo 'Installing and configuring journalbeat'
(
elastic_beats="artifacts.elastic.co/downloads/beats"
mkdir -p /tmp/journalbeat
cd /tmp/journalbeat

cat <<EOF > journalbeat-6.5.4-amd64.deb.sha512
5c748e2661d16e004606dea4332deb2e990996056e00a54ecbbf691ab3cd33e02d76ce3609fecade326d8fd06e7b3eb328f92de24cd16c8f49ec3c80e14c8ad4  journalbeat-6.5.4-amd64.deb
EOF

$CURL --silent --fail \
      -L -O \
      "https://$elastic_beats/journalbeat/journalbeat-6.5.4-amd64.deb"

sha512sum -c journalbeat-6.5.4-amd64.deb.sha512
dpkg -i journalbeat-6.5.4-amd64.deb
)

cat <<EOF > /etc/journalbeat/journalbeat.yml
journalbeat.inputs:
- paths: []
  seek: cursor

logging.level: warning
logging.to_files: false
logging.to_syslog: true

processors:
- add_cloud_metadata: ~
- add_docker_metadata: ~

output.elasticsearch:
  ${journalbeat_egress_proxy_setting}
  hosts: ["https://${logit_elasticsearch_url}:443"]
  headers:
    Apikey: ${logit_api_key}
EOF
systemctl restart journalbeat

# ECS
echo 'Running ECS using Docker'
mkdir -p /etc/ecs
mkdir -p /var/lib/ecs/data

docker run \
  --init \
  --privileged \
  --name ecs-agent \
  --detach=true \
  --restart=on-failure:10 \
  --volume=/etc/ecs:/etc/ecs \
  --volume=/lib64:/lib64 \
  --volume=/lib:/lib \
  --volume=/proc:/host/proc \
  --volume=/sbin:/sbin \
  --volume=/sys/fs/cgroup:/sys/fs/cgroup \
  --volume=/usr/lib:/usr/lib \
  --volume=/var/lib/ecs/data:/data \
  --volume=/var/lib/ecs/dhclient:/var/lib/dhclient \
  --volume=/var/run:/var/run \
  --net=host \
  --env="ECS_CLUSTER=${cluster}" \
  --env="${ecs_egress_proxy_setting}" \
  --env=AWS_DEFAULT_REGION=eu-west-2 \
  --env="NO_PROXY=169.254.169.254,169.254.170.2,/var/run/docker.sock" \
  --env=ECS_DATADIR=/data \
  --env=ECS_ENABLE_TASK_ENI=true \
  --env=ECS_ENABLE_TASK_IAM_ROLE=true \
  --env=ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true \
  --env='ECS_AVAILABLE_LOGGING_DRIVERS=["journald"]' \
  --env="ECS_LOGLEVEL=warn" \
  amazon/amazon-ecs-agent:v1.23.0

apt-get install --yes prometheus-node-exporter
mkdir /etc/systemd/system/prometheus-node-exporter.service.d
# Create an environment file for prometheus node exporter
cat >  /etc/systemd/system/prometheus-node-exporter.service.d/prometheus-node-exporter.env <<EOF
ARGS="--collector.ntp --collector.diskstats.ignored-devices=^(ram|loop|fd|(h|s|v|xv)d[a-z]|nvme\\d+n\\d+p)\\d+$ --collector.filesystem.ignored-mount-points=^/(sys|proc|dev|run|var/lib/docker)($|/) --collector.netdev.ignored-devices=^lo$ --collector.textfile.directory=/var/lib/prometheus/node-exporter"
EOF
# Create an override file which will override prometheus node exporter service file
cat > /etc/systemd/system/prometheus-node-exporter.service.d/10-override-args.conf <<EOF
[Service]
EnvironmentFile=/etc/systemd/system/prometheus-node-exporter.service.d/prometheus-node-exporter.env
EOF
systemctl daemon-reload
systemctl enable prometheus-node-exporter
systemctl restart prometheus-node-exporter

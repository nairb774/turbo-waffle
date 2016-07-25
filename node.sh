#!/bin/bash -ex

MASTER_IP="$1"
K8S_VERSION=1.3.3
FLANNEL_VERSION=0.5.5
FLANNEL_IFACE=eth0
FLANNEL_IPMASQ=true

# Install docker per: https://docs.docker.com/engine/installation/linux/ubuntulinux/
apt-get update
apt-get install apt-transport-https ca-certificates
apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
mkdir -p /etc/apt/sources.list.d
echo 'deb https://apt.dockerproject.org/repo ubuntu-trusty main' > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get -y install bridge-utils docker-engine

# Setup k8s per: http://kubernetes.io/docs/getting-started-guides/docker-multinode/master/

sh -c 'docker daemon -H unix:///var/run/docker-bootstrap.sock -p /var/run/docker-bootstrap.pid --iptables=false --ip-masq=false --bridge=none --graph=/var/lib/docker-bootstrap 2> /var/log/docker-bootstrap.log 1> /dev/null &'
until docker -H unix:///var/run/docker-bootstrap.sock ps; do # Need a way to know when it is up...
  sleep 1
done

stop docker || echo 'Docker already down'

docker -H unix:///var/run/docker-bootstrap.sock run -d \
    --label flanneld \
    --net=host \
    --privileged \
    -v /dev/net:/dev/net \
    quay.io/coreos/flannel:${FLANNEL_VERSION} \
    /opt/bin/flanneld \
        --ip-masq=${FLANNEL_IPMASQ} \
        --etcd-endpoints=http://${MASTER_IP}:4001 \
        --iface=${FLANNEL_IFACE}

# TODO: Wait for flannel to come up fully before going on...

# Configure the system container to make use of the flannel server:
cat << 'EOF' >> /etc/default/docker
FLANNEL_ID="$(docker -H unix:///var/run/docker-bootstrap.sock ps --filter label=flanneld --format '{{.ID}}')"
eval "$(docker -H unix:///var/run/docker-bootstrap.sock exec "$FLANNEL_ID" cat /run/flannel/subnet.env)"
DOCKER_OPTS="$DOCKER_OPTS --bip=${FLANNEL_SUBNET} --mtu=${FLANNEL_MTU}"
EOF

# Remove the old bridge.
ifconfig docker0 down
brctl delbr docker0

start docker
until docker ps; do  # Wait for it to come up (need a better solution)
  sleep 1
done

docker run \
    --volume=/:/rootfs:ro \
    --volume=/sys:/sys:ro \
    --volume=/dev:/dev \
    --volume=/var/lib/docker/:/var/lib/docker:rw \
    --volume=/var/lib/kubelet/:/var/lib/kubelet:rw \
    --volume=/var/run:/var/run:rw \
    --net=host \
    --privileged=true \
    --pid=host \
    -d \
    gcr.io/google_containers/hyperkube-amd64:v${K8S_VERSION} \
    /hyperkube kubelet \
        --allow-privileged=true \
        --api-servers=http://${MASTER_IP}:8080 \
        --v=2 \
        --address=0.0.0.0 \
        --enable-server \
        --containerized \
        --cluster-dns=10.0.0.10 \
        --cluster-domain=cluster.local

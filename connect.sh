#!/bin/bash

# docker run --rm -ti -p 3223:3223 -e AUTHORIZED_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC6JqwBKh4FSQdxQAwT27R33qB2+f7hcDuJCn0jcH2fgdcfVLpRS/97xQsvYYAMpW7lwZs7Y4hGIsWstKnXW8n0cG/xYVWLHqlxkNGHZBfUlHfGDNEHWaIdIhnnKnScj85KJmx/AWDDd0eZY1/JR0yb0MPG3Im3jQdXTJqwolRUfMIn/kDDqzYligHiBxwlssZv2BQt+jTP8uXOtL1iLK3g8+GtXvjRzpXfAj4BueUeGxd1nfFcdUv29WHlYxzLTzMj7VljmZWBPkFMEk8P6yxQNPlnNTTNYgVZQx1Ozf0Q7ivJnlwHspziebiWet0t5zWIS3EGo6dqtl3ZFO1sqBpB khagerma@ONM-KHAGERMA-01" become-proxy

set -eo pipefail

# if the shell exits, close all running jobs
trap 'kill $(jobs -p) 2>/dev/null' EXIT

# if unknown, print
if [[ "$1" == "help" || "$1" == "--help" || "$1" == "-h" || "$1" == "h" ]]; then
  echo "usage:"
  echo "    $0 <ports...>"
  echo
  echo "    <ports...> ports that should be forwarded from the remote pod to a local server"
  echo "               i.e. - what ports in-dev app listens on"
  exit
fi

# ask for sudo here, so we have it later
sudo -p "[local sudo] Password:" echo >/dev/null

# if the proxy pod doesn't exist
if ! kubectl get --namespace=default deployment "become-proxy" >/dev/null 2>&1; then
  # create it, and wait for it to start
  echo -n "Creating proxy pod... "
  kubectl apply --namespace=default -f become-proxy.yml >/dev/null
  until kubectl rollout --namespace=default status deployment/become-proxy >/dev/null; do
    sleep 1
  done
  echo "OK"
fi

# port forwarding for DNS requests local -> remote; other ssh config
CMD="ssh -o ConnectTimeout=2 -o ConnectionAttempts=1 -o ServerAliveInterval=1 -o ServerAliveCountMax=2 -i $PWD/.identity -L 5353:127.0.0.1:5353"
# parse remaining parameters as forwarded ports
for port in "$@"; do
  # port forwarding for ports remote -> local
  CMD="$CMD -R $port:localhost:$port"
done

# create identity file with known private key
# TODO: this is very insecure
cat >.identity <<EOF
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQQjeYrWZAHGQc8Vd2uSYlPg4zCSJfoV
+aK9UOewMWOm3d2v4Dq/SVE1alUpipCw1+HKWFupOEjdm/fsUpAUzUjQAAAAuJNJ5DqTSe
Q6AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCN5itZkAcZBzxV3
a5JiU+DjMJIl+hX5or1Q57AxY6bd3a/gOr9JUTVqVSmKkLDX4cpYW6k4SN2b9+xSkBTNSN
AAAAAhAN8e/IOUXS8ypBsprs9JeBVtZ+R9Hpz6sHJYvXQrV+gpAAAAGGtoYWdlcm1hQE9O
TS1LSEFHRVJNQS0wMQECAwQFBgc=
-----END OPENSSH PRIVATE KEY-----
EOF
chmod 600 .identity

echo -n "Setup tunnel... "
kubectl port-forward --namespace=default deployment/become-proxy 32233 >/dev/null &
proxyPortForwardPid=$!
echo "OK"

# determine the cluster & service subnets
echo -n "Determining subnets... "
SUBNET=($(kubectl cluster-info dump | grep -E -- '--service-cluster-ip-range=|--cluster-cidr=' | sed -e 's/[^0-9]*\([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\/[0-9]*\).*/\1/'))
echo "${SUBNET[0]}" "${SUBNET[1]}"

# most of the heavy lifting is done by sshuttle
echo -n "Setup sshuttle connection... "
# TODO might need to --exclude the server IP from forwarding if the k8s subnets include it
if ! sshuttle -e "$CMD" -r "root@localhost:32233" -D --pidfile=".sshuttle.pid" "${SUBNET[0]}" "${SUBNET[1]}"; then
  rm -f .identity
  echo "Failed to connect."
  exit
fi
rm -f .identity
sshuttlePid="$(cat .sshuttle.pid)"
echo "OK"

# make sure forwarding still works when connected to a VPN (tested with Pulse Secure on OSX)
echo -n "Setup VPN override... "
if [[ "$OSTYPE" == "linux-gnu" ]]; then
  sudo -p "[local sudo] Password:" ip route add "${SUBNET[0]}" via default
  sudo -p "[local sudo] Password:" ip route add "${SUBNET[1]}" via default
  # after sshuttle exits, remove the route without requiring sudo
  sudo -p "[local sudo] Password:" -- sh -c "while [[ -e .sshuttle.pid ]]; do sleep 1; done; ip route del '${SUBNET[0]}' via default; ip route del '${SUBNET[1]}' via default" &
  echo "OK"
elif [[ "$OSTYPE" == "skipdarwin"* ]]; then
  sudo -p "[local sudo] Password:" route -n add -net "${SUBNET[0]}" default >/dev/null
  sudo -p "[local sudo] Password:" route -n add -net "${SUBNET[1]}" default >/dev/null
  # after sshuttle exits, remove the route without requiring sudo
  sudo -p "[local sudo] Password:" -- sh -c "while [[ -e .sshuttle.pid ]]; do sleep 1; done; route -n delete -net '${SUBNET[0]}' default >/dev/null; route -n delete -net '${SUBNET[1]}' default >/dev/null" &
  echo "OK"
else
  echo "Skipped"
fi

# forward DNS requests made to localhost across the connection
echo -n "Setup DNS forwarding... "
socat -T15 udp4-recvfrom:53,reuseaddr,fork tcp:localhost:5353 2>/dev/null &
dnsForwardPid=$!
echo "OK"

# setup split DNS
# send requests for *.cluster.local to localhost
echo -n "Setup split DNS... "
sudo -p "[local sudo] Password:" mkdir -p /etc/resolver
sudo -p "[local sudo] Password:" chown $(id -u):$(id -g) /etc/resolver # perhaps not the best solution, grant access to the dir so we can delete files later
echo 'nameserver 127.0.0.1' >/etc/resolver/cluster.local
echo "OK"

echo "All OK"

# wait for sshuttle to exit, or ctrl-c
trap "echo" INT
while [[ -e .sshuttle.pid ]] && kill -0 "$dnsForwardPid" && kill -0 "$proxyPortForwardPid"; do sleep 2 || break; done

# remove *.cluster.local DNS rules
echo "Teardown split DNS..."
rm -f /etc/resolver/cluster.local

echo "Teardown DNS forwarding..."
kill "$dnsForwardPid" 2>/dev/null || true
wait "$dnsForwardPid" 2>/dev/null || true

echo "Teardown sshuttle connection..."
kill "$sshuttlePid" 2>/dev/null || true
wait "$sshuttlePid" 2>/dev/null || true

echo "Teardown tunnel..."
kill "$proxyPortForwardPid" 2>/dev/null || true
wait "$proxyPortForwardPid" 2>/dev/null || true

echo "Teardown VPN override..."
# teardown handled by background process when sshuttle exits
sleep 1

#!/bin/bash

# docker run --rm -ti -p 3223:3223 -e AUTHORIZED_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC6JqwBKh4FSQdxQAwT27R33qB2+f7hcDuJCn0jcH2fgdcfVLpRS/97xQsvYYAMpW7lwZs7Y4hGIsWstKnXW8n0cG/xYVWLHqlxkNGHZBfUlHfGDNEHWaIdIhnnKnScj85KJmx/AWDDd0eZY1/JR0yb0MPG3Im3jQdXTJqwolRUfMIn/kDDqzYligHiBxwlssZv2BQt+jTP8uXOtL1iLK3g8+GtXvjRzpXfAj4BueUeGxd1nfFcdUv29WHlYxzLTzMj7VljmZWBPkFMEk8P6yxQNPlnNTTNYgVZQx1Ozf0Q7ivJnlwHspziebiWet0t5zWIS3EGo6dqtl3ZFO1sqBpB khagerma@ONM-KHAGERMA-01" become-proxy

set -eo pipefail

# if unknown, print
if [[ "$1" == "" ]]; then
  echo "usage:"
  echo "    $0 <server-ip>[:<port>] <ports...>"
  echo
  echo "    <ports...> ports that should be forwarded from the remote pod to a local server"
  echo "               i.e. - what ports in-dev app listens on"
  exit
fi

# determine ip:port
SERVER_IP_PORT="$1"
shift
SERVER_IP=(${SERVER_IP_PORT//:/ })
SERVER_PORT=${SERVER_IP[1]}
SERVER_IP=${SERVER_IP[0]}
if [[ "$SERVER_IP_PORT" == "$SERVER_IP" ]]; then
  SERVER_IP_PORT="$SERVER_IP_PORT:32233"
  SERVER_PORT=32233
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
chmod 400 .identity

# connect to the pod, and determine the k8s subnet on a best-effort basis
# TODO: currently cannot determine range size (/8, /16, /24, etc.) /16 is assumed
echo -n "Determining subnet... "
SUBNET=$(ssh -p "$SERVER_PORT" -i "$PWD/.identity" "root@$SERVER_IP" "awk '/^nameserver/{print \$2}' /etc/resolv.conf")/16
echo "$SUBNET"

# most of the heavy lifting is done by sshuttle
echo -n "Setup sshuttle connection... "
if ! sshuttle -e "$CMD" -r "root@$SERVER_IP_PORT" --exclude "$SERVER_IP" -D --pidfile=".sshuttle.pid" "$SUBNET"; then
  rm -f .identity
  echo "Failed to connect."
  exit
fi
rm -f .identity
echo "OK"

# forward DNS requests made to localhost across the connection
echo -n "Setup DNS forwarding... "
socat -T15 udp4-recvfrom:53,reuseaddr,fork tcp:localhost:5353 2>/dev/null &
echo "OK"

# setup split DNS
# send requests for *.cluster.local to localhost
echo -n "Setup split DNS... "
sudo -p "[local sudo] password:" mkdir -p /etc/resolver
sudo chown $(id -u):$(id -g) /etc/resolver # perhaps not the best solution, grant access to the dir so we can delete files later
echo 'nameserver 127.0.0.1' >/etc/resolver/cluster.local
echo "OK"

echo "All OK"

# wait for sshuttle to exit, or ctrl-c
trap "echo" INT
while [[ -e .sshuttle.pid ]]; do sleep 1 || break; done

# remove *.cluster.local DNS rules
echo "Teardown split DNS..."
rm -f /etc/resolver/cluster.local

echo "Teardown DNS forwarding..."
kill $(jobs -p) 2>/dev/null || true
wait $(jobs -p) || true

echo "Teardown sshuttle connection..."
kill $(cat .sshuttle.pid 2>/dev/null) 2>/dev/null || true
wait $(cat .sshuttle.pid 2>/dev/null) || true

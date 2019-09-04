#!/bin/bash

set -eo pipefail

# ask for sudo here, so we have it later
sudo -p "[local sudo] Password:" echo >/dev/null

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR"

## verify UUID is generated
#if [[ -f .uuid ]]; then
#  UUID="$(cat .uuid)"
#else
#  UUID="$(cat /dev/urandom | LC_CTYPE=C tr -dc a-zA-Z0-9 | fold -w 16 | head -n 1)" || true
#  echo "$UUID" > .uuid
#fi

# add to existing forward folder structure
NAMESPACE="$(kubectl config view -o jsonpath='{.contexts[0].context.namespace}')"
if [[ "$NAMESPACE" == "" ]]; then
  NAMESPACE="default"
fi
while [[ "$#" -ne 0 ]]; do
  if [[ "$1" == "--namespace" ]]; then
    NAMESPACE="$2"
    shift
  elif [[ "$1" == "--namespace="* ]]; then
    NAMESPACE="${1#"--namespace="}"
  else
    SERVICE="$1"
    mkdir -p ".redirected/$NAMESPACE/$SERVICE"

    # if this information is not already recorded
    echo -n "$SERVICE: "
    if ! [[ -f ".redirected/$NAMESPACE/$SERVICE/original-selector.txt" ]]; then
      echo -n "Saving selector... "
      ORIGINAL_SELECTOR="$(kubectl get --namespace="$NAMESPACE" svc --output=go-template='{{ $first := true }}{{ range $k, $v := .spec.selector }}{{if eq $first true }}{{ $first = false }}{{ else }},{{ end }}"{{ js $k }}":"{{ js $v }}"{{ end }}' "$SERVICE")"
      echo -n "OK;  Detecting Ports... "
      PORTS="$(kubectl get --namespace="$NAMESPACE" svc --output=go-template='{{ $first := true }}{{ range $k, $v := .spec.ports }}{{if eq $first true }}{{ $first = false }}{{ else }} {{ end }}{{ $v.targetPort }}{{ end }}' "$SERVICE")"

      echo "$ORIGINAL_SELECTOR" >".redirected/$NAMESPACE/$SERVICE/original-selector.txt"
      echo "$PORTS" >".redirected/$NAMESPACE/$SERVICE/ports.txt"
      echo -n "$PORTS; "
    fi

    echo -n "Redirecting service... "
    kubectl patch --namespace="$NAMESPACE" svc "$SERVICE" --type=json --patch='[{"op": "replace", "path": "/spec/selector", "value":{"proxy":"unique-tag"}}]' >/dev/null
    echo "OK"
  fi
  shift
done

mkdir -p .redirected/
cd .redirected/

# ensure required proxy pods exist
for NAMESPACE in */; do
  NAMESPACE="${NAMESPACE%/}"
  if [[ "$NAMESPACE" != "*" ]]; then
    # if the proxy pod doesn't exist
    if ! kubectl get deployment --namespace="$NAMESPACE" "become-proxy" >/dev/null 2>&1; then
      # create it, and wait for it to start
      echo -n "Creating proxy pod in $NAMESPACE... "
      kubectl apply --namespace="$NAMESPACE" -f "$DIR/become-proxy.yml" >/dev/null
      until kubectl rollout status --namespace="$NAMESPACE" deployment/become-proxy >/dev/null; do
        sleep 1
      done
      echo "OK"
    fi
  fi
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

# create ssh tunnels for each service
echo "Setting up tunnels..."
for NAMESPACE in */; do
  NAMESPACE="${NAMESPACE%/}"
  if [[ "$NAMESPACE" != "*" ]]; then
    cd "$NAMESPACE"

    # read the list of ports
    PORTS=()
    for SERVICE_PORTS in */ports.txt; do
      PORTS+=($(cat "$SERVICE_PORTS"))
    done

    echo -n "  $NAMESPACE (${PORTS[@]})... "
    if [[ -f ssh-pid.txt ]] && kill -0 "$(cat ssh-pid.txt)" 2>/dev/null && [[ -f ssh-ports.txt && "$(cat ssh-ports.txt)" == "${PORTS[@]}" ]]; then
      echo "Exists"
    else
      rm ssh-pid.txt ssh-ports.txt 2>/dev/null || true

      # convert list of ports to ssh tunneling parameters
      CMD=()
      for port in ${PORTS[@]}; do
        # port forwarding for ports remote -> local
        CMD+=("${CMD[@]}" "-R" "$port:localhost:$port")
      done

      # start ssh session
      nohup ssh -o ConnectTimeout=2 -o ConnectionAttempts=1 -o ServerAliveInterval=1 -o ServerAliveCountMax=2 -i "$DIR/.redirected/.identity" ${CMD[@]} -p 32233 -N root@become-proxy."$NAMESPACE".svc.cluster.local >/dev/null 2>&1 &
      echo "$!" >ssh-pid.txt
      echo "${PORTS[@]}" >ssh-ports.txt

      echo "OK"
    fi
    cd ..
  fi
done

sleep 1
rm -f .identity









#echo -n "Setup tunnel... "
#kubectl port-forward --namespace="$NAMESPACE" deployment/become-proxy 32233 >/dev/null &
#proxyPortForwardPid=$!
#echo "OK"

#echo "Redirecting service(s):"
#SERVICE_PORTS=()
#ORIGINAL_SELECTORS=("")
#for SERVICE in "$@"; do
#  echo -n "  $SERVICE: Saving selector... "
#  ORIGINAL_SELECTOR="$(kubectl get svc --output=go-template='{{ $first := true }}{{ range $k, $v := .spec.selector }}{{if eq $first true }}{{ $first = false }}{{ else }},{{ end }}"{{ js $k }}":"{{ js $v }}"{{ end }}' "$SERVICE")"
#  ORIGINAL_SELECTORS+=("$ORIGINAL_SELECTOR")
#  echo -n "OK;  Detecting Ports... "
#  PORTS="$(kubectl get svc --output=go-template='{{ $first := true }}{{ range $k, $v := .spec.ports }}{{if eq $first true }}{{ $first = false }}{{ else }} {{ end }}{{ $v.targetPort }}{{ end }}' "$SERVICE")"
#  echo -n "$PORTS;  Redirecting service... "
#  SERVICE_PORTS+=(${PORTS})
#  kubectl patch svc "$SERVICE" --type=json --patch='[{"op": "replace", "path": "/spec/selector", "value":{"proxy":"unique-tag"}}]' >/dev/null
#  echo "OK"
#done

#echo "Will forward ports: ${SERVICE_PORTS[@]}"
#"$DIR/connect.sh" ${SERVICE_PORTS[@]} || true



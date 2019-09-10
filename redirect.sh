#!/bin/bash

set -eo pipefail

print_usage() {
  echo "Usage:"
  echo "  $0 [--redirect] <service> ..."
  echo "  $0 --revert [<service> ...]"
  echo "  $0 --revert-all"
  echo "  Flags:"
  echo "    --namespace=<namespace> ... Can be specified more than once, changes namespace for subsequent services"
}

redirect_service() { # $1, $2 := namespace, service
  mkdir -p ".redirected/$1/$2"

  # if this information is not already recorded
  echo -n "Redirect $2: "
  if ! [[ -f ".redirected/$1/$2/original-selector.txt" ]]; then
    echo -n "Saving selector... "
    ORIGINAL_SELECTOR="$(kubectl get --namespace="$1" svc --output=go-template='{{ $first := true }}{{ range $k, $v := .spec.selector }}{{if eq $first true }}{{ $first = false }}{{ else }},{{ end }}"{{ js $k }}":"{{ js $v }}"{{ end }}' "$2")"
    echo -n "OK;  Detecting Ports... "
    PORTS="$(kubectl get --namespace="$1" svc --output=go-template='{{ $first := true }}{{ range $k, $v := .spec.ports }}{{if eq $first true }}{{ $first = false }}{{ else }} {{ end }}{{ $v.targetPort }}{{ end }}' "$2")"

    echo "$ORIGINAL_SELECTOR" >".redirected/$1/$2/original-selector.txt"
    echo "$PORTS" >".redirected/$1/$2/ports.txt"
    echo -n "$PORTS; "
  fi

  echo -n "Redirecting service... "
  kubectl patch --namespace="$1" svc "$2" --type=json --patch='[{"op": "replace", "path": "/spec/selector", "value":{"proxy":"unique-tag"}}]' >/dev/null
  echo "OK"
}

revert_service() { # $1, $2 := namespace, service
  # if this information was recorded
  echo -n "Revert $2: "
  if [[ -f .redirected/"$1/$2"/original-selector.txt ]]; then
    # revert it
    ORIGINAL_SELECTOR="$(cat ".redirected/$1/$2/original-selector.txt")"
    echo -n "($ORIGINAL_SELECTOR)... "
    kubectl patch --namespace="$1" svc "$2" --type=json --patch='[{"op": "replace", "path": "/spec/selector", "value":{'"$ORIGINAL_SELECTOR}}]" >/dev/null
    rm ".redirected/$1/$2/original-selector.txt"
    rm ".redirected/$1/$2/ports.txt"
    rm -r ".redirected/$1/$2"
    echo "OK"
  else
    echo "Unaltered"
  fi
}

revert_all_services() {
  for NAMESPACE in .redirected/*/; do
    NAMESPACE="${NAMESPACE%/}"
    NAMESPACE="${NAMESPACE#".redirected/"}"
    if [[ "$NAMESPACE" != "*" ]]; then
      for SERVICE in .redirected/"$NAMESPACE"/*/; do
        SERVICE="${SERVICE%/}"
        SERVICE="${SERVICE#".redirected/$NAMESPACE/"}"
        if [[ "$SERVICE" != "*" ]]; then
          revert_service "$NAMESPACE" "$SERVICE"
        fi
      done
    fi
  done
}

setup_tunnel() {
  NAMESPACE="$1"
  shift
  # convert list of ports to ssh tunnel parameters
  PORTS=()
  CMD=()
  while [[ "$#" -ne 0 ]]; do
    # Rebuild list of ports
    PORTS+=("$1")
    # port forwarding for ports remote -> local
    CMD+=("${CMD[@]}" "-R" "$1:localhost:$1")
    shift
  done

  # start ssh session
  nohup ssh -o ConnectTimeout=2 -o ConnectionAttempts=1 -o ServerAliveInterval=1 -o ServerAliveCountMax=2 -i "$DIR/.redirected/.identity" ${CMD[@]} -p 32233 -N root@become-proxy."$NAMESPACE".svc.cluster.local >/dev/null 2>&1 &
  echo "$!" >".redirected/$NAMESPACE/ssh-pid.txt"
  echo "${PORTS[@]}" >".redirected/$NAMESPACE/ssh-ports.txt"
}

teardown_tunnel() {
  if [[ -f ".redirected/$1/ssh-pid.txt" ]]; then
    sudo -p "[local sudo] Password:" kill $(cat ".redirected/$1/ssh-pid.txt") || true
    rm ".redirected/$1/ssh-pid.txt"
  fi
  if [[ -f ".redirected/$1/ssh-ports.txt" ]]; then
    rm ".redirected/$1/ssh-ports.txt" 2>/dev/null || true
  fi
}

verify_tunnels() {
  # read the list of ports
  PORTS=()
  for SERVICE_PORTS in .redirected/"$1"/*/ports.txt; do
    if [[ -f "$SERVICE_PORTS" ]]; then
      PORTS+=($(cat "$SERVICE_PORTS"))
    fi
  done

  echo -n "  $1: "
  if [[ "" == "${PORTS[@]}" ]]; then # teardown tunnel
    if [[ -f ".redirected/$1/ssh-pid.txt" ]] && kill -0 $(cat ".redirected/$1/ssh-pid.txt") 2>/dev/null; then # if exists
      echo -n "Tearing down... "
      teardown_tunnel "$1"
    fi
    rm -r ".redirected/$1/"
    echo "OK"
  else # setup tunnel
    # if the proxy pod doesn't exist
    if ! kubectl get deployment --namespace="$1" "become-proxy" >/dev/null 2>&1; then
      # create it, and wait for it to start
      echo -n "(Creating proxy pod... "
      kubectl apply --namespace="$1" -f "$DIR/become-proxy.yml" >/dev/null
      until kubectl rollout status --namespace="$1" deployment/become-proxy >/dev/null; do
        sleep 1
      done
      echo -n "OK) "
    fi

    if [[ -f ".redirected/$1/ssh-pid.txt" ]] && kill -0 "$(cat ".redirected/$1/ssh-pid.txt")" 2>/dev/null; then # if exists
      if [[ -f ".redirected/$1/ssh-ports.txt" && "$(cat ".redirected/$1/ssh-ports.txt")" == "${PORTS[@]}" ]]; then # if unchanged
        echo "Exists"
      else # if changed
        echo -n "Restarting... "
        teardown_tunnel "$1"
        setup_tunnel "$1" ${PORTS[@]}
        echo "OK"
      fi
    else # if tunnel not exist
      echo -n "Setting up... "
      setup_tunnel "$1" ${PORTS[@]}
      echo "OK"
    fi
  fi
}

if [[ "$1" == "--help" || "$1" == "-h" || "$1" == "help" ]]; then
  print_usage
  exit 0
fi

# ask for sudo here, so we have it later
sudo -p "[local sudo] Password:" echo >/dev/null

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR"

# add to existing forward folder structure
COMMAND="redirect"
NAMESPACE="$(kubectl config view -o jsonpath='{.contexts[0].context.namespace}')"
if [[ "$NAMESPACE" == "" ]]; then
  NAMESPACE="default"
fi
while [[ "$#" -ne 0 ]]; do
  if [[ "$1" == "--revert" ]]; then
    COMMAND="revert"
  elif [[ "$1" == "--redirect" ]]; then
    COMMAND="redirect"
  elif [[ "$1" == "--revert-all" ]]; then
    revert_all_services
  elif [[ "$1" == "--namespace" ]]; then
    NAMESPACE="$2"
    shift
  elif [[ "$1" == "--namespace="* ]]; then
    NAMESPACE="${1#"--namespace="}"
  elif [[ "$1" == "-n" ]]; then
    NAMESPACE="$2"
    shift
  elif [[ "$1" == "-n="* ]]; then
    NAMESPACE="${1#"-n="}"
  elif [[ "$1" == "-"* ]]; then
    echo "Unknown tag '$1'"
    print_usage
    exit 1
  else
    SERVICE="$1"
    if [[ "$COMMAND" == "redirect" ]]; then
      redirect_service "$NAMESPACE" "$SERVICE"
    elif [[ "$COMMAND" == "revert" ]]; then
      revert_service "$NAMESPACE" "$SERVICE"
    fi
  fi
  shift
done

mkdir -p .redirected/

# create identity file with known private key
# TODO: this is very insecure
cat >.redirected/.identity <<EOF
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
chmod 600 .redirected/.identity

# create ssh tunnels for each service
echo "Verifying tunnels..."
for NAMESPACE in .redirected/*/; do
  NAMESPACE="${NAMESPACE%/}"
  NAMESPACE="${NAMESPACE#".redirected/"}"
  if [[ "$NAMESPACE" != "*" ]]; then
    verify_tunnels "$NAMESPACE"
  fi
done

sleep 1
rm -f .redirected/.identity

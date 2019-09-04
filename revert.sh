#!/bin/bash

set -eo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR"

# remove from the existing forward folder structure
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
  elif [[ "$1" == "--all" ]]; then
    REVERT_ALL=true
  else
    SERVICE="$1"
    mkdir -p ".redirected/$NAMESPACE/$SERVICE"

    # if this information was recorded
    if [[ -f .redirected/"$NAMESPACE/$SERVICE"/original-selector.txt ]]; then
      # revert it
      ORIGINAL_SELECTOR="$(cat ".redirected/$NAMESPACE/$SERVICE/original-selector.txt")"
      echo -n "Reverting $SERVICE: ($ORIGINAL_SELECTOR)... "
      kubectl patch --namespace="$NAMESPACE" svc "$SERVICE" --type=json --patch='[{"op": "replace", "path": "/spec/selector", "value":{'"$ORIGINAL_SELECTOR}}]" >/dev/null
      rm ".redirected/$NAMESPACE/$SERVICE/original-selector.txt"
      rm ".redirected/$NAMESPACE/$SERVICE/ports.txt"
      rm -r ".redirected/$NAMESPACE/$SERVICE"
      if [[ -z "$(ls -A ".redirected/$NAMESPACE")" ]]; then
        rm -r ".redirected/$NAMESPACE"
      fi
      echo "OK"
    else
      echo "The service $SERVICE doesn't exist in the $NAMESPACE namespace"
    fi
  fi
  shift
done


if [[ "$REVERT_ALL" == true ]]; then
  cd .redirected/
  for NAMESPACE in */; do
    NAMESPACE="${NAMESPACE%/}"
    if [[ "$NAMESPACE" != "*" ]]; then
      cd "$NAMESPACE"

      for SERVICE in */; do
        SERVICE="${SERVICE%/}"
        if [[ "$SERVICE" != "*" ]]; then
          cd "$SERVICE"

          # if this information was recorded
          if [[ -f "original-selector.txt" ]]; then
            ORIGINAL_SELECTOR="$(cat original-selector.txt)"
            echo -n "Reverting $SERVICE: ($ORIGINAL_SELECTOR)... "
            kubectl patch --namespace="$NAMESPACE" svc "$SERVICE" --type=json --patch='[{"op": "replace", "path": "/spec/selector", "value":{'"$ORIGINAL_SELECTOR}}]" >/dev/null
            rm "original-selector.txt"
            rm "ports.txt"
            echo "OK"
          fi

          cd ..
          rm -r "$SERVICE"
        fi
      done

      if [[ -f ssh-pid.txt ]]; then
        echo -n "Tearing down tunnel into $NAMESPACE... "
        sudo kill -9 $(cat ssh-pid.txt)
        # TODO: auto-restart with remaining port-forwards
        rm ssh-pid.txt ssh-ports.txt 2>/dev/null || true
        echo "OK"
      fi

      cd ..
      rm -r "$NAMESPACE"
    fi
  done
  cd ..
fi

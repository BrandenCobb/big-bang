#!/usr/bin/env bash

# exit on error
set -e

# Get original CoreDNS config
kubectl get configmap -n kube-system coredns -o jsonpath='{.data.NodeHosts}' > newhosts

# Safeguard in case configmap doesn't end with newline
if [[ $(tail -c 1 newhosts) != "" ]]; then
  echo "" >> newhosts
fi

# Get each VS hostname + ingress gateway IP and add to newhosts
for vs in $(kubectl get virtualservice -A -o go-template='{{range .items}}{{.metadata.name}}{{":"}}{{.metadata.namespace}}{{" "}}{{end}}'); do
  vs_name=$(echo ${vs} | awk -F: '{print $1}')
  vs_namespace=$(echo ${vs} | awk -F: '{print $2}')
  hosts=$(kubectl get virtualservice ${vs_name} -n ${vs_namespace} -o go-template='{{range .spec.hosts}}{{.}}{{" "}}{{end}}')
  gateway=$(kubectl get virtualservice ${vs_name} -n ${vs_namespace} -o jsonpath='{.spec.gateways[0]}' | awk -F/ '{print $2}')
  ingress_gateway=$(kubectl get gateway -n istio-system $gateway -o jsonpath='{.spec.selector.app}')
  external_ip=$(kubectl get svc -n istio-system $ingress_gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  for host in $hosts; do
    host=$(echo ${host} | xargs)
    # Remove previous entry if on upgrade job
    sed -i "/$host/d" newhosts
    echo "${external_ip} ${host}" >> newhosts
  done
done

# Patch CoreDNS and restart pod
hosts=$(cat newhosts) yq e -n '.data.NodeHosts = strenv(hosts)' > patch.yaml
kubectl patch configmap -n kube-system coredns --patch "$(cat patch.yaml)"
kubectl rollout restart deployment -n kube-system coredns
kubectl rollout status deployment -n kube-system coredns --timeout=30s

# Gather all HRs we should test
installed_helmreleases=$(helm list -n bigbang -o json | jq '.[].name' | tr -d '"' | grep -v "bigbang")

mkdir -p cypress-tests

ERRORS=0

# For each HR, if it has helm tests: run them, capture exit code, output logs, and save cypress artifacts
for hr in $installed_helmreleases; do
  test_result=$(helm test $hr -n bigbang) && export EXIT_CODE=$? || export EXIT_CODE=$?
  echo "$test_result"
  namespace=$(echo "$test_result" | yq eval '."NAMESPACE"' -)
  test_suite=$(echo "$test_result" | yq eval '.["TEST SUITE"]' -)
  if [ ! $test_suite == "None" ]; then
    echo "***** Helm Test Logs for Helmrelease ${hr} *****"
    for pod in $(echo "$test_result" | grep "TEST SUITE" | grep "cypress-test" | awk -F: '{print $2}' | xargs); do
      if kubectl get pod -n ${namespace} ${pod} &>/dev/null; then
        echo -e "---\nLogs for ${pod}:\n---"
        kubectl logs --tail=-1 -n ${namespace} ${pod}
      fi
    done
    for pod in $(echo "$test_result" | grep "TEST SUITE" | grep "script-test" | awk -F: '{print $2}' | xargs); do
      if kubectl get pod -n ${namespace} ${pod} &>/dev/null; then
        echo -e "---\nLogs for ${pod}:\n---"
        kubectl logs --tail=-1 -n ${namespace} ${pod}
      fi
    done
    echo "***** End Helm Test Logs for Helmrelease ${hr} *****"
    if kubectl get configmap -n ${namespace} cypress-screenshots &>/dev/null; then
      mkdir -p cypress-tests/${hr}/tests/cypress
      kubectl get configmap -n ${namespace} cypress-screenshots -o jsonpath='{.data.cypress-screenshots\.tar\.gz\.b64}' > cypress-screenshots.tar.gz.b64
      cat cypress-screenshots.tar.gz.b64 | base64 -d > cypress-screenshots.tar.gz
      tar -zxf cypress-screenshots.tar.gz --strip-components=2 -C cypress-tests/${hr}/tests/cypress
      rm -rf cypress-screenshots.tar.gz.b64 cypress-screenshots.tar.gz
    fi
    if kubectl get configmap -n ${namespace} cypress-videos &>/dev/null; then
      mkdir -p cypress-tests/${hr}/tests/cypress
      kubectl get configmap -n ${namespace} cypress-videos -o jsonpath='{.data.cypress-videos\.tar\.gz\.b64}' > cypress-videos.tar.gz.b64
      cat cypress-videos.tar.gz.b64 | base64 -d > cypress-videos.tar.gz
      tar -zxf cypress-videos.tar.gz --strip-components=2 -C cypress-tests/${hr}/tests/cypress
      rm -rf cypress-videos.tar.gz.b64 cypress-videos.tar.gz
    fi
    if [[ ${EXIT_CODE} -ne 0 ]]; then
      ERRORS=$((ERRORS + 1))
    fi
  fi
done

if [ $ERRORS -gt 0 ]; then
  echo "Encountered $ERRORS errors while running tests. See output logs above and artifacts in the job."
  exit 123
fi

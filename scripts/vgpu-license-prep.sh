#!/bin/zsh
# Licence ConfigMap, NGC pull secret and the PAISConfiguration switch to the NVAIE driver type. Private AI Services
# (PAIS) then runs the GPU Operator with the vGPU guest driver from nvcr.io/nvaie and nvidia-gridd licenses every GPU
# node against the Cloud License Service (CLS). API fields (PAIS Kubernetes API reference): nvidiaConfig.gpuDriverType
# NVAIE|OSS, licenseConfigRef (ConfigMap with client_configuration_token.tok and gridd.conf, required for NVAIE),
# imagePullSecretRef (Secret kubernetes.io/dockerconfigjson with the NGC key), gpuOperatorVersion, driver.version.
#   MODE=status (default): current nvidiaConfig, existing ConfigMap/Secret, conditions
#   MODE=apply:            create/refresh ConfigMap and Secret from the two files, patch nvidiaConfig, watch
#   MODE=oss:              back to the OSS driver type (passthrough), licenseConfigRef removed
# Variables:
#   SUPERVISOR_NS   the Supervisor namespace that runs PAIS
#   CLS_TOKEN_FILE  client configuration token from the licensing portal (allocation -> Create client config token)
#   NGC_KEY_FILE    one line, your personal NGC API key (NGC -> Setup -> API keys). Never printed, never in git.
#   DRIVER (default 580.105.8), OPERATOR (default 25.10.1): guest driver and GPU Operator versions PAIS should use;
#   check the PAIS 3.0 release notes for the versions your bundle ships.
# Run after `kubectl vsphere login`:
#   SUPERVISOR_NS=<ns> CLS_TOKEN_FILE=~/nvaie/client_configuration_token.tok NGC_KEY_FILE=~/nvaie/ngc_api_key \
#     MODE=apply zsh vgpu-license-prep.sh 2>&1 | tee /tmp/vgpu-license-prep.txt
set -u
MODE=${MODE:-status}; NS=${SUPERVISOR_NS:?set SUPERVISOR_NS}
DRIVER=${DRIVER:-580.105.8}; OPERATOR=${OPERATOR:-25.10.1}
CM=${LICENSE_CM:-nvaie-license}; SEC=${PULL_SECRET:-ngc-pull}
TOK=${CLS_TOKEN_FILE:-}; KEY=${NGC_KEY_FILE:-}
h() { print -r -- ""; print -r -- "### $*  ($(date +%T))"; }
kubectl config use-context $NS >/dev/null 2>&1
kubectl auth can-i patch paisconfigurations -n $NS >/dev/null 2>&1 || {
  print -r -- "Not logged in. First: kubectl vsphere login --server <supervisor> -u <user> --insecure-skip-tls-verify"; exit 1; }

status() {
  h "nvidiaConfig today"
  kubectl -n $NS get paisconfiguration default -o jsonpath='{.spec.nvidiaConfig}'; print
  h "licence ConfigMap and pull secret in $NS"
  kubectl -n $NS get configmap $CM -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",{}); print("  configmap keys:", {k: len(v) for k,v in d.items()})' || print -r -- "  configmap $CM: missing"
  kubectl -n $NS get secret $SEC -o jsonpath='{.type}{"\n"}' 2>/dev/null || print -r -- "  secret $SEC: missing"
  h "conditions"
  kubectl -n $NS get paisconfiguration default -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}' | cut -c1-200
  h "VM classes in $NS (vGPU classes must be here before the endpoint)"
  kubectl -n $NS get virtualmachineclass -o custom-columns='NAME:.metadata.name,CPU:.spec.hardware.cpus,MEM:.spec.hardware.memory' --no-headers 2>/dev/null | sed 's/^/  /'
}

watch_operator() {
  KC=/tmp/pais-vks.kubeconfig
  VKS=$(kubectl -n $NS get secret -o name | grep -E "^secret/$NS-[0-9]+-kubeconfig$" | head -1)
  [[ -n $VKS ]] && kubectl -n $NS get $VKS -o jsonpath='{.data.value}' | base64 -d > $KC
  for i in {1..30}; do
    sleep 20
    print -r -- "--- $(date +%T)"
    kubectl -n $NS get paisconfiguration default -o jsonpath='{range .status.conditions[?(@.type=="GPUOperatorReady")]}{.type}={.status} {.reason} {.message}{"\n"}{end}' | cut -c1-200
    if [[ -s $KC ]]; then
      kubectl --kubeconfig $KC -n gpu-operator get pods --no-headers 2>/dev/null | awk '{print "  gpu-operator:", $1, $2, $3}' | head -15
      kubectl --kubeconfig $KC -n gpu-operator get clusterpolicy -o jsonpath='{range .items[*]}{"  clusterpolicy: "}{.metadata.name}{" state="}{.status.state}{" repo="}{.spec.driver.repository}{" image="}{.spec.driver.image}{" version="}{.spec.driver.version}{" licensing="}{.spec.driver.licensingConfig}{"\n"}{end}' 2>/dev/null
      kubectl --kubeconfig $KC get pods -A --no-headers 2>/dev/null | grep -i -E 'ImagePull|ErrImage|CrashLoop' | awk '{print "  PROBLEM:", $1, $2, $4}'
    fi
    G=$(kubectl -n $NS get paisconfiguration default -o jsonpath='{range .status.conditions[?(@.type=="GPUOperatorReady")]}{.status}{end}')
    [[ $G == True ]] && { print -r -- "GPUOperatorReady=True"; break; }
  done
  print -r -- "Note: the driver daemonset (and the licence) only shows up on a GPU node, i.e. after the first vGPU ModelEndpoint."
  print -r -- "Note: the ClusterPolicy may still show nvcr.io/nvidia for a while after the patch; re-check before the endpoint."
}

case $MODE in
  status) status ;;
  apply)
    status
    [[ -n $TOK && -s $TOK ]] || { print -r -- "set CLS_TOKEN_FILE to the client configuration token (download it from the allocation in the licensing portal)"; exit 1; }
    [[ -n $KEY && -s $KEY ]] || { print -r -- "set NGC_KEY_FILE to a one-line file with your NGC API key (NGC -> Setup -> API keys)"; exit 1; }
    h "1. ConfigMap $CM (client configuration token + empty gridd.conf)"
    : > /tmp/gridd.conf
    kubectl -n $NS create configmap $CM --from-file=client_configuration_token.tok=$TOK --from-file=gridd.conf=/tmp/gridd.conf --dry-run=client -o yaml | kubectl apply -f - || exit 1
    h "2. Secret $SEC (dockerconfigjson for nvcr.io, user \$oauthtoken)"
    kubectl -n $NS create secret docker-registry $SEC --docker-server=nvcr.io --docker-username='$oauthtoken' --docker-password="$(tr -d '[:space:]' < $KEY)" --dry-run=client -o yaml | kubectl apply -f - || exit 1
    kubectl -n $NS get secret $SEC -o jsonpath='{.type}{"\n"}'
    h "3. patch nvidiaConfig: NVAIE, driver $DRIVER, operator $OPERATOR, licence $CM, pull secret $SEC"
    kubectl -n $NS patch paisconfiguration default --type merge -p "{\"spec\":{\"nvidiaConfig\":{\"gpuDriverType\":\"NVAIE\",\"gpuOperatorVersion\":\"$OPERATOR\",\"driver\":{\"version\":\"$DRIVER\"},\"licenseConfigRef\":{\"name\":\"$CM\"},\"imagePullSecretRef\":{\"name\":\"$SEC\"}}}}" || exit 1
    kubectl -n $NS get paisconfiguration default -o jsonpath='{.spec.nvidiaConfig}'; print
    h "4. watch (up to 10 min)"
    watch_operator
    ;;
  oss)
    h "back to OSS (passthrough): licenseConfigRef and imagePullSecretRef removed"
    kubectl -n $NS patch paisconfiguration default --type json -p "[{\"op\":\"replace\",\"path\":\"/spec/nvidiaConfig\",\"value\":{\"gpuDriverType\":\"OSS\",\"gpuOperatorVersion\":\"$OPERATOR\",\"driver\":{\"version\":\"$DRIVER\"}}}]" || exit 1
    watch_operator
    ;;
  *) print -r -- "MODE must be status, apply or oss"; exit 1 ;;
esac

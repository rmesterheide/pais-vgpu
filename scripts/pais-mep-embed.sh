#!/bin/zsh
# Embeddings Model Endpoint on a small vGPU slice: bge-m3 from your registry on the Infinity engine (no engine override).
#   MODE=apply (default) | status | delete
# Variables: SUPERVISOR_NS, REGISTRY (host:port/project), STORAGE_CLASS, EPNAME (default bge-m3-vgpu4c),
#   VMCLASS (default a5000-vgpu-4c), OCI (default $REGISTRY/baai/bge-m3:v1).
# Run after `kubectl vsphere login`:
#   SUPERVISOR_NS=<ns> REGISTRY=<host:port/project> STORAGE_CLASS=<sc> zsh pais-mep-embed.sh 2>&1 | tee /tmp/pais-mep-embed.txt
# Test (PAIS_TOKEN holds an API token of the gateway):
#   curl -sk -H "Authorization: Bearer $PAIS_TOKEN" -H 'Content-Type: application/json' \
#     -d '{"model":"bge-m3-vgpu4c","input":["one GPU, many tenants"]}' https://<pais-fqdn>/api/v1/compatibility/openai/v1/embeddings | head -c 300
set -u
MODE=${MODE:-apply}; NS=${SUPERVISOR_NS:?set SUPERVISOR_NS}; SC=${STORAGE_CLASS:?set STORAGE_CLASS}; REG=${REGISTRY:?set REGISTRY=<host:port/project>}
NAME=${EPNAME:-bge-m3-vgpu4c}; VMCLASS=${VMCLASS:-a5000-vgpu-4c}; OCI=${OCI:-$REG/baai/bge-m3:v1}
h() { print -r -- ""; print -r -- "### $*  ($(date +%T))"; }
kubectl config use-context $NS >/dev/null 2>&1
kubectl auth can-i create modelendpoints -n $NS >/dev/null 2>&1 || { print -r -- "Not logged in. First: kubectl vsphere login --server <supervisor> -u <user> --insecure-skip-tls-verify"; exit 1; }
PULL=$(kubectl -n $NS get secret -o name | grep -E "^secret/$NS-$NS-reg-creds-" | head -1 | cut -d/ -f2)
[[ -n $PULL ]] || { print -r -- "registry pull secret $NS-$NS-reg-creds-* not found"; exit 1; }

if [[ $MODE == delete ]]; then
  h "delete ModelEndpoint $NAME"; kubectl -n $NS delete modelendpoint $NAME; kubectl -n $NS get modelendpoint,vm 2>&1; exit 0
fi
if [[ $MODE == apply ]]; then
  kubectl -n $NS get virtualmachineclass $VMCLASS >/dev/null 2>&1 || kubectl -n $NS get virtualmachineclassbinding $VMCLASS >/dev/null 2>&1 || { print -r -- "VM class $VMCLASS not in namespace $NS"; exit 1; }
  Y=/tmp/mep-$NAME.yaml
  cat > $Y <<YAML
apiVersion: pais.vmware.com/v1alpha1
kind: ModelEndpoint
metadata:
  name: $NAME
  namespace: $NS
  annotations:
    pais.vmware.com/displayName: $NAME
    ui.pais.vmware.com/model-info-secret: $PULL
spec:
  type: Embeddings
  engine: Infinity
  model:
    ociRef: $OCI
    pullSecrets:
      - name: $PULL
  routingName: $NAME
  replicas: 1
  virtualMachineClassName: $VMCLASS
  storageClassName: $SC
YAML
  h "1. manifest"; cat $Y
  h "2. apply"; kubectl apply -f $Y || exit 1
fi
h "3. watch (up to 25 min)"
START=$(date +%s)
for i in {1..50}; do
  R=$(kubectl -n $NS get modelendpoint $NAME -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status} {.reason} {.message}{end}' 2>/dev/null | cut -c1-220)
  print -r -- "--- $(date +%T) after $(( ($(date +%s)-START)/60 )) min: Ready=$R"
  kubectl -n $NS get vm -o custom-columns='VM:.metadata.name,CLASS:.spec.className,POWER:.status.powerState' --no-headers 2>/dev/null | grep -E "$NAME|CLASS" | sed 's/^/  /'
  [[ $R == True* ]] && break
  sleep 30
done
kubectl -n $NS get modelendpoint
print -r -- "Done. Test with the curl in the header of this script."

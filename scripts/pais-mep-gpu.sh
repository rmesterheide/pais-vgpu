#!/bin/zsh
# Chat Model Endpoint on a vGPU slice (or a passthrough card): llama.cpp CUDA engine inside Private AI Services (PAIS),
# GGUF from your own OCI registry (Harbor, pushed with `vcf pais models push`).
#  0. preflight: login, PAISConfiguration Ready, VM class present in the namespace, registry pull secret
#  1. write the ModelEndpoint manifest to /tmp and show it
#  2. apply it (PAIS creates a VKS worker from the VM class, pulls the engine image and the model, starts llama-server)
#  3. watch up to 30 minutes: ModelEndpoint conditions, VMs in the namespace, pods inside the VKS cluster
#  4. test through the gateway: /models, one short and one longer chat completion, four parallel requests
# Variables:
#   SUPERVISOR_NS   Supervisor namespace that runs PAIS
#   REGISTRY        registry host[:port]/project, e.g. harbor.example.com:443/models
#   STORAGE_CLASS   storage class name available in the namespace
#   PAIS_GW         gateway base, https://<pais-fqdn>/api/v1/compatibility/openai/v1
#   VMCLASS         VM class with the vGPU profile (lab: a5000-vgpu-12c = 8 vCPU, 32 GiB reserved, nvidia_rtxa5000-12c)
#   MODEL           gemma (default, google/gemma-4-12b-qat-gguf:v1, 7.2 GB), gemma-text (tag v1-text, GGUF without the
#                   vision projector), qwen (qwen/qwen3.8-27b-gguf:v1, 16.5 GB, needs the whole card); or set OCI yourself
#   EPNAME          endpoint and route name (default from MODEL), CTX context size (16384 fits a 12 GB slice with Gemma;
#                   4096 to 8192 on an 8 GB slice), IMG engine image (default ghcr.io/ggml-org/llama.cpp:server-cuda-b11913,
#                   the bundled image is CPU only, so a CUDA image is mandatory)
#   MODE            apply (default) | status (steps 3 and 4 only) | delete (remove the endpoint and its worker node)
# Run after `kubectl vsphere login`:
#   SUPERVISOR_NS=<ns> REGISTRY=<host:port/project> STORAGE_CLASS=<sc> PAIS_GW=https://<pais>/api/v1/compatibility/openai/v1 \
#     VMCLASS=a5000-vgpu-12c MODEL=gemma EPNAME=gemma-4-12b-vgpu12c zsh pais-mep-gpu.sh 2>&1 | tee /tmp/pais-mep-gpu.txt
set -u
NS=${SUPERVISOR_NS:?set SUPERVISOR_NS}
REG=${REGISTRY:?set REGISTRY=<host:port/project>}
SC=${STORAGE_CLASS:?set STORAGE_CLASS}
GW=${PAIS_GW:?set PAIS_GW=https://<pais-fqdn>/api/v1/compatibility/openai/v1}
MODEL=${MODEL:-gemma}
VMCLASS=${VMCLASS:-a5000-vgpu-12c}
MODE=${MODE:-apply}
h() { print -r -- ""; print -r -- "### $*"; }

case $MODEL in
  qwen)       NAME=qwen3.8-27b-gpu;    OCI=${OCI:-$REG/qwen/qwen3.8-27b-gguf:v1} ;;
  gemma)      NAME=gemma-4-12b-gpu;    OCI=${OCI:-$REG/google/gemma-4-12b-qat-gguf:v1} ;;
  gemma-text) NAME=gemma-4-12b-text;   OCI=${OCI:-$REG/google/gemma-4-12b-qat-gguf:v1-text} ;;   # GGUF only, no mmproj: ~0.8 GB less VRAM
  *) print -r -- "unknown MODEL=$MODEL (qwen, gemma, gemma-text)"; exit 1 ;;
esac
NAME=${EPNAME:-$NAME}; CTX=${CTX:-16384}
IMG=${IMG:-ghcr.io/ggml-org/llama.cpp:server-cuda-b11913}
ROUTE=$NAME

kubectl config use-context $NS >/dev/null 2>&1
kubectl auth can-i create modelendpoints -n $NS >/dev/null 2>&1 || {
  print -r -- "Not logged in. First: kubectl vsphere login --server <supervisor> -u <user> --insecure-skip-tls-verify"; exit 1; }

if [[ $MODE == delete ]]; then
  h "delete ModelEndpoint $NAME (the worker VM goes with it)"
  kubectl -n $NS delete modelendpoint $NAME
  kubectl -n $NS get modelendpoint,vm 2>&1
  exit 0
fi

h "0. GPU prerequisites: nvidiaConfig on the PAISConfiguration"
kubectl -n $NS get paisconfiguration default -o jsonpath='{.spec.nvidiaConfig}'; print
[[ -n "$(kubectl -n $NS get paisconfiguration default -o jsonpath='{.spec.nvidiaConfig.gpuDriverType}')" ]] || { print -r -- "nvidiaConfig missing: run MODE=apply zsh vgpu-license-prep.sh first"; exit 1; }

h "0a. PAISConfiguration conditions"
kubectl -n $NS get paisconfiguration default -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}'
READY=$(kubectl -n $NS get paisconfiguration default -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')
[[ $READY == True ]] || print -r -- "WARNING: PAISConfiguration Ready=$READY (ModelEndpointPrerequisitesMet above decides whether an endpoint can start)"

h "0b. VM classes in namespace $NS"
kubectl -n $NS get virtualmachineclass -o custom-columns='NAME:.metadata.name,CPU:.spec.hardware.cpus,MEM:.spec.hardware.memory' 2>/dev/null \
  || kubectl -n $NS get virtualmachineclassbinding 2>/dev/null
if ! kubectl -n $NS get virtualmachineclass $VMCLASS >/dev/null 2>&1 && ! kubectl -n $NS get virtualmachineclassbinding $VMCLASS >/dev/null 2>&1; then
  print -r -- "VM class $VMCLASS is not available in namespace $NS."
  print -r -- "Add it in vCenter on the namespace (VM Service card, Manage VM Classes), or run with VMCLASS=<one of the names above>."
  exit 1
fi

h "0c. registry pull secret (PAIS creates it from the Supervisor registry entry)"
PULL=$(kubectl -n $NS get secret -o name | grep "^secret/$NS-$NS-reg-creds-" | head -1 | cut -d/ -f2)
[[ -n $PULL ]] || { print -r -- "no $NS-$NS-reg-creds-* secret found"; exit 1; }
print -r -- "secret: $PULL"
kubectl -n $NS get secret $PULL -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | python3 -c 'import json,sys; print("registries:", list(json.load(sys.stdin)["auths"].keys()))'

if [[ $MODE == apply ]]; then
  h "1. manifest"
  Y=/tmp/mep-$NAME.yaml
  {
    cat <<YAML
apiVersion: pais.vmware.com/v1alpha1
kind: ModelEndpoint
metadata:
  name: $NAME
  namespace: $NS
  annotations:
    pais.vmware.com/displayName: $NAME
    ui.pais.vmware.com/model-info-secret: $PULL
spec:
  type: Completions
  engine: LlamaCPP
  model:
    ociRef: $OCI
    pullSecrets:
      - name: $PULL
  routingName: $ROUTE
  replicas: 1
  virtualMachineClassName: $VMCLASS
  storageClassName: $SC
  inferenceServerCustomization:
    engineImage: $IMG
    cliArgs:
      - '--n-gpu-layers'
      - '99'
      - '--ctx-size'
      - '$CTX'
      - '--flash-attn'
      - 'on'
      - '--reasoning-budget'
      - '0'
      - '--jinja'
      - '--metrics'
YAML
  } > $Y
  cat $Y

  h "2. apply"
  kubectl apply -f $Y || exit 1
fi

h "3. watch (up to 30 minutes)"
KC=/tmp/pais-vks.kubeconfig
VKS=$(kubectl -n $NS get secret -o name | grep -E "^secret/$NS-[0-9]+-kubeconfig$" | head -1)
[[ -n $VKS ]] && kubectl -n $NS get $VKS -o jsonpath='{.data.value}' | base64 -d > $KC
START=$(date +%s)
for i in {1..60}; do
  sleep 30
  print -r -- "--- $(date +%T) after $(( ($(date +%s)-START)/60 )) min"
  kubectl -n $NS get modelendpoint $NAME -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}' 2>&1 | cut -c1-300
  kubectl -n $NS get vm -o custom-columns='VM:.metadata.name,POWER:.status.powerState,CLASS:.spec.className' 2>/dev/null
  if [[ -s $KC ]]; then
    kubectl --kubeconfig $KC get pods -A --no-headers 2>/dev/null | grep -v -E '^(kube-system|vmware-system|tkg-system|secretgen-controller|kapp-controller|pinniped|cert-manager)' | awk '{print "  vks:", $1, $2, $3, $4}' | head -12
    kubectl --kubeconfig $KC get nodes --no-headers 2>/dev/null | awk '{print "  node:", $1, $2}'
    kubectl --kubeconfig $KC get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu' --no-headers 2>/dev/null | awk '$2!="<none>"{print "  gpu allocatable:", $1, $2}'
    kubectl --kubeconfig $KC -n gpu-operator get pods --no-headers 2>/dev/null | grep -v -E ' Running | Completed ' | awk '{print "  gpu-operator:", $1, $3}'
  fi
  R=$(kubectl -n $NS get modelendpoint $NAME -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)
  [[ $R == True ]] && { print -r -- "ModelEndpoint $NAME is Ready after $(( ($(date +%s)-START)/60 )) min"; break; }
done
kubectl -n $NS get modelendpoint
if [[ -s $KC ]]; then
  h "3a. GPU driver daemonset log tail (driver load, licence)"
  DP=$(kubectl --kubeconfig $KC -n gpu-operator get pods --no-headers 2>/dev/null | grep -E 'nvidia-driver-daemonset|nvidia-vgpu' | awk '{print $1}' | head -1)
  [[ -n $DP ]] && kubectl --kubeconfig $KC -n gpu-operator logs $DP --tail=15 2>&1 | cut -c1-200
  h "3b. engine pod log tail (CUDA device, offloaded layers, pull errors show up here)"
  POD=$(kubectl --kubeconfig $KC get pods -A --no-headers 2>/dev/null | grep -i -E "$NAME|modelendpoint|llama" | head -1)
  [[ -n $POD ]] && kubectl --kubeconfig $KC -n ${POD%% *} describe pod $(print -r -- $POD | awk '{print $2}') | grep -A 12 '^Events:' | cut -c1-220
  [[ -n $POD ]] && kubectl --kubeconfig $KC -n ${POD%% *} logs $(print -r -- $POD | awk '{print $2}') --all-containers --tail=25 2>&1 | cut -c1-220
fi

h "4. test through the gateway"
T=${PAIS_TOKEN:-}
[[ -n $T ]] || { read -rs 'T?PAIS API token (Enter to skip): '; print; }
T=${T//[[:space:]]/}
[[ -n $T ]] || { print -r -- "skipped"; exit 0; }
curl -sk -H "Authorization: Bearer $T" "$GW/models" | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(" ", m.get("id"), m.get("status") or m.get("availability") or "") for m in d.get("data", [])]'
for n in 40 250; do
  print -r -- "--- chat/completions model=$ROUTE max_tokens=$n"
  T0=$(date +%s.%N)
  curl -sk -o /tmp/mep-answer.json -w 'http=%{http_code} ttfb=%{time_starttransfer}s total=%{time_total}s\n' \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' "$GW/chat/completions" \
    -d "{\"model\":\"$ROUTE\",\"max_tokens\":$n,\"messages\":[{\"role\":\"user\",\"content\":\"Explain in plain words what a Kubernetes namespace is.\"}]}"
  python3 - "$T0" <<'PY'
import json, sys, time
t0 = float(sys.argv[1]); raw = open("/tmp/mep-answer.json").read()
try: d = json.loads(raw)
except ValueError: print("body:", raw[:300]); raise SystemExit
if "choices" not in d: print("body:", raw[:400]); raise SystemExit
u = d.get("usage") or {}; dt = time.time() - t0
print("usage:", u, "| about %.1f tok/s end to end" % (u.get("completion_tokens", 0) / dt if dt else 0))
print("text:", d["choices"][0]["message"]["content"].strip()[:300].replace("\n", " "))
PY
done
h "5. four parallel requests (aggregate throughput, max_tokens 200 each)"
T0=$(date +%s.%N)
for k in 1 2 3 4; do
  curl -sk -o /tmp/mep-par-$k.json -H "Authorization: Bearer $T" -H 'Content-Type: application/json' "$GW/chat/completions" \
    -d "{\"model\":\"$ROUTE\",\"max_tokens\":200,\"messages\":[{\"role\":\"user\",\"content\":\"Write $k short sentences about the sea.\"}]}" &
done
wait
python3 - "$T0" <<'PY2'
import json, sys, time, glob
t0=float(sys.argv[1]); dt=time.time()-t0; tot=0
for f in sorted(glob.glob("/tmp/mep-par-*.json")):
    try: tot += (json.load(open(f)).get("usage") or {}).get("completion_tokens",0)
    except Exception: print("bad body in", f)
print("4 parallel: %d completion tokens in %.1f s = %.1f tok/s aggregate" % (tot, dt, tot/dt if dt else 0))
PY2
print -r -- ""
print -r -- "Done. Remove the endpoint with: MODE=delete EPNAME=$NAME zsh pais-mep-gpu.sh"

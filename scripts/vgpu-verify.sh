#!/bin/zsh
# Prove that an endpoint runs on a vGPU slice and that the slice is licensed.
#  1. GPU nodes and their allocatable GPUs; driver pod on each GPU node
#  2. nvidia-smi inside the driver pod: product name (e.g. RTX A5000-12C), driver version, memory (the slice ceiling)
#  3. licence: nvidia-smi -q "vGPU Software Licensed Product" block (Licensed (Expiry ...) or Unlicensed)
#  4. nvidia-gridd log lines from the driver pod (License acquired / renewal / failures)
#  5. ModelEndpoint conditions (PAIS prints driver mismatches here)
# Variables: SUPERVISOR_NS. Run after `kubectl vsphere login`:
#   SUPERVISOR_NS=<ns> zsh vgpu-verify.sh 2>&1 | tee /tmp/vgpu-verify.txt
set -u
NS=${SUPERVISOR_NS:?set SUPERVISOR_NS}
h() { print -r -- ""; print -r -- "### $*  ($(date +%T))"; }
kubectl config use-context $NS >/dev/null 2>&1
KC=/tmp/pais-vks.kubeconfig
VKS=$(kubectl -n $NS get secret -o name | grep -E "^secret/$NS-[0-9]+-kubeconfig$" | head -1)
[[ -n $VKS ]] || { print -r -- "Not logged in or no VKS kubeconfig secret in $NS"; exit 1; }
kubectl -n $NS get $VKS -o jsonpath='{.data.value}' | base64 -d > $KC
k() { kubectl --kubeconfig $KC "$@"; }

h "1. nodes with GPUs"
k get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product,DRIVER:.metadata.labels.nvidia\.com/cuda\.driver\.major,MEM_MB:.metadata.labels.nvidia\.com/gpu\.memory' --no-headers 2>/dev/null
h "VMs and classes in $NS"
kubectl -n $NS get vm -o custom-columns='VM:.metadata.name,CLASS:.spec.className,POWER:.status.powerState' --no-headers 2>/dev/null | sed 's/^/  /'

for DP in $(k -n gpu-operator get pods --no-headers 2>/dev/null | grep -E 'nvidia-gpu-driver|nvidia-driver-daemonset|nvidia-vgpu' | awk '{print $1}'); do
  CT=$(k -n gpu-operator get pod $DP -o jsonpath='{.spec.containers[0].name}')
  NODE=$(k -n gpu-operator get pod $DP -o jsonpath='{.spec.nodeName}')
  h "2. driver pod $DP on $NODE: nvidia-smi"
  k -n gpu-operator exec $DP -c $CT -- nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,utilization.gpu --format=csv 2>&1
  k -n gpu-operator exec $DP -c $CT -- nvidia-smi 2>&1 | sed -n '1,12p'
  h "3. licence on $NODE"
  k -n gpu-operator exec $DP -c $CT -- sh -c 'nvidia-smi -q | grep -A4 "vGPU Software Licensed Product"' 2>&1
  k -n gpu-operator exec $DP -c $CT -- sh -c 'ls -la /etc/nvidia/ClientConfigToken/ 2>/dev/null; cat /etc/nvidia/gridd.conf 2>/dev/null | grep -v "^#" | grep . ' 2>&1 | sed 's/^/  /'
  h "4. nvidia-gridd lines in the driver log ($DP)"
  k -n gpu-operator logs $DP -c $CT 2>&1 | grep -i -E 'gridd|licen' | tail -15 | cut -c1-200
  k -n gpu-operator exec $DP -c $CT -- sh -c 'grep -i -h -E "licen" /var/log/syslog /var/log/messages 2>/dev/null | tail -10' 2>&1 | cut -c1-200
done

h "5. ModelEndpoints and their conditions (driver mismatch messages land here)"
kubectl -n $NS get modelendpoint 2>&1
for M in $(kubectl -n $NS get modelendpoint -o name 2>/dev/null); do
  print -r -- "--- $M"
  kubectl -n $NS get $M -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}' | cut -c1-300
done
h "6. GPU Operator pods (all)"
k -n gpu-operator get pods -o wide --no-headers 2>/dev/null | awk '{print "  ", $1, $2, $3, $7}'

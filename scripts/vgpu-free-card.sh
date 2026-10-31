#!/bin/zsh
# Optional, only if a VKS cluster holds the card in passthrough (as in github.com/rmesterheide/vks-gpu-sharing):
# take the GPU away from that cluster so the host can switch the card from passthrough to vGPU. The cluster keeps
# its control plane; only the worker pool goes to 0.
#   MODE=status (default): worker replicas, machines, VMs in the namespace
#   MODE=free:             set the worker pool to 0 replicas and wait until its VM is gone (up to 10 min)
#   MODE=back:             worker pool back to 1 (only useful once the card is in passthrough again)
# Variables: SUPERVISOR_NS (namespace), CLUSTER (VKS cluster name), GPU_CLASS_PREFIX (VM class name prefix of the
# passthrough class, used to see when the card is free). Run after `kubectl vsphere login`:
#   SUPERVISOR_NS=<ns> CLUSTER=gpu-dra MODE=free zsh vgpu-free-card.sh 2>&1 | tee /tmp/vgpu-free-card.txt
set -u
MODE=${MODE:-status}; NS=${SUPERVISOR_NS:?set SUPERVISOR_NS}; CL=${CLUSTER:-gpu-dra}; PFX=${GPU_CLASS_PREFIX:-a5000-}
h() { print -r -- ""; print -r -- "### $*  ($(date +%T))"; }
kubectl config use-context $NS >/dev/null 2>&1 || { print -r -- "Not logged in. First: kubectl vsphere login --server <supervisor> -u <user> --insecure-skip-tls-verify"; exit 1; }

status() {
  h "cluster $CL: worker pools"
  kubectl -n $NS get cluster $CL -o jsonpath='{range .spec.topology.workers.machineDeployments[*]}{.name}{" class="}{.class}{" replicas="}{.replicas}{"\n"}{end}' 2>&1
  kubectl -n $NS get machines -l cluster.x-k8s.io/cluster-name=$CL -o custom-columns='MACHINE:.metadata.name,PHASE:.status.phase,NODE:.status.nodeRef.name' --no-headers 2>/dev/null | sed 's/^/  /'
  h "VMs in namespace $NS (the card is free when no VM with class $PFX* is listed)"
  kubectl -n $NS get vm -o custom-columns='VM:.metadata.name,CLASS:.spec.className,POWER:.status.powerState' --no-headers 2>/dev/null | sed 's/^/  /'
  h "ModelEndpoints (none expected)"
  kubectl -n $NS get modelendpoint 2>&1 | sed 's/^/  /'
}

case $MODE in
  status) status ;;
  free|back)
    R=0; [[ $MODE == back ]] && R=1
    status
    h "set worker pool replicas to $R"
    kubectl -n $NS patch cluster $CL --type json -p "[{\"op\":\"replace\",\"path\":\"/spec/topology/workers/machineDeployments/0/replicas\",\"value\":$R}]" || exit 1
    if [[ $MODE == free ]]; then
      for i in {1..60}; do
        N=$(kubectl -n $NS get vm -o custom-columns='C:.spec.className' --no-headers 2>/dev/null | grep -c "$PFX")
        print -r -- "  $(date +%T) GPU VMs left: $N"
        [[ $N -eq 0 ]] && break
        sleep 10
      done
    fi
    status
    print -r -- ""
    print -r -- "Next: on the host, vgpu-host.sh with MODE=check, then MODE=install (host reboot)."
    ;;
  *) print -r -- "MODE must be status, free or back"; exit 1 ;;
esac

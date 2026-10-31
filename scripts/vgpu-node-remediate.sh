#!/bin/zsh
# Check 3 from the blog post: a VKS worker that boots more than 15 minutes after its Machine was created has an expired
# kubeadm bootstrap token and never joins (kubelet silent, Machine stuck at "Waiting for a Node with spec.providerID").
# The VKS webhook refuses a plain `delete machine`; the MachineHealthCheck path is annotate, then delete. The
# MachineDeployment replaces the Machine within a minute and the new node joins in about five.
#   SUPERVISOR_NS=<ns> MACHINE=<machine name> zsh vgpu-node-remediate.sh
set -u
NS=${SUPERVISOR_NS:?set SUPERVISOR_NS}; M=${MACHINE:?set MACHINE (kubectl -n $NS get machines)}
kubectl -n $NS get machine $M -o custom-columns='MACHINE:.metadata.name,PHASE:.status.phase,NODE:.status.nodeRef.name,AGE:.metadata.creationTimestamp'
kubectl -n $NS annotate machine $M cluster.x-k8s.io/remediate-machine="" --overwrite
kubectl -n $NS delete machine $M
kubectl -n $NS get machines

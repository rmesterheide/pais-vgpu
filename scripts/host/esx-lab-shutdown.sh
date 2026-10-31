# Orderly shutdown of a single-host Supervisor lab. Runs ON the ESX host (busybox sh):
#   ssh <esx-host> 'sh /vmfs/volumes/<datastore>/nvaie/esx-lab-shutdown.sh'
# Order: vCenter first (its WCP service powers the Supervisor control plane back on while it runs), then the Supervisor
# control plane (it powers VKS VMs and pods back on while it runs), then VKS VMs, pod VMs, FLB, registry/DNS VM,
# maintenance mode, host. VM ids change over time: the script resolves them by name pattern.
# ACTION=poweroff (default) or ACTION=reboot (for a BIOS visit, e.g. to enable SR-IOV).
ACTION=${ACTION:-poweroff}
VC_VM=${VC_VM:-'vc*'}; SCP_VM=${SCP_VM:-'SupervisorControlPlaneVM*'}; VKS_VM=${VKS_VM:-'*-[0-9a-z]*-[0-9a-z]*-*'}
POD_VM=${POD_VM:-'*-controller-manager-*'}; FLB_VM=${FLB_VM:-'flb-*'}; VIS_VM=${VIS_VM:-'vis*'}
log() { echo "$(date +%T) $*"; }
state() { vim-cmd vmsvc/power.getstate $1 | tail -1; }
name() { vim-cmd vmsvc/get.summary $1 | grep -m1 "name =" | sed 's/.*= "//; s/",//'; }
ids() { vim-cmd vmsvc/getallvms | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
byname() { for id in $(ids); do case "$(name $id)" in $1) echo $id;; esac; done; }
waitoff() { n=0; while [ "$(state $1)" != "Powered off" ] && [ $n -lt $2 ]; do sleep 5; n=$((n+5)); done; log "  $(name $1): $(state $1) after ${n}s"; }
guest() { for id in $(byname "$1"); do [ "$(state $id)" = "Powered on" ] || continue; log "guest shutdown $(name $id)"; vim-cmd vmsvc/power.shutdown $id >/dev/null 2>&1; waitoff $id $2
  [ "$(state $id)" = "Powered on" ] && { log "  hard power off $(name $id)"; vim-cmd vmsvc/power.off $id >/dev/null 2>&1; waitoff $id 30; }; done; }
hard() { for id in $(byname "$1"); do [ "$(state $id)" = "Powered on" ] || continue; vim-cmd vmsvc/power.off $id >/dev/null 2>&1; log "  power off $(name $id) -> $(state $id)"; done; }
log "1. vCenter";                      guest "$VC_VM" 420
log "2. Supervisor control plane";     guest "$SCP_VM" 300
log "3. VKS cluster VMs";              guest "$VKS_VM" 240
log "4. pod VMs";                      hard "$POD_VM"
log "5. Foundation Load Balancer";     guest "$FLB_VM" 180
log "6. registry / DNS VM";            guest "$VIS_VM" 180
for id in $(ids); do [ "$(state $id)" = "Powered on" ] && { log "  STILL ON: $(name $id), powering off"; vim-cmd vmsvc/power.off $id >/dev/null 2>&1; }; done
log "7. maintenance mode"; esxcli system maintenanceMode set --enable true --timeout 180; esxcli system maintenanceMode get
if [ "$(esxcli system maintenanceMode get)" = "Enabled" ]; then log "8. host $ACTION"; esxcli system shutdown $ACTION --reason "lab $ACTION $(date +%F)"; log "$ACTION issued"
else log "NOT in maintenance mode, host left running"; fi

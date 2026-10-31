# Start a single-host Supervisor lab after a host boot. Runs ON the ESX host (busybox sh):
#   ssh <esx-host> 'sh /vmfs/volumes/<datastore>/nvaie/esx-lab-startup.sh'
# Order: exit maintenance mode, registry/DNS VM, vCenter, then the Supervisor control plane and the Foundation Load
# Balancer. Once vCenter's WCP service is up it powers on the Supervisor control plane itself if we have not; the
# Supervisor then powers on the VKS VMs and recreates the pod VMs. No autostart is configured on purpose.
# VM name patterns (override as environment variables): VC_VM, SCP_VM, VKS_VM, FLB_VM, VIS_VM.
VC_VM=${VC_VM:-'vc*'}; SCP_VM=${SCP_VM:-'SupervisorControlPlaneVM*'}; VKS_VM=${VKS_VM:-'*-[0-9a-z]*-[0-9a-z]*-*'}
FLB_VM=${FLB_VM:-'flb-*'}; VIS_VM=${VIS_VM:-'vis*'}
log() { echo "$(date +%T) $*"; }
state() { vim-cmd vmsvc/power.getstate $1 | tail -1; }
name() { vim-cmd vmsvc/get.summary $1 | grep -m1 "name =" | sed 's/.*= "//; s/",//'; }
ids() { vim-cmd vmsvc/getallvms | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}'; }
byname() { for id in $(ids); do case "$(name $id)" in $1) echo $id;; esac; done; }
on() { for id in $(byname "$1"); do [ "$(state $id)" = "Powered on" ] && { log "  already on: $(name $id)"; continue; }; vim-cmd vmsvc/power.on $id >/dev/null 2>&1; log "  power on $(name $id) -> $(state $id)"; done; }
log "GPU devices:"; lspci | grep -i -E "nvidia|3d controller|vga" ; esxcli hardware pci list | grep -i -A12 nvidia | grep -E "Vendor Name|Device Name|Vendor ID|Device ID|SubVendor ID|SubDevice ID|Module ID|Passthru" | head -8
log "0. exit maintenance mode"; esxcli system maintenanceMode set --enable false; esxcli system maintenanceMode get
log "1. registry / DNS VM"; on "$VIS_VM"
log "2. vCenter"; on "$VC_VM"
log "   waiting 120 s for vCenter services"; sleep 120
log "3. Supervisor control plane and FLB"; on "$SCP_VM"; on "$FLB_VM"
log "4. VKS VMs (the Supervisor would do this too)"; on "$VKS_VM"
log "inventory:"; for id in $(ids); do log "  $id | $(state $id) | $(name $id)"; done
log "done. vCenter UI needs about 1 more minute, Supervisor API 2 to 3 min, PAIS ingress about 5 min."

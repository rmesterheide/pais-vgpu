# Host side of the NVIDIA AI Enterprise (NVAIE) vGPU install on a single ESX host. Runs ON the host (busybox sh).
# Copy it to a datastore folder, not /tmp (ESX wipes /tmp on every reboot):
#   scp vgpu-host.sh <esx-host>:/vmfs/volumes/<datastore>/nvaie/
#   ssh <esx-host> 'GPU=0000:XX:00.0 PKGDIR=/vmfs/volumes/<datastore>/nvaie MODE=check sh /vmfs/volumes/<datastore>/nvaie/vgpu-host.sh'
# Required variables:
#   GPU      PCI address of the card (esxcli hardware pci list | grep -i nvidia), e.g. 0000:c1:00.0
#   PKGDIR   datastore folder with the two NVAIE host zips (host driver bundle and gpu-mgmt-daemon)
# Optional: AUDIO (the card's audio function, default GPU with .1; gone once the card is in display-off mode),
#   VC_VM, SCP_VM, VKS_VM, POD_VM, FLB_VM, VIS_VM (VM name patterns for the orderly shutdown, see the defaults below).
# Modes:
#   check   : VIB list, module, daemon, nvidia-smi, graphics device list, passthrough state, vGPU profiles (read-only)
#   install : orderly VM shutdown (same order as esx-lab-shutdown.sh), maintenance mode, passthrough OFF for the card,
#             install both components from $PKGDIR (host driver first, daemon second), REBOOT the host.
#             NVIDIA's guide asks for a reboot between switching passthrough off and the VIB install; add one if you
#             want to be exact. Everything on the host is down from here until esx-lab-startup.sh ran.
#   shared  : set the GPU to Shared Direct (SharedPassthru) and vGPU mode Mixed Size, refresh, show the result.
#             Run after the reboot and before any vGPU VM powers on. Needs no VM shutdown.
#   sched   : show the scheduler; SCHED=equal|best|fixed sets RmPVMRL (0x01 / default / 0x11), takes effect after a reboot
#   watch   : nvidia-smi vgpu view every 5 s for WATCH seconds (default 60), for the host-side picture during a benchmark
#   passthru: back to passthrough (type Basic, passthrough on for both functions); reboot afterwards
# Package files of NVAIE 7.8 (download from the NVIDIA Licensing Portal, not included here):
#   Host_Drivers/NVD-AIE-900_580.178.05-1OEM.900.0.24580437.zip and Host_Drivers/nvd-gpu-mgmt-daemon_580.65.05-0.0.0000.zip
# The script picks *.zip files in $PKGDIR whose name contains nvd/NVD and installs the daemon second.
# Before MODE=install: the card must be in display-off ("compute") mode (see README, check 1) and SR-IOV must be on
# in the BIOS (check 2). Otherwise the driver PSODs on install or the first vGPU VM fails to power on.
MODE=${MODE:-check}
PKGDIR=${PKGDIR:?set PKGDIR=/vmfs/volumes/<datastore>/nvaie}
GPU=${GPU:?set GPU=<pci address of the card, e.g. 0000:c1:00.0>}; AUDIO=${AUDIO:-${GPU%.0}.1}
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

check() {
  log "ESX: $(vmware -v)"
  log "NVIDIA VIBs:"; esxcli software vib list | grep -i -E "nvd|nvidia" | sed 's/^/   /' || log "   none"
  log "module: $(vmkload_mod -l | grep -i nvidia | awk '{printf "%s ", $1}')"
  [ -x /etc/init.d/nvdGpuMgmtDaemon ] && log "daemon: $(/etc/init.d/nvdGpuMgmtDaemon status 2>&1 | head -1)" || log "daemon: not installed"
  log "passthrough:"; esxcli hardware pci pcipassthru list | grep -E "$GPU|$AUDIO" | sed 's/^/   /'
  log "graphics devices:"; esxcli graphics device list 2>/dev/null | sed 's/^/   /'
  log "nvidia-smi:"; nvidia-smi 2>&1 | head -20 | sed 's/^/   /'
  log "vGPU profiles (nvidia-smi vgpu -s):"; nvidia-smi vgpu -s 2>&1 | head -40 | sed 's/^/   /'
  log "scheduler module parameter:"; esxcli system module parameters list -m nvidia 2>/dev/null | grep -i RegistryDwords | sed 's/^/   /'
  log "SR-IOV at boot (empty is good):"; grep -i "Enable VFs failed" /var/log/vmkwarning.log 2>/dev/null | tail -2 | sed 's/^/   /'
  log "package folder $PKGDIR:"; ls -la $PKGDIR 2>/dev/null | sed 's/^/   /' || log "   missing"
}

case "$MODE" in
  check) check ;;
  install)
    ZIPS=$(ls $PKGDIR/*.zip 2>/dev/null | grep -i nvd)
    [ -n "$ZIPS" ] || { log "no NVD*.zip in $PKGDIR, copy the two component zips first"; exit 1; }
    log "will install:"; for z in $ZIPS; do log "   $z"; done
    log "1. vCenter";                      guest "$VC_VM" 420
    log "2. Supervisor control plane";     guest "$SCP_VM" 300
    log "3. VKS cluster VMs";              guest "$VKS_VM" 240
    log "4. pod VMs";                      hard "$POD_VM"
    log "5. Foundation Load Balancer";     guest "$FLB_VM" 180
    log "6. registry / DNS VM";            guest "$VIS_VM" 180
    for id in $(ids); do [ "$(state $id)" = "Powered on" ] && { log "  STILL ON: $(name $id), powering off"; vim-cmd vmsvc/power.off $id >/dev/null 2>&1; }; done
    log "7. maintenance mode"; esxcli system maintenanceMode set --enable true --timeout 180; esxcli system maintenanceMode get
    [ "$(esxcli system maintenanceMode get)" = "Enabled" ] || { log "NOT in maintenance mode, stopping before the install"; exit 1; }
    log "8. passthrough off for $GPU and $AUDIO"
    for d in $GPU $AUDIO; do esxcli hardware pci pcipassthru set --device-id="$d" --enable=false --apply-now 2>&1 | sed 's/^/   /'; done
    esxcli hardware pci pcipassthru list | grep -E "$GPU|$AUDIO" | sed 's/^/   /'
    log "9. install components (host driver first, daemon second; absolute paths)"
    for z in $(echo "$ZIPS" | grep -v -i daemon) $(echo "$ZIPS" | grep -i daemon); do
      log "   esxcli software vib install -d $z"
      esxcli software vib install -d "$z" 2>&1 | sed 's/^/      /'
    done
    log "VIBs now:"; esxcli software vib list | grep -i -E "nvd|nvidia" | sed 's/^/   /'
    log "10. reboot (maintenance mode stays on; esx-lab-startup.sh exits it and starts the VMs)"
    esxcli system shutdown reboot --reason "NVAIE vGPU manager install $(date +%F)"
    log "reboot issued"
    ;;
  shared)
    log "graphics type Shared Direct + vGPU mode Mixed Size for $GPU"
    esxcli graphics device set --device-id=$GPU --type=SharedPassthru --vgpu-mode=MixedSize 2>&1 | sed 's/^/   /'
    esxcli graphics host refresh 2>&1 | sed 's/^/   /'
    sleep 3
    esxcli graphics device list 2>/dev/null | sed 's/^/   /'
    log "profiles:"; nvidia-smi vgpu -s 2>&1 | head -40 | sed 's/^/   /'
    log "vGPU creatable now (nvidia-smi vgpu -c):"; nvidia-smi vgpu -c 2>&1 | head -40 | sed 's/^/   /'
    ;;
  sched)
    log "current:"; esxcli system module parameters list -m nvidia 2>/dev/null | grep -i RegistryDwords | sed 's/^/   /'
    dmesg 2>/dev/null | grep NVRM | grep -i scheduler | tail -3 | sed 's/^/   /'
    case "${SCHED:-}" in
      equal) esxcli system module parameters set -m nvidia -p "NVreg_RegistryDwords=RmPVMRL=0x01"; log "set equal share (0x01), reboot to apply" ;;
      fixed) esxcli system module parameters set -m nvidia -p "NVreg_RegistryDwords=RmPVMRL=0x11"; log "set fixed share (0x11), reboot to apply" ;;
      best)  esxcli system module parameters set -m nvidia -p "NVreg_RegistryDwords="; log "back to best effort (default), reboot to apply" ;;
      "")    log "SCHED not set, nothing changed (SCHED=equal|fixed|best)" ;;
    esac
    ;;
  watch)
    W=${WATCH:-60}; n=0
    while [ $n -lt $W ]; do
      echo "--- $(date +%T)"
      nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw,temperature.gpu --format=csv,noheader 2>&1
      nvidia-smi vgpu 2>&1 | grep -E "RTX|NVIDIA [A-Z]" | sed "s/ \{2,\}/ /g"
      sleep 5; n=$((n+5))
    done
    ;;
  passthru)
    log "back to passthrough: graphics type Basic, passthrough on for both functions (reboot afterwards)"
    esxcli graphics device set --device-id=$GPU --type=Basic 2>&1 | sed 's/^/   /'; esxcli graphics host refresh
    for d in $GPU $AUDIO; do esxcli hardware pci pcipassthru set --device-id="$d" --enable=true --apply-now 2>&1 | sed 's/^/   /'; done
    esxcli hardware pci pcipassthru list | grep -E "$GPU|$AUDIO" | sed 's/^/   /'
    ;;
  *) log "MODE must be check, install, shared, sched, watch or passthru"; exit 1 ;;
esac

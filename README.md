# pais-vgpu

Scripts, manifests and results to reproduce NVIDIA vGPU on a single vSphere 9.1 host with Private AI Services (PAIS) 3.0: one RTX A5000 split into slices, each slice in its own vSphere Kubernetes Service (VKS) worker, one PAIS Model Endpoint per slice. The lab ran two 12 GB chat tenants, then a 12 GB chat tenant next to an 8 GB chat tenant and a 4 GB embedding tenant.

This is the companion to the blog post "Route to Private AI Services 3.0, part 4: one card, three tenants, one evening to vGPU" on raimes.ai. The scripts are the ones used in the lab run of 2026-10-31. They are lab scripts, not a product. Read them before you run them. The predecessor, GPU sharing with Dynamic Resource Allocation (DRA) on the same card without vGPU, is at https://github.com/rmesterheide/vks-gpu-sharing; its numbers are the comparison row below.

## What you need

- An NVIDIA AI Enterprise (NVAIE) entitlement. The lab ran on a 90-day evaluation. In the NVIDIA Licensing Portal: a licence server of type Cloud License Service (CLS), an allocation with enough `NVAIE_Licensing` seats (one per vGPU VM), deployed to CLS, and a **client configuration token** downloaded from that allocation. Keep the token file out of git.
- A personal **NGC API key** (NGC → Setup → API keys). PAIS pulls the vGPU guest driver from `nvcr.io/nvaie` with it.
- The **NVAIE 7.8 software package for vSphere 9.0** from the portal's Downloads page (7.8 is the R580 long-term branch that matches the guest driver PAIS 3.0 ships; VCF 9.1 is validated for it). From the zip you need two files: `Host_Drivers/NVD-AIE-900_580.178.05-1OEM.900.0.24580437.zip` (vGPU Manager) and `Host_Drivers/nvd-gpu-mgmt-daemon_580.65.05-0.0.0000.zip`. The packages are not in this repo.
- vSphere 9.1 with a Supervisor, PAIS 3.0 activated on a namespace, a VKS workload cluster that PAIS manages, and a model in an OCI registry (`vcf pais models push`, the lab used Harbor). Part 3 of the series covers that state.
- **Check 1, the card's mode.** Workstation cards such as the RTX A5000, A5500, A6000 and the RTX 5000/6000 Ada ship in display-enabled mode and run vGPU only in display-off mode (footnote in NVIDIA's vSphere support matrix). Request NVIDIA's Display Mode Selector (developer.nvidia.com, approved at once) and switch the mode once. It does not run on ESX; `manifests/dms-live.vmx.example` describes the throw-away Linux VM used for it. Skipping this step gives a purple screen (`rm_init_adapter` in world `nvidia-smi`) during the VIB post-install.
- **Check 2, the BIOS.** Ampere cards run vGPU on vSphere in SR-IOV mode. Enable SR-IOV Support and PCIe ARI (up to 24 virtual functions need function numbers above 7); Above 4G Decoding must be on. Passthrough never needed any of this, so a host that ran passthrough fine can still fail here. The symptom is `PCI: Enable VFs failed for device @<pci address>` in `vmkwarning.log` at boot and a vGPU VM that does not power on (`Could not initialize plugin libnvidia-vgx.so`).
- **Check 3, the clock.** Create the first ModelEndpoint only when the host shows the profiles (`nvidia-smi vgpu -c`). A VKS worker that boots more than 15 minutes after its Machine was created has an expired bootstrap token and never joins; `scripts/vgpu-node-remediate.sh` is the fix.
- `kubectl` with the vSphere plugin, `zsh`, `python3` on the machine you run the scripts from; SSH to the ESX host with a key.

## Lab setup

- One EPYC host, ESX 9.1.1 build 25782009, vCenter 9.1.1, Supervisor with the Foundation Load Balancer, no VMware Cloud Foundation (VCF) Automation. Read it as a lab route.
- Card: RTX A5000 24 GB (refurbished), display-off mode, SR-IOV with 24 virtual functions, ECC on. Graphics type Shared Direct, vGPU mode Mixed Size (so 12C, 8C and 4C can coexist).
- VM classes created in vCenter under Workload Management → Services → VM Service → VM Classes, PCI device of access type "NVIDIA GRID vGPU", profile names `nvidia_rtxa5000-12c` / `-8c` / `-4c` (C = compute), memory fully reserved (a vGPU VM does not power on otherwise), assigned to the PAIS namespace: `a5000-vgpu-12c` (8 vCPU, 32 GB), `a5000-vgpu-8c` (6, 24), `a5000-vgpu-4c` (4, 16).
- PAIS `nvidiaConfig`: `gpuDriverType: NVAIE`, licence ConfigMap, NGC pull secret (`manifests/nvidiaconfig-nvaie.yaml`). PAIS then runs the GPU Operator with the vGPU guest driver and `nvidia-gridd` licenses each node against the CLS.

## The version chain

| Layer | Version | Where it comes from |
|---|---|---|
| ESX | 9.1.1 build 25782009 | Broadcom support portal |
| vGPU Manager on ESX | 580.178.05 (VIB `NVD-AIE_ESXi_9.0.0_Driver`) | NVAIE 7.8 host package |
| GPU Management Daemon | 580.65.05 (VIB `nvdgpumgmtdaemon`) | NVAIE 7.8 host package |
| Display Mode Selector | 1.77 | developer.nvidia.com, one-time use |
| Card mode | display-off ("compute", mode 4), SR-IOV host vGPU mode | set once with the tool, BIOS |
| VKS control plane | Kubernetes 1.34.x (PAIS-managed cluster) | PAIS 3.0 bundle |
| GPU Operator in the guest cluster | 25.10.1 | PAIS `nvidiaConfig.gpuOperatorVersion` |
| Guest driver | 580.105.08 (`nvidia-vgpu-driver-ubuntu24.04`) | `nvcr.io/nvaie`, pulled with the NGC key |
| Licence | NVIDIA Virtual Compute Server, CLS (NLS 4.0), 24 h lease | client configuration token in the ConfigMap |
| Engine | llama.cpp `ghcr.io/ggml-org/llama.cpp:server-cuda-b11913` (chat), Infinity (embeddings, bundled) | ModelEndpoint `engineImage` |
| Models | Gemma 4 12B QAT Q4 GGUF (7.2 GB), BAAI bge-m3 | your registry |

Host driver 580.178.05 and guest driver 580.105.08 are both R580 and ran together without complaint. The GPU Operator's ClusterPolicy may still show `nvcr.io/nvidia` for a while after the `nvidiaConfig` patch; re-check before the first endpoint.

## Run order

Variables used by the scripts (export them once):

- `ESX_HOST`, `GPU` (PCI address of the card), `PKGDIR` (a datastore folder on the host for the two zips and the host scripts; `/tmp` is wiped on every reboot).
- `SUPERVISOR_NS` (the namespace that runs PAIS), `STORAGE_CLASS`, `REGISTRY` (`host:port/project`), `PAIS_GW` (`https://<pais-fqdn>/api/v1/compatibility/openai/v1`), `PAIS_TOKEN` or `PAIS_TOKEN_FILE` (a gateway API token).
- `CLS_TOKEN_FILE` (client configuration token), `NGC_KEY_FILE` (one line, NGC API key). Neither file belongs in git; `.gitignore` covers the usual names.
- Log in with `kubectl vsphere login --server <supervisor> -u <user> --insecure-skip-tls-verify` before the Supervisor-side scripts.

Order of the evening (times are what the lab needed once the three checks were done):

0. Card mode (check 1) and BIOS (check 2) first, if the card ran passthrough before. Both need a host reboot anyway.
1. If a VKS cluster holds the card in passthrough (as in the DRA repo), free it: `MODE=free zsh scripts/vgpu-free-card.sh`.
2. Copy the two zips and the host scripts to `$PKGDIR` on the host, then read-only check:
   `ssh $ESX_HOST "GPU=$GPU PKGDIR=$PKGDIR MODE=check sh $PKGDIR/vgpu-host.sh"`
3. Install (orderly VM shutdown, maintenance mode, passthrough off, both VIBs, reboot; 10 minutes):
   `ssh $ESX_HOST "GPU=$GPU PKGDIR=$PKGDIR MODE=install sh $PKGDIR/vgpu-host.sh"`
4. After the boot, Shared Direct and Mixed Size, then start the lab VMs:
   `ssh $ESX_HOST "GPU=$GPU PKGDIR=$PKGDIR MODE=shared sh $PKGDIR/vgpu-host.sh"` and `ssh $ESX_HOST "sh $PKGDIR/esx-lab-startup.sh"`.
   `nvidia-smi vgpu -c` must list the profiles now. Grep `vmkwarning.log` for `Enable VFs`: nothing is good.
5. VM classes in vCenter (see Lab setup), assigned to the namespace. 5 minutes.
6. Licence ConfigMap, pull secret, `nvidiaConfig` to NVAIE (`GPUOperatorReady=True` within seconds; the VKS control plane may roll once, then PAIS `Ready` takes 10 to 15 minutes):
   `MODE=apply zsh scripts/vgpu-license-prep.sh`
7. First endpoint on a 12C slice (worker VM, node join, driver pull, licence, model load; 9 minutes to Ready on a fresh node):
   `VMCLASS=a5000-vgpu-12c MODEL=gemma EPNAME=gemma-4-12b-vgpu12c zsh scripts/pais-mep-gpu.sh`
   If the node does not join within ten minutes, check 3: `MACHINE=<name> zsh scripts/vgpu-node-remediate.sh`.
8. Prove slice and licence: `zsh scripts/vgpu-verify.sh` (product `RTX A5000-12C`, `vGPU Software Licensed Product ... Licensed`, `nvidia-gridd` "License acquired").
9. Second tenant: the same command with `EPNAME=gemma-4-12b-vgpu12c-b`. Mixed sizes: delete it, then `VMCLASS=a5000-vgpu-8c MODEL=gemma-text CTX=4096 EPNAME=gemma-4-12b-vgpu8c zsh scripts/pais-mep-gpu.sh` and `zsh scripts/pais-mep-embed.sh`.
10. Measure: `PAR=4 python3 scripts/gw-bench.py gemma-4-12b-vgpu12c`, both tenants at once by starting two of them, embeddings with `python3 scripts/emb-bench.py bge-m3-vgpu4c`, all three with `zsh scripts/mixed-bench.sh`. The host view runs with `MODE=watch`.

## Scripts

- `scripts/host/vgpu-host.sh`: on the ESX host. `check`, `install`, `shared`, `sched` (RmPVMRL equal/fixed/best effort), `watch`, `passthru` (back to passthrough).
- `scripts/host/esx-lab-startup.sh`, `scripts/host/esx-lab-shutdown.sh`: start and stop a single-host Supervisor lab in the right order (vCenter's WCP service and the Supervisor power VMs back on while they run, so the order matters). `ACTION=reboot` for a BIOS visit. VM name patterns are variables.
- `scripts/vgpu-free-card.sh`: optional, scales a passthrough VKS worker pool to 0 so the card is free.
- `scripts/vgpu-license-prep.sh`: licence ConfigMap, NGC pull secret, `nvidiaConfig` NVAIE; `MODE=oss` reverts.
- `scripts/pais-mep-gpu.sh`: chat ModelEndpoint on a vGPU class (or passthrough), watch loop, gateway test.
- `scripts/pais-mep-embed.sh`: embeddings ModelEndpoint on the small slice.
- `scripts/vgpu-verify.sh`: nodes, `nvidia-smi` and licence state inside the driver pod, `nvidia-gridd` log, endpoint conditions.
- `scripts/vgpu-node-remediate.sh`: annotate-and-delete for a Machine whose bootstrap token expired.
- `scripts/gw-bench.py`, `scripts/emb-bench.py`, `scripts/mixed-bench.sh`: load through the PAIS gateway, single and parallel, three tenants at once.

## Manifests

- `modelendpoint-chat-vgpu12c.yaml`: the chat endpoint as the script writes it (llama.cpp CUDA image, `--n-gpu-layers 99`, 16k context).
- `modelendpoint-embeddings-vgpu4c.yaml`: the embeddings endpoint (Infinity, no override).
- `nvidiaconfig-nvaie.yaml`: the `nvidiaConfig` patch.
- `dms-live.vmx.example`: the settings of the throw-away VM for the Display Mode Selector (EFI, Secure Boot off, memory reserved, 64-bit MMIO, PCIe root ports 4 to 7, two ISOs, GRUB `modprobe.blacklist=nouveau`).

## Results

Measured 2026-10-31, Gemma 4 12B QAT on llama.cpp through the PAIS gateway, 400 tokens per answer. Full tables and reading in `results/2026-10-31-vgpu-a5000.md`.

| Setup | 1 request tok/s | 4 parallel aggregate | 8 parallel aggregate |
|---|---|---|---|
| Passthrough, whole card (2026-10-27) | 70.9 | 242.7 | 350.8 |
| One 12C slice alone | 68.9 | 228.1 | 387.7 |
| Two 12C slices, both busy (sum) | 29.0 + 30.4 | 109.1 + 104.1 = 213.2 | 88.7 + 88.5 = 177.2 |
| DRA time-slicing, two containers, both busy (2026-10-30) | 29.8 + 29.8 | 96.0 + 96.0 = 192.0 | |
| 12C chat next to a 4C embedding tenant under load | 69.0 | 220.0 | |

One slice alone is the whole card. Two busy slices split it evenly and lose a lot at 8 + 8 (time-slice thrash, reproducible to the decimal). A 4C embedding tenant (bge-m3, 491 texts/s alone, 506 next to the chat tenant) costs the chat tenant about 3 %. Gemma 4 12B Q4 does not fit an 8C slice; 8 GB is for models up to about 5 GB of weights.

## Scope and limits

- One host, one card, three slice sizes; best-effort scheduler only (equal and fixed share are the next run).
- ECC on, so each slice loses a little framebuffer on the host side.
- Licence behaviour with an unreachable CLS not measured.
- No MIG (the A5000 does not support it), no vMotion test.

## License

Apache 2.0. See `LICENSE`.

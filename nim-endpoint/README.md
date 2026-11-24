# nim-endpoint: an NVIDIA NIM as a catalog item in VCF Automation

A consumer orders "nim-endpoint" in the VCF Automation catalog, picks a model and a name, and then calls the model
through the gateway of Private AI Services (PAIS) under that name. Behind it, Argo CD rolls out one NIM on a shared
vSphere Kubernetes Service (VKS) cluster with the NVIDIA NIM Operator.

Lab: one host, one RTX A5000 (24 GB), VCF 9.1.1, PAIS 3.0. Names and addresses in the files are the lab's and are meant
as examples.

## Pieces

| File | What it is | Who applies it |
|---|---|---|
| `chart/` | Helm chart: `NIMCache`, `NIMService` and a LoadBalancer service with a fixed address | Argo CD, per order |
| `argocd-project.yaml` | Argo CD project: this repository, one cluster, one namespace | platform team, once |
| `blueprint-nim-endpoint.yaml` | VCF Automation blueprint: an Argo CD `Application` plus an `InferenceGatewayRoute` | platform team, once; consumers order it |
| `argocd-healthchecks.yaml` | Health checks for `NIMService` and `NIMCache`, as a patch for the Argo CD instance | platform team, once |

## Platform side, once

1. A VKS cluster with a GPU worker and the GPU Operator (in the lab: the "AI Kubernetes cluster" catalog item).
2. NIM Operator on that cluster: `helm upgrade --install nim-operator nvidia/k8s-nim-operator -n nim-operator`.
3. Namespace `nim` with two secrets that hold the NGC API key: `ngc-secret` (image pull) and `ngc-api-secret`
   (key `NGC_API_KEY`). They are created by hand and never stored in Git. The order form does not ask for the key.
4. An Argo CD instance with the cluster attached, `argocd-project.yaml` applied in the instance's namespace, and
   `argocd-healthchecks.yaml` merged into the `ArgoCD` object (`spec.resourceHealthChecks`).
5. The blueprint released to the catalog.

## What an order does

1. The blueprint creates the `Application` with three Helm parameters: `name`, `model`, `loadBalancerIP`.
2. Argo CD syncs the chart: the cache (kept across orders, so the weights are downloaded once), the NIM, the service.
3. The blueprint creates the gateway route `name` that points at the fixed address.
4. Deleting the order removes the route and, through the Argo CD finalizer, the NIM. The cache stays.

## Measured on the lab card (2026-11-24)

| NIM | 12 GB slice | 24 GB slice |
|---|---|---|
| Llama 3.1 Nemotron Nano 8B v1 (1.8.4) | out of memory | runs with the vLLM BF16 profile and 16k context: 20.4 GB, 34 tokens/s single, 133 tokens/s with four parallel requests |
| Nemotron Nano 9B v2 (1.12.2) | out of memory | does not start |
| Nemotron 3 Nano (2.1.7) | no runnable profile | no profile for this card (NVFP4 needs newer GPUs, FP8 needs 34 GB) |

Two things to know: a profile that the NIM lists as "runnable" can still fail at load, so the chart pins the profile per
model; and a 24 GB vGPU slice offers about 21.4 GiB to CUDA.

## Timing in the lab (2026-11-24)

| Order | Weights | Order finished | NIM answers |
|---|---|---|---|
| first order of a model | downloaded (16 GB) | see note | after about 6 minutes |
| next order of the same model | from the cache | after 162 s | after 141 s |
| delete | cache kept | 70 s until NIM, service and route are gone | |

Note: the first order ran before the health checks were in place and reported success after 49 s, long before the NIM was
ready. With `argocd-healthchecks.yaml` the application stays "Progressing" until the NIM is ready, and the order waits for it.

## Limits of this version

- One NIM at a time (one card, one fixed address).
- The health checks have to be added to each Argo CD instance that rolls out NIMs.

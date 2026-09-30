# Models-as-a-Service on OpenShift AI: Gemma 3 270M + Qwen3 0.6B

Kustomize manifests plus one bash script that enable **Models-as-a-Service (MaaS)** on
Red Hat OpenShift AI 3.4 / 3.5 and publish the two smallest models of each family:

| Model | Params | HF repo | Notes |
|---|---|---|---|
| `gemma-3-270m-it` | 270M | `google/gemma-3-270m-it` | Gated: needs `HF_TOKEN` of an account that accepted the Gemma license |
| `qwen3-0-6b` | 0.6B | `Qwen/Qwen3-0.6B` | Apache-2.0, not gated |

Both run on **vLLM CPU** by default (no GPU needed). `--accelerator gpu` switches them to vLLM CUDA.

The same manifests are used by both deployment paths:

* `./deploy.sh oc` applies them layer by layer with `oc`, waiting for readiness in between.
* `./deploy.sh argocd` creates the secrets, then lets Argo CD (OpenShift GitOps) sync them from git.

## Layout

```
operators/                 optional: Connectivity Link, LeaderWorkerSet, cert-manager subscriptions
platform/
  10-kuadrant/             Kuadrant instance (Authorino + Limitador)
  20-authorino-tls/        Authorino TLS listener + service-ca serving cert
  30-gateway/              GatewayClass, maas-default-gateway, passthrough Route
    cluster-params.env     cluster specific hostname + TLS secret (written by ./deploy.sh configure)
  40-postgres/             PoC PostgreSQL for MaaS API keys (skip with --postgres-url)
  50-rhoai/rhoai-3.4|3.5/  partial DSC + dashboard config that switch MaaS on
  overlays/rhoai-3.4|3.5/  everything above in one kustomization (what Argo CD syncs)
models/
  base/                    maas-models namespace, hf-model-puller ServiceAccount
  gemma-3-270m-it/         LLMInferenceService + MaaSModelRef
  qwen3-0-6b/              LLMInferenceService + MaaSModelRef
  components/gpu/          kustomize component: vLLM CUDA, 1 GPU, tolerations, shm
  overlays/cpu|gpu/
governance/                MaaSAuthPolicy + free (5k tok/min) and premium (100k tok/min) MaaSSubscriptions
argocd/                    Application templates + RBAC for the OpenShift GitOps controller
deploy.sh
```

## Prerequisites

* OpenShift 4.19.9+ with **OpenShift AI 3.4 or 3.5** installed and a `default-dsc` DataScienceCluster
* **Red Hat Connectivity Link** operator (or pass `--with-operators`)
* `oc` logged in as cluster-admin; `jq` and `curl` for `./deploy.sh test`
* For Argo CD: the **OpenShift GitOps** operator and this folder in a git repo Argo CD can read
* `export HF_TOKEN=hf_...` (Gemma is gated)

## Deploy with oc

```bash
export HF_TOKEN=hf_xxx
./deploy.sh oc                         # auto-detects 3.4 vs 3.5, CPU serving
./deploy.sh oc --accelerator gpu       # 1 NVIDIA GPU per model (Ampere or newer)
./deploy.sh test
```

## Deploy with Argo CD

```bash
export HF_TOKEN=hf_xxx
./deploy.sh configure                  # writes platform/30-gateway/cluster-params.env
git add -A && git commit -m "maas: cluster params" && git push
./deploy.sh argocd                     # secrets + RBAC + Applications, then waits for sync
./deploy.sh test
```

Options: `--repo-url`, `--revision` (default: `origin` remote and current branch),
`--rhoai-version`, `--accelerator`, `--with-operators`. Private repos need a repository
credential in Argo CD first. To create the Applications by hand, replace the `__...__`
placeholders in `argocd/applications.yaml`, but still run the bootstrap part of the script
(or create the secrets yourself), because secrets are deliberately not in git.

What the script does imperatively in both modes, and why:

| Step | Reason |
|---|---|
| `hf-token`, `postgres-creds`, `maas-db-config` secrets | never in git (use Sealed Secrets / ESO for production) |
| enable User Workload Monitoring | merges into an existing `cluster-monitoring-config` instead of overwriting it |
| `SSL_CERT_FILE` env on the Authorino deployment | object owned by the Authorino operator |
| 3.5 only: copy `maas-db-config` to `redhat-ai-gateway-infra` | namespace only exists after MaaS is enabled |
| label the maas-api namespace `maas.opendatahub.io/gateway-access=true` | same |

## Use it

```bash
HOST=maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
KEY=$(curl -sk -X POST https://$HOST/maas-api/v1/api-keys \
  -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' \
  -d '{"name":"my-key","subscription":"small-models-free","expiresIn":"24h"}' | jq -r .key)

curl -sk https://$HOST/v1/models -H "Authorization: Bearer $KEY" | jq '.data[].id'
```

Any OpenAI compatible client works with `base_url=https://$HOST/v1` and the API key.
Use the model `id` returned by `/v1/models`. Premium quota:
`oc adm groups add-users maas-premium-users <user>` and create keys with `"subscription":"small-models-premium"`.

## Design choices and caveats

* **Gateway exposure.** The gateway runs as a ClusterIP service behind a TLS passthrough
  Route on `maas.<apps-domain>`, serving the default ingress wildcard cert. This works on any
  platform without a LoadBalancer or DNS changes. For a cloud LoadBalancer instead, remove the
  `networking.istio.io/service-type` annotation and `route.yaml`.
* **Partial objects.** `DataScienceCluster`, `OdhDashboardConfig` and the Authorino objects are
  applied with server-side apply, so only the MaaS fields are owned. Argo CD will never prune or
  delete them (`Prune=false,Delete=false`).
* **3.4 vs 3.5.** 3.4 enables MaaS via `kserve.modelsAsService`, 3.5 via
  `aigateway.modelsAsAService` (the 3.4 field is frozen in 3.5).
* **Gemma token.** The HF token reaches the KServe storage-initializer through the
  `hf-model-puller` ServiceAccount. If your KServe build does not pick it up (init container
  fails with 401), mirror the model into an OCI modelcar image and use `uri: oci://...`.
* **Xet download hang.** If a storage-initializer is stuck in `Init:0/1`, the script sets
  `HF_HUB_DISABLE_XET=1` on it after 5 minutes. KServe can revert that on reconcile.
* **PostgreSQL** in `maas-db` is a single-replica PoC. Use `--postgres-url` for anything real.
* **Argo CD RBAC.** `argocd/rbac.yaml` grants the GitOps controller cluster-admin. Scope it down
  for production.
* **Swap models** by editing `spec.model.uri` (for example `hf://Qwen/Qwen2.5-0.5B-Instruct`)
  and the names in `governance/`.

## Clean up

```bash
./deploy.sh destroy                 # models, governance, gateway, PoC DB (or the Argo CD apps)
./deploy.sh destroy --disable-maas  # also switch MaaS off in the DSC
```

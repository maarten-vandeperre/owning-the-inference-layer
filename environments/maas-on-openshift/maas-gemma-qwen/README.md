# Models-as-a-Service on OpenShift AI: Gemma 3 270M + Qwen3 0.6B

Kustomize manifests plus one bash script that enable **Models-as-a-Service (MaaS)** on
Red Hat OpenShift AI 3.4 / 3.5 and publish the two smallest models of each family:

| Model | Params | HF repo | Notes |
|---|---|---|---|
| `gemma-3-270m-it` | 270M | `google/gemma-3-270m-it` | Gated: needs `HF_TOKEN` of an account that accepted the Gemma license |
| `qwen3-0-6b` | 0.6B | `Qwen/Qwen3-0.6B` | Apache-2.0, not gated |

Both run on **vLLM CPU** by default (no GPU needed). `--accelerator gpu` switches them to vLLM CUDA.

Also enabled: the **Gen AI studio playground** and **token consumption / telemetry dashboards**
(`--no-observability` skips the dashboards).

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
                           3.4 also pins the operator Subscription to stable-3.4
                           (playground is Llama Stack; 3.4 has no OGX component)
  overlays/rhoai-3.4|3.5/  everything above in one kustomization (what Argo CD syncs)
models/
  base/                    maas-models namespace, hf-model-puller ServiceAccount
  gemma-3-270m-it/         LLMInferenceService + MaaSModelRef
  qwen3-0-6b/              LLMInferenceService + MaaSModelRef
  components/gpu/          kustomize component: vLLM CUDA, 1 GPU, tolerations, shm
  overlays/cpu|gpu/
governance/                MaaSAuthPolicy + free (5k tok/min) and premium (100k tok/min) MaaSSubscriptions
observability/
  operators/               Cluster Observability, Tempo, OpenTelemetry operators
  operators-loki/          Loki operator (3.5 usage logs)
  monitoring/              partial DSCInitialization: switches on the RHOAI monitoring stack
  usage-logs/              3.5: MinIO (PoC S3) + LokiStack for per-request usage logs
    cluster-params.env     StorageClass for Loki (written by ./deploy.sh configure)
  overlays/rhoai-3.4|3.5/
argocd/                    Application templates + RBAC for the OpenShift GitOps controller
deploy.sh
```

## Prerequisites

* OpenShift 4.19.9+ with **OpenShift AI 3.4 or 3.5** installed and a `default-dsc` DataScienceCluster
* **Red Hat Connectivity Link** operator (or pass `--with-operators`)
* `oc` logged in as cluster-admin; `jq` and `curl` for `./deploy.sh test`
* For Argo CD: the **OpenShift GitOps** operator and this folder in a git repo Argo CD can read
* `export HF_TOKEN=hf_...` (Gemma is gated, see [Hugging Face token for Gemma](#hugging-face-token-for-gemma))

## Deploy with oc

```bash
export HF_TOKEN=hf_xxx
./deploy.sh oc --rhoai-version 3.4   # pin overlays + operator to 3.4 (playground via Llama Stack)
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
| force Authorino `listener.tls.enabled=true` if Kuadrant left it false | gateway ext_authz requires TLS |
| 3.5 only: copy `maas-db-config` to `redhat-ai-gateway-infra` | namespace only exists after MaaS is enabled |
| label the maas-api namespace `maas.opendatahub.io/gateway-access=true` | same |
| 3.4 after downgrade: delete leftover 3.5 `Config` / `redhat-ai-gateway-infra` maas-api | competing deny-only HTTPRoute breaks dashboard MaaS |

## Hugging Face token for Gemma

`google/gemma-3-270m-it` is a gated repo. Qwen needs no token. The token ends up in the
`hf-token` secret in `maas-models` and reaches the KServe storage-initializer through the
`hf-model-puller` ServiceAccount. It only works if **both** of these are true:

1. The Hugging Face account that owns the token has accepted the Gemma license. Open
   https://huggingface.co/google/gemma-3-270m-it while logged in with that account: it either says
   you have been granted access, or shows the button to accept.
2. The token may read gated repos. Classic `read` / `write` tokens always can. A **fine-grained**
   token needs, under Settings > Access Tokens > edit token > Repositories:
   **"Read access to contents of all public gated repos you can access"**. Editing it keeps the
   token value, so nothing changes in the cluster.

If either is missing, the storage-initializer fails with `403 ... Cannot access gated repo ...
you are not in the authorized list` and the pod goes to `Init:CrashLoopBackOff`.

Check and fix:

```bash
./deploy.sh hf-check     # tests HF_TOKEN from your shell, or else the token in the cluster secret
```

It prints the account and token type and, when access is denied, the exact steps for that token
type. Hugging Face's own denials are recognised by their `X-Error-Code` header, so a 403 from a
corporate proxy is reported as "could not verify" instead. The same check runs at the start of
every deploy (warning only).

After fixing:

| What you changed | Next step |
|---|---|
| Accepted the license and/or edited the fine-grained token | `./deploy.sh wait` (same token, it restarts the Gemma pod and retries) |
| Created a new token | `export HF_TOKEN=hf_...; ./deploy.sh oc` (updates the secret), or update the secret yourself and run `./deploy.sh wait` |

Manual equivalent of `hf-check`:

```bash
T=$(oc get secret hf-token -n maas-models -o jsonpath='{.data.HF_TOKEN}' | base64 -d)
curl -s -H "Authorization: Bearer $T" https://huggingface.co/api/whoami-v2 | jq -r '.name, .auth.accessToken.role'
curl -sI -H "Authorization: Bearer $T" https://huggingface.co/google/gemma-3-270m-it/resolve/main/config.json | grep -iE '^HTTP|x-error'
# OK = HTTP 200 or 302 and no x-error-code line
```

No token at all: point Gemma at an ungated copy of the same weights (Gemma license terms still
apply), e.g. `uri: hf://unsloth/gemma-3-270m-it` in `models/gemma-3-270m-it/llminferenceservice.yaml`.

## Token consumption dashboards

| Where | What | Version |
|---|---|---|
| RHOAI dashboard > Observe & monitor | Per-request usage: tokens per model, subscription and user, admin and per-user views (logs based, Loki) | 3.5 |
| RHOAI dashboard > MaaS observability dashboard | Token consumption, request counts and rate-limit hits per subscription, CSV export | 3.4 + 3.5 (Tech Preview) |
| `./deploy.sh usage [--window 7d]` | Tokens / requests / 429s per model and subscription, straight from Prometheus | 3.4 + 3.5 |

What gets switched on: the monitoring stack in `default-dsci`, gateway telemetry on the MaaS
tenant config (adds `model` and `subscription` labels to the token counters), and on 3.5 the
usage-log pipeline. Per-user metrics are off by default for privacy; enable them with
`--capture-user`. To add only the dashboards to an existing install: `./deploy.sh observability`.

Rate-limit counters live in Limitador memory, so `usage` numbers reset when that pod restarts.
The 3.5 logs-based dashboards do not have that limitation.

## Gen AI playground

**Prefer 3.4 for the playground.** OpenShift AI 3.4 has **no `ogx` component**. The playground
backend is `llamastackoperator` (`llamastack.io` CRDs). That is what
`platform/50-rhoai/rhoai-3.4` enables, and it does not produce the OGX "no matches for kind"
errors.

**RHOAI 3.5 known issue:** on several 3.5.x builds the OGX module CRD is not shipped. Setting
`ogx: Managed` then leaves `OGXReady=False` ("no matches for kind OGX") and keeps the whole DSC
NotReady. On 3.5 the playground is therefore opt-in: `./deploy.sh playground` enables `ogx`,
and rolls it back to `Removed` automatically if it hits this issue. Every run also starts with
a self-heal check: if `ogx: Managed` is stuck on this error (from an earlier run or a manual
edit), it is set back to `Removed` before anything else happens. MaaS itself is not affected.

The DSC gets `llamastackoperator` (3.4) or `ogx` (3.5, via `./deploy.sh playground`) set to
`Managed`, the dashboard gets `genAiStudio: true`, and both models carry the
`opendatahub.io/genai-asset: "true"` label so they show up as AI asset endpoints. Qwen also has
tool calling enabled (`hermes` parser), so it can use MCP servers in the playground. Gemma 3
270M is too small for reliable tool calling, but it still needs `--enable-auto-tool-choice`,
`--tool-call-parser=pythonic`, and the permissive `chat-template-playground.jinja` (ConfigMap
`gemma-3-270m-it-chat-template`): the playground prepends an assistant welcome turn and
`instructions` as a system message, and Gemma's stock template rejects that with
`Conversation roles must alternate user/assistant/...`, which shows up as an empty failed
assistant turn in the UI.

On **3.4**, the playground Llama Stack server is **declared in git** as
`platform/60-playground` (a `LlamaStackDistribution` + `llama-stack-config` ConfigMap).
`./deploy.sh oc --rhoai-version 3.4` and the Argo CD `maas-platform` app (3.4 overlay)
apply it. It stays in project **`ai-tenants`** because that is where the dashboard
project-scoped Playground UI expects it (and where the MaaS controller creates the
namespace); the server calls Gemma/Qwen through the MaaS gateway URLs from
`cluster-params.env`, not as in-namespace model pods.

MaaS AuthPolicy requires a real `sk-oai-*` API key on every chat call. The LSD mounts
Secret `ai-tenants/lsd-maas-api-keys` (created by `./deploy.sh`, never in git). A UI
placeholder of `fake` (what the dashboard uses when key creation fails, e.g. after a
Postgres wipe on 3.5→3.4) makes `/v1/responses` fail with provider 401 and the UI shows
an empty assistant turn with only **Show metrics**.

Open **Gen AI studio > Playground**, project `ai-tenants`, and pick
`maas-vllm-inference-1/gemma-3-270m-it` or `maas-vllm-inference-2/qwen3-0-6b`.
Refresh the page after the LSD rolls out; no model/subscription change is needed.

On **3.5** (OGX, opt-in), a playground is still created per project from the UI:

1. RHOAI dashboard > **Gen AI studio > AI asset endpoints**, project `maas-models`
2. **Add to playground** on both models, then **Create playground**
3. **Gen AI studio > Playground**

### Pin / downgrade OpenShift AI to 3.4

`platform/50-rhoai/rhoai-3.4/subscription.yaml` pins the operator to channel `stable-3.4`
(`startingCSV: rhods-operator.3.4.4`). OLM does **not** downgrade an existing 3.5 CSV when you
only change the channel: delete the Subscription and the 3.5 CSV, then apply the 3.4 overlay
(or `./deploy.sh oc --rhoai-version 3.4`).

After a 3.5 → 3.4 operator swap, also:

* Switch MaaS to the 3.4 shape: `kserve.modelsAsService: Managed`, remove `aigateway` / `ogx`
  from the DSC (the 3.4 overlay does this).
* Reset the PoC MaaS Postgres schema if `maas-api` crashes on migration version 5 (3.5 schema
  has no down path on 3.4).
* Delete leftover 3.5 **module** Deployments that dual-control the same CRs as the 3.4 platform
  operator (`dashboard-operator`, `workbenches-operator`, `opendatahub-feast-operator`,
  `kserve-module-controller-manager`). Leaving them scaled to 0 still blocks `DashboardReady`.
* Recreate Deployments whose `spec.selector` 3.4 cannot patch (immutable field), if the operator
  reports that error.
* Delete the leftover 3.5 MaaS `Config` CR (`configs.maas.opendatahub.io/default`) and anything
  it still owns under `redhat-ai-gateway-infra` (especially `maas-api-route`). That route wins
  over the 3.4 `maas-api` in `redhat-ods-applications` and its AuthPolicy is deny-only, so the
  dashboard shows "Models as a Service could not be loaded" and API keys fail with HTTP 500.
  `./deploy.sh` does this automatically on 3.4 via `maas_api_glue`.
* Re-apply Authorino TLS (`platform/20-authorino-tls`). Kuadrant often leaves
  `listener.tls.enabled=false`; the gateway then cannot reach Authorino and `/maas-api` returns
  plain-text `Internal Server Error`.
* Label the live maas-api namespace `maas.opendatahub.io/gateway-access=true` so its HTTPRoute
  is admitted (`redhat-ods-applications` on 3.4).
* Recreate MaaS API keys (Postgres is wiped with the schema reset). Re-run
  `./deploy.sh oc --rhoai-version 3.4` (or mint a key and refresh Secret
  `ai-tenants/lsd-maas-api-keys`) so the Gen AI playground stops using `VLLM_API_TOKEN=fake`.
* If `oc apply` on `LLMInferenceService` fails with webhook "could not find the requested
  resource" (3.5→3.4 path skew on llmisvc / odh-model-controller webhooks), set those
  Mutating/ValidatingWebhookConfigurations to `failurePolicy: Ignore` long enough to apply,
  or re-apply after the kserve / model-controller pods have settled on 3.4 images.

On **AI asset endpoints**, pick project **`maas-models`** (not `ai-tenants`). The project
dropdown filters project-scoped gen-ai assets; Gemma/Qwen live in `maas-models` with
`opendatahub.io/genai-asset: "true"`. The MaaS source itself is cluster-wide once healthy.

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
  `aigateway.modelsAsAService` (the 3.4 field is frozen in 3.5). The 3.4 overlay also pins the
  operator Subscription to `stable-3.4` so a fresh install does not land on 3.5 via `stable-3.x`.
  See [Pin / downgrade OpenShift AI to 3.4](#pin--downgrade-openshift-ai-to-34).
* **Gemma token.** See [Hugging Face token for Gemma](#hugging-face-token-for-gemma). If the
  `hf-check` passes but the pod still fails with 401, your KServe build does not pass the token
  from the ServiceAccount on: mirror the model into an OCI modelcar image and use `uri: oci://...`.
* **Xet download hang.** If a storage-initializer is stuck in `Init:0/1`, the script sets
  `HF_HUB_DISABLE_XET=1` on it after 5 minutes. KServe can revert that on reconcile.
* **PostgreSQL** in `maas-db` and **MinIO** in `redhat-ods-monitoring` are single-replica PoCs.
  Use `--postgres-url` and real S3/ODF storage for anything that matters.
* **Stuck models** no longer block the script. Error states (`Error`, `CrashLoopBackOff`,
  `OOMKilled`, `ImagePullBackOff`) are diagnosed immediately; silent states (`Pending`, a hanging
  download, running but never ready) are reported every minute and diagnosed after
  `--model-timeout` minutes (default 30). The script then finishes the rest and exits non-zero.
  After a fix: `./deploy.sh wait`.
* **Argo CD RBAC.** `argocd/rbac.yaml` grants the GitOps controller cluster-admin. Scope it down
  for production.
* **Swap models** by editing `spec.model.uri` (for example `hf://Qwen/Qwen2.5-0.5B-Instruct`)
  and the names in `governance/`.

## Clean up

```bash
./deploy.sh destroy                 # models, governance, gateway, PoC DB (or the Argo CD apps)
./deploy.sh destroy --disable-maas  # also switch MaaS off in the DSC
```

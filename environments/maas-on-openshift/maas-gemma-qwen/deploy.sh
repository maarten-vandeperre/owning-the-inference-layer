#!/usr/bin/env bash
# =============================================================================
# Models-as-a-Service on OpenShift AI with the smallest Gemma and Qwen models
#   - google/gemma-3-270m-it   (gated on Hugging Face, needs HF_TOKEN)
#   - Qwen/Qwen3-0.6B
#
# Commands
#   configure   Detect cluster domain + TLS secret, write platform/30-gateway/cluster-params.env
#   oc          Deploy everything with the oc CLI (layer by layer, with readiness waits)
#   argocd      Bootstrap secrets, then hand the manifests to Argo CD (OpenShift GitOps)
#   test        Create a MaaS API key and send a chat completion to both models
#   usage       Token consumption per model / subscription (/ user) from Prometheus
#   wait        Re-check the models (with diagnostics) after fixing something
#   observability  Add only the dashboards/telemetry to an existing MaaS install
#   playground  Enable the Gen AI playground backend (opt-in on 3.5, see README)
#   hf-check    Check that the Hugging Face token can download Gemma, and how to fix it if not
#   status      Show the state of all MaaS resources
#   render      Print the rendered manifests (no cluster changes)
#   destroy     Remove models, governance, gateway and PoC database
#
# Options
#   --rhoai-version 3.4|3.5   Default: auto-detected from the installed operator
#   --accelerator cpu|gpu     Default: cpu (vLLM CPU). gpu = vLLM CUDA, 1 NVIDIA GPU per model
#   --with-operators          Also install Connectivity Link, LWS and cert-manager operators
#   --postgres-url URL        Use an external PostgreSQL instead of the PoC one in maas-db
#   --repo-url URL            (argocd) Git repo Argo CD pulls from. Default: git remote origin
#   --revision REV            (argocd) Branch/tag/commit. Default: current branch
#   --no-observability        Skip the telemetry / token consumption dashboards
#   --capture-user            Add the user id to token metrics (off by default, GDPR)
#   --model-timeout MIN       Max minutes to wait per model before diagnosing (default 30)
#   --window DURATION         (usage) Time window, Prometheus syntax. Default: 24h
#   --disable-maas            (destroy) Also set MaaS to Removed in the DataScienceCluster
#
# Environment
#   HF_TOKEN   Hugging Face token of an account that accepted the Gemma license
# =============================================================================
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS_FILE="${ROOT_DIR}/platform/30-gateway/cluster-params.env"
PLAYGROUND_PARAMS_FILE="${ROOT_DIR}/platform/60-playground/cluster-params.env"
OBS_PARAMS_FILE="${ROOT_DIR}/observability/usage-logs/cluster-params.env"
MONITORING_NS="redhat-ods-monitoring"

MODELS_NS="maas-models"
DB_NS="maas-db"
RHOAI_APPS_NS="redhat-ods-applications"
GATEWAY_INFRA_NS_35="redhat-ai-gateway-infra"
MAAS_POLICY_NS="models-as-a-service"
GITOPS_NS="openshift-gitops"
MODELS=("gemma-3-270m-it" "qwen3-0-6b")

RHOAI_VERSION=""
ACCELERATOR="cpu"
WITH_OPERATORS=false
POSTGRES_URL=""
REPO_URL=""
REVISION=""
DISABLE_MAAS=false
WITH_OBSERVABILITY=true
CAPTURE_USER=false
MODEL_TIMEOUT_MIN=30
USAGE_WINDOW="24h"

# ----------------------------------------------------------------------------- logging
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step() { echo "${B}==> $*${N}"; }
info() { echo "    $*"; }
ok()   { echo "    ${G}OK${N} $*"; }
warn() { echo "    ${Y}WARN${N} $*" >&2; }
die()  { echo "${R}ERROR${N} $*" >&2; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ----------------------------------------------------------------------------- helpers
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }

# wait_until <timeout-seconds> <description> <command...>
wait_until() {
  local timeout=$1 desc=$2; shift 2
  local start=$SECONDS last=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start >= timeout )) && { warn "timed out after ${timeout}s waiting for: ${desc}"; return 1; }
    if (( SECONDS - last >= 60 )); then   # heartbeat, so a long wait never looks like a hang
      info "... still waiting for: ${desc} ($(( (SECONDS - start) / 60 ))/$(( timeout / 60 )) min)"
      last=$SECONDS
    fi
    sleep 10
  done
  ok "$desc"
}

apply_k() {  # server-side apply of a kustomize dir (partial objects rely on SSA)
  oc apply --server-side --force-conflicts --field-manager=maas-deploy -k "$1"
}

ns_ensure() {
  oc get namespace "$1" >/dev/null 2>&1 || oc create namespace "$1" >/dev/null
}

crd_exists() { oc get crd "$1" >/dev/null 2>&1; }

param() { grep -E "^$1=" "$PARAMS_FILE" | cut -d= -f2-; }

maas_api_ns() {
  # Prefer the namespace that matches the active RHOAI version. After a 3.5→3.4
  # downgrade both can exist briefly; picking gateway-infra first would glue the
  # leftover 3.5 API that cannot list MaaSModelRefs.
  local order
  if [[ "$RHOAI_VERSION" == "3.5" ]]; then
    order=("$GATEWAY_INFRA_NS_35" "$RHOAI_APPS_NS")
  else
    order=("$RHOAI_APPS_NS" "$GATEWAY_INFRA_NS_35")
  fi
  local ns
  for ns in "${order[@]}"; do
    oc get deployment maas-api -n "$ns" >/dev/null 2>&1 && { echo "$ns"; return 0; }
  done
  return 1
}

# ----------------------------------------------------------------------------- preflight
preflight() {
  step "Preflight checks"
  need oc
  oc whoami >/dev/null 2>&1 || die "not logged in, run 'oc login' first"
  oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || die "cluster-admin rights are required"
  ok "logged in as $(oc whoami) on $(oc whoami --show-server)"

  local csv version
  csv=$(oc get csv -n redhat-ods-operator -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.version}{"\n"}{end}' 2>/dev/null | grep '^rhods-operator' | head -1 || true)
  [[ -n "$csv" ]] || die "Red Hat OpenShift AI operator not found in redhat-ods-operator"
  version=$(awk '{print $2}' <<<"$csv" | cut -d. -f1,2)
  ok "OpenShift AI ${version} installed"

  if [[ -z "$RHOAI_VERSION" ]]; then
    if printf '%s\n3.5\n' "$version" | sort -V | head -1 | grep -qx '3.5'; then RHOAI_VERSION="3.5"
    elif [[ "$version" == "3.4" ]]; then RHOAI_VERSION="3.4"
    else die "OpenShift AI ${version} is not supported: these manifests need 3.4+ (subscription based MaaS)"; fi
  fi
  [[ "$RHOAI_VERSION" == "3.4" || "$RHOAI_VERSION" == "3.5" ]] || die "--rhoai-version must be 3.4 or 3.5"
  info "using platform overlay rhoai-${RHOAI_VERSION}, accelerator ${ACCELERATOR}"

  oc get datasciencecluster default-dsc >/dev/null 2>&1 || die "DataScienceCluster 'default-dsc' not found"
  heal_known_ogx_issue

  if [[ "$WITH_OPERATORS" == false ]]; then
    local csvs; csvs=$(oc get csv -n openshift-operators -o name 2>/dev/null || true)
    grep -q rhcl-operator <<<"$csvs" || die "Red Hat Connectivity Link operator not found, install it or pass --with-operators"
    ok "Connectivity Link operator present"
  fi

  if [[ "$ACCELERATOR" == "gpu" ]]; then
    local gpus; gpus=$(oc get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}')
    grep -q '[1-9]' <<<"$gpus" || warn "no allocatable nvidia.com/gpu found on any node, GPU pods will stay Pending"
  fi
}

# ----------------------------------------------------------------------------- configure
configure() {
  step "Detecting cluster specific values"
  local domain cert host
  domain=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
  cert=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || true)
  cert=${cert:-router-certs-default}
  host="maas.${domain}"
  cat >"$PARAMS_FILE" <<EOF
# Cluster specific values, generated by: ./deploy.sh configure
# Commit this file when you deploy with Argo CD.
MAAS_HOSTNAME=${host}
TLS_SECRET_NAME=${cert}
PLAYGROUND_VLLM_URL_GEMMA=https://${host}/maas-models/gemma-3-270m-it/v1
PLAYGROUND_VLLM_URL_QWEN=https://${host}/maas-models/qwen3-0-6b/v1
EOF
  # kustomize load-restrictor: playground cannot read ../30-gateway/cluster-params.env
  cp "$PARAMS_FILE" "$PLAYGROUND_PARAMS_FILE"
  ok "MAAS_HOSTNAME=${host}"
  ok "TLS_SECRET_NAME=${cert} (wildcard *.${domain} cert served by the gateway)"
  ok "PLAYGROUND_VLLM_URL_* for Llama Stack playground base URLs"

  local sc
  sc=$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)
  [[ -n "$sc" ]] || { sc=$(oc get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); warn "no default StorageClass, using '${sc}'"; }
  cat >"$OBS_PARAMS_FILE" <<EOF
# Cluster specific values, generated by: ./deploy.sh configure
# Commit this file when you deploy with Argo CD.
STORAGE_CLASS=${sc}
EOF
  ok "STORAGE_CLASS=${sc} (Loki usage logs)"
}

# ----------------------------------------------------------------------------- operators
install_operators() {
  step "Installing prerequisite operators"
  oc apply -k "${ROOT_DIR}/operators"
  wait_until 900 "Connectivity Link operator ready" \
    bash -c "oc get csv -n openshift-operators -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{\"\n\"}{end}' | grep -q '^rhcl-operator.* Succeeded'"
  wait_until 900 "LeaderWorkerSet operator ready" \
    bash -c "oc get csv -n openshift-lws-operator -o jsonpath='{.items[*].status.phase}' | grep -q Succeeded"
  wait_until 900 "cert-manager operator ready" \
    bash -c "oc get csv -n cert-manager-operator -o jsonpath='{.items[*].status.phase}' | grep -q Succeeded"
}

# ----------------------------------------------------------------------------- bootstrap
# Everything imperative lives here: secrets (never in git) and cluster wide config
# that must be merged rather than overwritten.
bootstrap() {
  step "Bootstrapping namespaces and secrets"
  ns_ensure "$MODELS_NS"
  oc label namespace "$MODELS_NS" maas.opendatahub.io/gateway-access=true opendatahub.io/dashboard=true --overwrite >/dev/null

  # Hugging Face token for the gated Gemma repo
  if [[ -n "${HF_TOKEN:-}" ]]; then
    oc create secret generic hf-token -n "$MODELS_NS" --from-literal=HF_TOKEN="$HF_TOKEN" \
      --dry-run=client -o yaml | oc apply -f - >/dev/null
    ok "secret ${MODELS_NS}/hf-token"
  elif oc get secret hf-token -n "$MODELS_NS" >/dev/null 2>&1; then
    ok "secret ${MODELS_NS}/hf-token already present (checking the token stored there)"
    HF_TOKEN=$(oc get secret hf-token -n "$MODELS_NS" -o jsonpath='{.data.HF_TOKEN}' | base64 -d)
  else
    die "HF_TOKEN is not set. google/gemma-3-270m-it is gated: accept the license on huggingface.co, then export HF_TOKEN=hf_..."
  fi

  hf_access_check || true

  # PostgreSQL for MaaS API keys
  local db_url
  if [[ -n "$POSTGRES_URL" ]]; then
    db_url="$POSTGRES_URL"
    info "using external PostgreSQL"
  else
    ns_ensure "$DB_NS"
    local pw
    if oc get secret postgres-creds -n "$DB_NS" >/dev/null 2>&1; then
      pw=$(oc get secret postgres-creds -n "$DB_NS" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
    else
      pw=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32)
      oc create secret generic postgres-creds -n "$DB_NS" \
        --from-literal=POSTGRES_USER=maas --from-literal=POSTGRES_PASSWORD="$pw" --from-literal=POSTGRES_DB=maas >/dev/null
    fi
    ok "secret ${DB_NS}/postgres-creds"
    db_url="postgresql://maas:${pw}@postgres.${DB_NS}.svc.cluster.local:5432/maas?sslmode=disable"
  fi
  oc create secret generic maas-db-config -n "$RHOAI_APPS_NS" --from-literal=DB_CONNECTION_URL="$db_url" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "secret ${RHOAI_APPS_NS}/maas-db-config"

  # S3 credentials for the Loki usage-log store (RHOAI 3.5+ usage dashboards)
  if [[ "$WITH_OBSERVABILITY" == true && "$RHOAI_VERSION" == "3.5" ]]; then
    ns_ensure "$MONITORING_NS"
    if ! oc get secret minio-secret -n "$MONITORING_NS" >/dev/null 2>&1; then
      oc create secret generic minio-secret -n "$MONITORING_NS" \
        --from-literal=access_key_id=maas-loki \
        --from-literal=access_key_secret="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32)" \
        --from-literal=bucketnames=loki \
        --from-literal=endpoint="http://minio.${MONITORING_NS}.svc:9000" \
        --from-literal=region=us-east-1 >/dev/null
    fi
    ok "secret ${MONITORING_NS}/minio-secret"
  fi

  # User Workload Monitoring (MaaS reports Degraded without it). Merge, never overwrite.
  local cfg tmp
  cfg=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
  if grep -Eq '^enableUserWorkload:[[:space:]]*true' <<<"$cfg"; then
    ok "user workload monitoring already enabled"
  else
    tmp=$(mktemp)
    if grep -Eq '^enableUserWorkload:' <<<"$cfg"; then
      sed -E 's/^enableUserWorkload:.*/enableUserWorkload: true/' <<<"$cfg" >"$tmp"
    else
      { [[ -n "$cfg" ]] && printf '%s\n' "$cfg"; echo "enableUserWorkload: true"; } >"$tmp"
    fi
    if oc get configmap cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1; then
      oc set data configmap/cluster-monitoring-config -n openshift-monitoring --from-file=config.yaml="$tmp" >/dev/null
    else
      oc create configmap cluster-monitoring-config -n openshift-monitoring --from-file=config.yaml="$tmp" >/dev/null
    fi
    rm -f "$tmp"
    ok "user workload monitoring enabled"
  fi
}

# Checks, from this machine, that the token can actually download the gated Gemma files.
# Only warns: the cluster may reach Hugging Face through a different path.
GEMMA_REPO="google/gemma-3-270m-it"
HF_FIX_URL_LICENSE="https://huggingface.co/${GEMMA_REPO}"
HF_FIX_URL_TOKENS="https://huggingface.co/settings/tokens"

# Checks, from this machine, that the token can actually download the gated Gemma files,
# and explains the exact fix for the account/token type. Returns 0 = OK, 1 = denied,
# 2 = could not verify. Only warns during a deploy: the cluster may use a different network path.
hf_access_check() {
  [[ -n "${HF_TOKEN:-}" ]] || return 2
  command -v curl >/dev/null 2>&1 || return 2
  local who user role headers code hf_err
  who=$(curl -s --max-time 15 -H "Authorization: Bearer ${HF_TOKEN}" https://huggingface.co/api/whoami-v2 || true)
  user=$(grep -o '"name":"[^"]*"' <<<"$who" | head -1 | cut -d'"' -f4 || true)
  role=$(grep -o '"role":"[^"]*"' <<<"$who" | head -1 | cut -d'"' -f4 || true)
  # no -L: an authorized request answers 200 or a redirect to the CDN, a denied one 401/403.
  # Hugging Face tags its own denials with an X-Error-Code header (GatedRepo, ...), which tells
  # them apart from a 403 produced by a corporate proxy.
  headers=$(curl -s -I --max-time 15 -H "Authorization: Bearer ${HF_TOKEN}" \
    "https://huggingface.co/${GEMMA_REPO}/resolve/main/config.json" 2>/dev/null | tr -d '\r' || true)
  code=$(head -1 <<<"$headers" | awk '{print $2}')
  hf_err=$(grep -i '^x-error-code:' <<<"$headers" | head -1 | awk '{print $2}' || true)
  local id="account ${user:-?}, ${role:-unknown} token"
  case "${code}:${hf_err}" in
    2??:*|3??:*)
      ok "Hugging Face token (${id}) can download ${GEMMA_REPO}"; return 0 ;;
    401:?*)
      warn "Hugging Face token is invalid or expired (${hf_err}): Gemma will fail to download."
      warn "  Create a new one at ${HF_FIX_URL_TOKENS}, then: export HF_TOKEN=hf_...; ./deploy.sh oc"
      return 1 ;;
    403:?*)
      warn "Hugging Face token (${id}) is NOT allowed to download ${GEMMA_REPO} (${hf_err})."
      warn "  You can keep this token. Fix it on huggingface.co while logged in as '${user:-the token owner}':"
      warn "  1. Accept the Gemma license (skip if the page says you have been granted access):"
      warn "       ${HF_FIX_URL_LICENSE}"
      if [[ "$role" == "fineGrained" ]]; then
        warn "  2. This is a fine-grained token: edit it at ${HF_FIX_URL_TOKENS} and tick"
        warn "       'Read access to contents of all public gated repos you can access' (token value stays the same)"
      else
        warn "  2. If the license was accepted with ANOTHER account, use a token of that account instead"
      fi
      warn "  Then verify with: ./deploy.sh hf-check   and retry the model with: ./deploy.sh wait"
      return 1 ;;
    *)
      info "could not verify Hugging Face access from this machine (HTTP ${code:-none})"; return 2 ;;
  esac
}

# ./deploy.sh hf-check: test the token that is (or will be) used by the cluster
hf_check_cmd() {
  need curl
  step "Hugging Face access for ${GEMMA_REPO}"
  if [[ -n "${HF_TOKEN:-}" ]]; then
    info "testing HF_TOKEN from your shell"
  else
    need oc
    HF_TOKEN=$(oc get secret hf-token -n "$MODELS_NS" -o jsonpath='{.data.HF_TOKEN}' 2>/dev/null | base64 -d || true)
    [[ -n "$HF_TOKEN" ]] || die "no HF_TOKEN exported and no secret ${MODELS_NS}/hf-token in the cluster"
    info "testing the token stored in secret ${MODELS_NS}/hf-token"
  fi
  local rc=0; hf_access_check || rc=$?
  if [[ $rc -eq 0 ]] && command -v oc >/dev/null 2>&1; then
    local state; state=$(model_pod gemma-3-270m-it 2>/dev/null | awk '{print $2}')
    [[ "$state" == *CrashLoopBackOff* || "$state" == *Error* ]] && info "Gemma pod is ${state}: run ./deploy.sh wait to retry the download now"
  fi
  exit "$rc"   # exit, not return: a non-zero return would trip the ERR trap
}

# ----------------------------------------------------------------------------- glue
# Steps that touch operator owned objects or namespaces that only exist later.
authorino_tls_env() {
  wait_until 300 "Authorino deployment exists" oc get deployment authorino -n kuadrant-system
  # Kuadrant creates Authorino with listener.tls.enabled=false; the gateway's
  # ext_authz talks TLS (service-ca). Without this, /maas-api returns plain-text
  # 500 "Internal Server Error" and the dashboard shows MaaS/API keys failures.
  if [[ "$(oc get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null)" != "true" ]]; then
    apply_k "${ROOT_DIR}/platform/20-authorino-tls"
    wait_until 120 "Authorino TLS enabled" \
      bash -c '[[ "$(oc get authorino authorino -n kuadrant-system -o jsonpath="{.spec.listener.tls.enabled}")" == "true" ]]'
    ok "Authorino TLS listener re-enabled"
  fi
  if oc get deployment authorino -n kuadrant-system -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -q SSL_CERT_FILE; then
    ok "Authorino trusts the service CA"
  else
    oc -n kuadrant-system set env deployment/authorino \
      SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
      REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt >/dev/null
    ok "Authorino configured to trust the service CA"
  fi
}

# 3.5 aigateway left a cluster-scoped Config that keeps a competing maas-api
# HTTPRoute in redhat-ai-gateway-infra. That route's AuthPolicy is
# deny-unconfigured-models only, so /maas-api returns 403/500 to the dashboard
# even when the 3.4 maas-api in redhat-ods-applications is healthy.
cleanup_maas_35_leftovers() {
  [[ "$RHOAI_VERSION" == "3.4" ]] || return 0
  if oc get config.maas.opendatahub.io default >/dev/null 2>&1; then
    oc delete config.maas.opendatahub.io default --wait=false >/dev/null
    ok "deleted leftover 3.5 MaaS Config (was owning ${GATEWAY_INFRA_NS_35}/maas-api)"
  fi
  if oc get httproute maas-api-route -n "$GATEWAY_INFRA_NS_35" >/dev/null 2>&1; then
    oc delete httproute maas-api-route -n "$GATEWAY_INFRA_NS_35" --wait=false >/dev/null
    ok "deleted leftover ${GATEWAY_INFRA_NS_35}/maas-api-route"
  fi
  if oc get deployment maas-api -n "$GATEWAY_INFRA_NS_35" >/dev/null 2>&1; then
    oc delete deployment,svc,cronjob -l app.kubernetes.io/name=maas-api -n "$GATEWAY_INFRA_NS_35" --wait=false >/dev/null 2>&1 || true
    ok "deleted leftover ${GATEWAY_INFRA_NS_35}/maas-api workload"
  fi
}

maas_api_glue() {
  wait_until 600 "MaaS CRDs installed" crd_exists maasmodelrefs.maas.opendatahub.io
  cleanup_maas_35_leftovers
  wait_until 600 "maas-api deployment created" maas_api_ns
  local ns; ns=$(maas_api_ns)
  info "maas-api runs in ${ns}"

  # 3.5+: maas-api moved to redhat-ai-gateway-infra and reads the DB secret there
  if [[ "$ns" == "$GATEWAY_INFRA_NS_35" ]] && ! oc get secret maas-db-config -n "$ns" >/dev/null 2>&1; then
    local url; url=$(oc get secret maas-db-config -n "$RHOAI_APPS_NS" -o jsonpath='{.data.DB_CONNECTION_URL}' | base64 -d)
    oc create secret generic maas-db-config -n "$ns" --from-literal=DB_CONNECTION_URL="$url" >/dev/null
    oc rollout restart deployment/maas-api -n "$ns" >/dev/null
    ok "mirrored maas-db-config to ${ns}"
  fi
  # The maas-api HTTPRoute must be admitted by the gateway
  oc label namespace "$ns" maas.opendatahub.io/gateway-access=true --overwrite >/dev/null
  oc rollout status deployment/maas-api -n "$ns" --timeout=300s >/dev/null && ok "maas-api ready"
}

# The Gen AI playground needs the OGX (3.5) / Llama Stack (3.4) CRDs. The dashboard caches
# API discovery at startup, so if it started before those CRDs existed it shows
# "no matches for ogx.io/v1beta1" until it is restarted.
playground_group() { [[ "$RHOAI_VERSION" == "3.5" ]] && echo "ogx.io" || echo "llamastack.io"; }
playground_crd_time() {
  local g; g=$(playground_group)
  oc get crd -o jsonpath="{range .items[?(@.spec.group==\"${g}\")]}{.metadata.creationTimestamp}{\"\\n\"}{end}" 2>/dev/null | sort | tail -1
}
playground_crds_exist() { [[ -n "$(playground_crd_time)" ]]; }

playground_conditions() {  # OGX / Llama Stack related DSC conditions, one per line
  oc get datasciencecluster default-dsc \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null \
    | grep -iE 'ogx|llama' || true
}

ogx_state() { oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.ogx.managementState}' 2>/dev/null || true; }
set_ogx() {
  oc patch datasciencecluster default-dsc --type=merge \
    -p "{\"spec\":{\"components\":{\"ogx\":{\"managementState\":\"$1\"}}}}" >/dev/null
}

# Self-heal at the start of every run: an earlier run (or a manual edit) may have left
# "ogx: Managed" on a 3.5.x build without the OGX module CRD, which pins the DSC at Ready=False.
heal_known_ogx_issue() {
  [[ "$RHOAI_VERSION" == "3.5" && "$(ogx_state)" == "Managed" ]] || return 0
  if grep -q 'no matches for kind "OGX"' <<<"$(playground_conditions)"; then
    set_ogx Removed
    warn "known RHOAI 3.5.x OGX issue found: set ogx back to Removed so default-dsc can become Ready"
    info "the playground stays off until an OpenShift AI update; retry then with ./deploy.sh playground"
  fi
}

# Explicit opt-in on 3.5 (./deploy.sh playground); always part of the deploy on 3.4.
enable_playground() {
  if [[ "$RHOAI_VERSION" == "3.5" && "$(ogx_state)" != "Managed" ]]; then
    set_ogx Managed
    ok "ogx set to Managed in default-dsc"
  fi
  PLAYGROUND_REQUESTED=true
  playground_glue
}

# Create / refresh the MaaS API key Secret the Llama Stack playground mounts.
# AuthPolicy on the MaaS gateway requires Bearer sk-oai-*; the UI placeholder
# "fake" produces empty assistant turns (provider 401, UI hides the error).
playground_maas_keys() {
  local host key ns=ai-tenants secret=lsd-maas-api-keys
  oc get namespace "$ns" >/dev/null 2>&1 || return 0
  host=$(param MAAS_HOSTNAME 2>/dev/null || true)
  [[ -n "$host" && "$host" != *CHANGE-ME* ]] || host="maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
  key=$(curl -sk --max-time 60 -X POST "https://${host}/maas-api/v1/api-keys" \
      -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
      -d '{"name":"lsd-genai-playground","subscription":"small-models-free","expiresIn":"720h"}' \
      | jq -r '.key // empty')
  if [[ -z "$key" ]]; then
    warn "could not mint a MaaS API key for the playground (is Postgres / maas-api healthy?)"
    warn "chats will stay empty until Secret ${ns}/${secret} holds a real sk-oai-* key"
    return 0
  fi
  oc create secret generic "$secret" -n "$ns" \
    --from-literal=VLLM_API_TOKEN_1="$key" --from-literal=VLLM_API_TOKEN_2="$key" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "playground MaaS API key stored in Secret ${ns}/${secret}"
  # Restart if the LSD is already running so it picks up a rotated key
  if oc get deploy lsd-genai-playground -n "$ns" >/dev/null 2>&1; then
    oc rollout restart deployment/lsd-genai-playground -n "$ns" >/dev/null 2>&1 || true
  fi
}

playground_glue() {
  step "Gen AI playground"
  if [[ "$RHOAI_VERSION" == "3.5" && "$(ogx_state)" != "Managed" && "${PLAYGROUND_REQUESTED:-false}" != true ]]; then
    info "skipped on 3.5 by default (known OGX module issue on some 3.5.x builds)"
    info "try it with: ./deploy.sh playground  (rolls back automatically if the issue is present)"
    return 0
  fi
  local g crd_t pods_t start=$SECONDS last=$SECONDS cond
  g=$(playground_group)
  until playground_crds_exist; do
    cond=$(playground_conditions)
    # Known RHOAI 3.5.x issue: the OGX module CRD is not shipped, the DSC stays NotReady forever
    if (( SECONDS - start >= 60 )) && grep -q 'no matches for kind "OGX"' <<<"$cond"; then
      warn "known RHOAI 3.5.x issue: the OGX module CRD (components.platform.opendatahub.io OGX) is not"
      warn "installed on this cluster, so the playground backend cannot be deployed."
      set_ogx Removed
      warn "rolled ogx back to Removed so default-dsc can become Ready again (MaaS is not affected)."
      info "retry after an OpenShift AI update: ./deploy.sh playground"
      return 0
    fi
    # Any other failing component status: show it instead of waiting 10 minutes
    if (( SECONDS - start >= 120 )) && grep -q '=False' <<<"$cond"; then
      warn "the ${g} API is not being installed, the operator reports:"
      sed 's/^/      /' <<<"$cond"
      info "operator log: oc logs -n redhat-ods-operator deploy/rhods-operator --since=15m | grep -iE 'ogx|llama'"
      return 0
    fi
    if (( SECONDS - start >= 600 )); then
      warn "${g} API still missing after 10 min. DSC conditions: ${cond:-none mention ogx/llama}"
      return 0
    fi
    if (( SECONDS - last >= 60 )); then
      info "... still waiting for the ${g} API ($(( (SECONDS - start) / 60 ))/10 min)"
      last=$SECONDS
    fi
    sleep 10
  done
  ok "${g} API installed (playground backend)"
  crd_t=$(playground_crd_time)
  pods_t=$(oc get pods -n "$RHOAI_APPS_NS" -l app=rhods-dashboard -o jsonpath='{range .items[*]}{.status.startTime}{"\n"}{end}' 2>/dev/null | sort | head -1)
  if [[ -z "$pods_t" || "$pods_t" < "$crd_t" ]]; then
    oc rollout restart deployment/rhods-dashboard -n "$RHOAI_APPS_NS" >/dev/null
    oc rollout status deployment/rhods-dashboard -n "$RHOAI_APPS_NS" --timeout=300s >/dev/null || true
    ok "dashboard restarted so it picks up the ${g} API"
  else
    ok "dashboard already knows the ${g} API"
  fi
}

# ----------------------------------------------------------------------------- waits
kuadrant_ready() { oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=10s; }

wait_kuadrant() {
  wait_until 240 "Kuadrant ready" kuadrant_ready && return 0
  # Known behaviour: Kuadrant stays on MissingDependency after the Gateway API provider
  # was installed underneath it. A restart of the operator pod makes it re-check.
  local pod
  pod=$(oc get pods -n openshift-operators -o name | grep kuadrant-operator-controller | head -1 || true)
  [[ -n "$pod" ]] && { warn "restarting ${pod}"; oc delete "$pod" -n openshift-operators >/dev/null; }
  wait_until 480 "Kuadrant ready" kuadrant_ready || die "Kuadrant not Ready: oc describe kuadrant kuadrant -n kuadrant-system"
}

wait_platform() {
  wait_kuadrant
  wait_until 300 "Gateway programmed" \
    oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=10s || true
  if [[ -z "$POSTGRES_URL" ]]; then
    wait_until 600 "PostgreSQL ready" oc rollout status deployment/postgres -n "$DB_NS" --timeout=10s
  fi
}

FAILED_MODELS=""   # plain string, empty arrays break "set -u" on macOS bash 3.2

model_pod() {        # "<pod> <status>" of the model's workload pod, empty if none yet
  oc get pods -n "$MODELS_NS" --no-headers 2>/dev/null | awk -v p="${1}-kserve-" 'index($1,p)==1 && $3!="Terminating" {print $1, $3; exit}'
}

diagnose_model() {
  local m=$1 pod
  pod=$(model_pod "$m" | awk '{print $1}')
  if [[ -z "$pod" ]]; then
    warn "${m}: no pod created, recent events:"
    oc get events -n "$MODELS_NS" --sort-by=.lastTimestamp 2>/dev/null | tail -8 | sed 's/^/      /'
    return 0
  fi
  warn "${m}: pod ${pod} is $(model_pod "$m" | awk '{print $2}')"
  info "storage-initializer env: $(oc get pod "$pod" -n "$MODELS_NS" -o jsonpath='{.spec.initContainers[0].env[*].name}' 2>/dev/null)"
  info "--- storage-initializer log (tail)"
  oc logs "$pod" -n "$MODELS_NS" -c storage-initializer --tail=15 2>&1 | sed 's/^/      /' || true
  if oc logs "$pod" -n "$MODELS_NS" -c storage-initializer --tail=50 2>/dev/null | grep -q 'gated repo'; then
    warn "${m}: the HF token reaches the pod, but its Hugging Face account is not allowed to download this gated model."
    info "  exact fix for this token: ./deploy.sh hf-check   (see also README, 'Hugging Face token for Gemma')"
  fi
  info "--- main log (tail)"
  oc logs "$pod" -n "$MODELS_NS" -c main --tail=15 2>&1 | sed 's/^/      /' || true
}

# KServe storage-initializer can hang on the Hugging Face Xet protocol; fall back to HTTP.
xet_workaround() {
  local dep="${1}-kserve"
  oc get deployment "$dep" -n "$MODELS_NS" >/dev/null 2>&1 || return 0
  warn "${1}: still in Init after 5 min, setting HF_HUB_DISABLE_XET=1 on the storage-initializer"
  oc set env "deployment/${dep}" -n "$MODELS_NS" -c storage-initializer HF_HUB_DISABLE_XET=1 >/dev/null 2>&1 || true
}

wait_models() {
  step "Waiting for models (image pull + download + load can take 5-15 min)"
  restart_failed_models
  local m state start last xet_done pending_told limit=$(( MODEL_TIMEOUT_MIN * 60 ))
  for m in "${MODELS[@]}"; do
    start=$SECONDS; last=0; xet_done=false; pending_told=false
    while ! oc wait "llminferenceservice/${m}" -n "$MODELS_NS" --for=condition=Ready --timeout=5s >/dev/null 2>&1; do
      state=$(model_pod "$m" | awk '{print $2}')
      case "$state" in
        *Error*|*CrashLoopBackOff*|*OOMKilled*|*ImagePullBackOff*|*ErrImagePull*)
          diagnose_model "$m"; FAILED_MODELS="${FAILED_MODELS} ${m}"; break ;;
        Init:0/1)
          if (( SECONDS - start > 300 )) && [[ "$xet_done" == false ]]; then xet_workaround "$m"; xet_done=true; fi ;;
        Pending)
          if (( SECONDS - start > 180 )) && [[ "$pending_told" == false ]]; then
            warn "${m}: Pending for 3 min: $(oc get events -n "$MODELS_NS" --field-selector reason=FailedScheduling -o jsonpath='{.items[-1:].message}' 2>/dev/null)"
            pending_told=true
          fi ;;
      esac
      if (( SECONDS - start > limit )); then
        diagnose_model "$m"; FAILED_MODELS="${FAILED_MODELS} ${m}"; break
      fi
      if (( SECONDS - last >= 60 )); then
        info "$(date +%H:%M:%S) ${m}: ${state:-no pod yet} ($(( (SECONDS - start) / 60 )) min)"; last=$SECONDS
      fi
      sleep 10
    done
    [[ " ${FAILED_MODELS} " == *" ${m} "* ]] || ok "${m} serving"
  done
}

restart_failed_models() {  # skip the CrashLoopBackOff back-off after fixing something
  local m state restarted=false
  for m in "${MODELS[@]}"; do
    state=$(model_pod "$m" | awk '{print $2}')
    if [[ "$state" == *CrashLoopBackOff* || "$state" == *Error* ]]; then
      oc rollout restart "deployment/${m}-kserve" -n "$MODELS_NS" >/dev/null && info "restarted ${m} (was ${state}), fresh attempt"
      restarted=true
    fi
  done
  # let the old pod start terminating, so it is not mistaken for the new attempt
  [[ "$restarted" == true ]] && sleep 20
  true
}

wait_modelrefs() {
  local m
  for m in "${MODELS[@]}"; do
    if [[ " ${FAILED_MODELS} " == *" ${m} "* ]]; then
      warn "skipping MaaSModelRef ${m}: its model is not serving"; continue
    fi
    wait_until 600 "MaaSModelRef ${m} Ready (subscription + auth policy paired)" \
      oc wait "maasmodelref/${m}" -n "$MODELS_NS" --for=jsonpath='{.status.phase}'=Ready --timeout=10s || true
  done
}

# ----------------------------------------------------------------------------- observability
csv_succeeded() {  # csv_succeeded <namespace> <csv-name-prefix>
  local out; out=$(oc get csv -n "$1" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null || true)
  grep -Eq "^${2}.* Succeeded$" <<<"$out"
}

install_observability_operators() {
  apply_k "${ROOT_DIR}/observability/operators"
  [[ "$RHOAI_VERSION" == "3.5" ]] && apply_k "${ROOT_DIR}/observability/operators-loki"
  wait_until 600 "Cluster Observability operator ready" csv_succeeded openshift-cluster-observability-operator cluster-observability-operator || true
  wait_until 600 "Tempo operator ready" csv_succeeded openshift-tempo-operator tempo || true
  wait_until 600 "OpenTelemetry operator ready" csv_succeeded openshift-opentelemetry-operator opentelemetry || true
  if [[ "$RHOAI_VERSION" == "3.5" ]]; then
    wait_until 600 "Loki operator ready" csv_succeeded openshift-operators-redhat loki-operator || true
  fi
}

tenant_patch() {  # merge patch on the operator owned MaaS tenant config
  if [[ "$RHOAI_VERSION" == "3.5" ]]; then
    oc patch maastenantconfigs.maas.opendatahub.io default-tenant -n "$MAAS_POLICY_NS" --type=merge -p "$1" >/dev/null
  else
    oc patch tenants.maas.opendatahub.io default-tenant -n "$MAAS_POLICY_NS" --type=merge -p "$1" >/dev/null
  fi
}
tenant_exists() {
  if [[ "$RHOAI_VERSION" == "3.5" ]]; then oc get maastenantconfigs.maas.opendatahub.io default-tenant -n "$MAAS_POLICY_NS"
  else oc get tenants.maas.opendatahub.io default-tenant -n "$MAAS_POLICY_NS"; fi
}
telemetry_ready() {
  [[ -n "$(oc get telemetrypolicies.extensions.kuadrant.io -n openshift-ingress --no-headers 2>/dev/null)" ]]
}
lokistack_ready() {
  # Not "oc wait --for=jsonpath" with a filter: several oc versions never match it even when
  # Ready=True. Read the condition and compare instead.
  [[ "$(oc get lokistack usage -n "$MONITORING_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == *True* ]]
}

diagnose_lokistack() {
  warn "LokiStack 'usage' conditions:"
  oc get lokistack usage -n "$MONITORING_NS" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null | sed 's/^/      /'
  local bad
  bad=$(oc get pods -n "$MONITORING_NS" --no-headers 2>/dev/null | grep -E '^(usage-|minio)' | grep -vE 'Running|Completed' || true)
  [[ -n "$bad" ]] && { warn "Loki / MinIO pods not running:"; sed 's/^/      /' <<<"$bad"; }
  bad=$(oc get pvc -n "$MONITORING_NS" --no-headers 2>/dev/null | grep -v Bound || true)
  [[ -n "$bad" ]] && { warn "unbound PVCs:"; sed 's/^/      /' <<<"$bad"; }
  info "fix, then re-run: ./deploy.sh observability"
}

# Switches on what lives in operator owned objects: gateway telemetry (token metrics
# labelled per model/subscription) and, on 3.5, the logs based usage pipeline.
observability_glue() {
  step "Observability: token metrics + usage dashboards"
  wait_until 600 "DSCI monitoring stack ready" \
    oc wait dsci/default-dsci --for=jsonpath='{.status.phase}'=Ready --timeout=10s || true

  # Gen AI studio Dashboard scrapes vLLM via OTel TA (opendatahub.io/monitoring=true),
  # not UWM (monitoring.opendatahub.io/scrape=true). Ensure the durable PodMonitor exists
  # even when only glue is re-run after models are already up.
  if oc get ns "$MODELS_NS" >/dev/null 2>&1; then
    oc apply -f "${ROOT_DIR}/observability/monitoring/maas-vllm-podmonitor.yaml" >/dev/null \
      && ok "Gen AI Dashboard PodMonitor (maas-vllm-engine) applied in ${MODELS_NS}"
  else
    warn "namespace ${MODELS_NS} missing, skip Gen AI Dashboard PodMonitor"
  fi

  wait_until 300 "MaaS tenant config present" tenant_exists || { warn "cannot enable telemetry, tenant config missing"; return 0; }
  local capture=false; [[ "$CAPTURE_USER" == true ]] && capture=true
  tenant_patch "{\"spec\":{\"telemetry\":{\"enabled\":true,\"metrics\":{\"captureModelUsage\":true,\"captureUser\":${capture}}}}}"
  ok "gateway telemetry enabled (per model + subscription$([[ "$capture" == true ]] && echo " + user"))"
  wait_until 180 "TelemetryPolicy created by the MaaS controller" telemetry_ready || true

  if [[ "$RHOAI_VERSION" == "3.5" ]]; then
    info "LokiStack starts ~8 components with PVCs, this usually takes 3-8 min"
    wait_until 600 "LokiStack ready" lokistack_ready || { diagnose_lokistack; warn "usage logging NOT enabled yet, continuing"; return 0; }
    oc patch configs.maas.opendatahub.io default --type=merge -p '{"spec":{"usageLogging":true}}' >/dev/null \
      && ok "usage logging enabled (per-request tokens -> Loki)"
  fi
}

deploy_observability_oc() {
  step "Observability 1/3: operators (COO, Tempo, OpenTelemetry$([[ "$RHOAI_VERSION" == "3.5" ]] && echo ", Loki"))"
  install_observability_operators
  step "Observability 2/3: RHOAI monitoring stack"
  apply_k "${ROOT_DIR}/observability/monitoring"
  if [[ "$RHOAI_VERSION" == "3.5" ]]; then
    step "Observability 3/3: usage-log store (MinIO + LokiStack)"
    wait_until 300 "LokiStack CRD installed" crd_exists lokistacks.loki.grafana.com || true
    apply_k "${ROOT_DIR}/observability/usage-logs"
  fi
  observability_glue
}

# ----------------------------------------------------------------------------- oc mode
deploy_oc() {
  preflight
  [[ "$WITH_OPERATORS" == true ]] && install_operators
  configure
  bootstrap

  step "Platform 1/5: Kuadrant + Authorino TLS"
  apply_k "${ROOT_DIR}/platform/10-kuadrant"
  apply_k "${ROOT_DIR}/platform/20-authorino-tls"
  # Creating the GatewayClass makes OpenShift install its Gateway API provider,
  # which Kuadrant needs before it reports Ready
  oc apply --server-side --force-conflicts --field-manager=maas-deploy -f "${ROOT_DIR}/platform/30-gateway/gatewayclass.yaml"
  wait_kuadrant

  step "Platform 2/5: Authorino trusts the service CA"
  wait_until 300 "Authorino serving cert issued" oc get secret authorino-server-cert -n kuadrant-system
  authorino_tls_env

  step "Platform 3/5: MaaS gateway"
  apply_k "${ROOT_DIR}/platform/30-gateway"
  wait_until 300 "Gateway programmed" \
    oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=10s || true

  if [[ -z "$POSTGRES_URL" ]]; then
    step "Platform 4/5: PostgreSQL (PoC)"
    apply_k "${ROOT_DIR}/platform/40-postgres"
    wait_until 600 "PostgreSQL ready" oc rollout status deployment/postgres -n "$DB_NS" --timeout=10s
  else
    step "Platform 4/5: PostgreSQL skipped (external database)"
  fi

  step "Platform 5/5: enable MaaS in OpenShift AI ${RHOAI_VERSION}"
  apply_k "${ROOT_DIR}/platform/50-rhoai/rhoai-${RHOAI_VERSION}"
  maas_api_glue
  playground_glue
  sleep 10  # the dashboard operator sometimes resets flags right after enablement
  [[ "$(oc get odhdashboardconfig odh-dashboard-config -n "$RHOAI_APPS_NS" -o jsonpath='{.spec.dashboardConfig.modelAsService}')" == "true" ]] \
    || apply_k "${ROOT_DIR}/platform/50-rhoai/rhoai-${RHOAI_VERSION}"

  step "Models: Gemma 3 270M + Qwen3 0.6B (${ACCELERATOR})"
  apply_k "${ROOT_DIR}/models/overlays/${ACCELERATOR}"

  step "Governance: auth policy + free/premium subscriptions"
  apply_k "${ROOT_DIR}/governance"

  # 3.4: declare the Llama Stack playground (Argo gets the same via the 3.4 platform overlay)
  if [[ "$RHOAI_VERSION" == "3.4" ]] && playground_crds_exist; then
    step "Gen AI playground: LlamaStackDistribution in ai-tenants"
    wait_until 300 "namespace ai-tenants" oc get namespace ai-tenants
    playground_maas_keys
    apply_k "${ROOT_DIR}/platform/60-playground"
  fi

  # runs while the models download
  [[ "$WITH_OBSERVABILITY" == true ]] && deploy_observability_oc

  wait_models
  wait_modelrefs
  done_banner
  [[ -z "$FAILED_MODELS" ]] || die "not serving:${FAILED_MODELS} (details above). Fix, then re-run: ./deploy.sh wait"
}

# ----------------------------------------------------------------------------- argocd mode
deploy_argocd() {
  preflight
  need git
  oc get namespace "$GITOPS_NS" >/dev/null 2>&1 || die "namespace ${GITOPS_NS} not found: install the Red Hat OpenShift GitOps operator first"

  git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "${ROOT_DIR} must be inside a git repository that Argo CD can reach"
  REPO_URL=${REPO_URL:-$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)}
  REVISION=${REVISION:-$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)}
  local repo_path; repo_path=$(git -C "$ROOT_DIR" rev-parse --show-prefix)
  [[ -n "$REPO_URL" ]] || die "no git remote 'origin', pass --repo-url"

  # cluster-params.env must match this cluster AND be pushed, because Argo CD renders from git
  local before; before=$(cat "$PARAMS_FILE" "$PLAYGROUND_PARAMS_FILE" "$OBS_PARAMS_FILE")
  configure
  if [[ "$before" != "$(cat "$PARAMS_FILE" "$PLAYGROUND_PARAMS_FILE" "$OBS_PARAMS_FILE")" ]] || ! git -C "$ROOT_DIR" diff --quiet HEAD -- "$PARAMS_FILE" "$PLAYGROUND_PARAMS_FILE" "$OBS_PARAMS_FILE"; then
    die "cluster-params.env files were updated for this cluster. Commit and push them, then re-run './deploy.sh argocd'"
  fi
  if git -C "$ROOT_DIR" rev-parse '@{u}' >/dev/null 2>&1 && [[ "$(git -C "$ROOT_DIR" rev-list '@{u}..HEAD' --count)" != "0" ]]; then
    die "local commits are not pushed yet, Argo CD would not see them. Run 'git push' first"
  fi
  info "repo ${REPO_URL} @ ${REVISION} path '${repo_path:-/}'"

  bootstrap

  step "Granting Argo CD permissions"
  oc apply -f "${ROOT_DIR}/argocd/rbac.yaml" >/dev/null && ok "ClusterRoleBinding openshift-gitops-maas-cluster-admin"

  step "Creating Argo CD Applications"
  render_apps() {
    sed -e "s#__REPO_URL__#${REPO_URL}#g" -e "s#__REVISION__#${REVISION}#g" -e "s#__REPO_PATH__#${repo_path}#g" \
        -e "s#__RHOAI_VERSION__#${RHOAI_VERSION}#g" -e "s#__ACCELERATOR__#${ACCELERATOR}#g" "$1"
  }
  if [[ "$WITH_OPERATORS" == true ]]; then
    render_apps "${ROOT_DIR}/argocd/operators-application.yaml" | oc apply -f -
  fi
  render_apps "${ROOT_DIR}/argocd/applications.yaml" | oc apply -f -
  [[ "$WITH_OBSERVABILITY" == true ]] && render_apps "${ROOT_DIR}/argocd/observability-application.yaml" | oc apply -f -

  step "Post-sync glue (operator owned objects)"
  wait_platform
  authorino_tls_env
  maas_api_glue
  playground_glue
  [[ "$WITH_OBSERVABILITY" == true ]] && observability_glue
  wait_models
  wait_modelrefs
  [[ -z "$FAILED_MODELS" ]] || warn "not serving:${FAILED_MODELS} (details above). Fix, then re-run: ./deploy.sh wait"
  info "Argo CD console: https://$(oc get route openshift-gitops-server -n "$GITOPS_NS" -o jsonpath='{.spec.host}' 2>/dev/null)"
  done_banner
}

# ----------------------------------------------------------------------------- test
test_models() {
  need oc; need curl; need jq
  local host key models body code m id url
  host=$(param MAAS_HOSTNAME)
  [[ "$host" == *CHANGE-ME* ]] && die "run './deploy.sh configure' first"
  step "Testing MaaS at https://${host}"
  # -k: lab clusters often use the self-signed default ingress cert
  local CURL=(curl -sk --max-time 120)

  key=$("${CURL[@]}" -X POST "https://${host}/maas-api/v1/api-keys" \
      -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
      -d '{"name":"deploy-sh-test","subscription":"small-models-free","expiresIn":"1h"}' | jq -r '.key // empty')
  [[ -n "$key" ]] || die "could not create an API key (check: oc get maassubscription -n ${MAAS_POLICY_NS})"
  ok "API key created (subscription small-models-free, expires in 1h)"

  models=$("${CURL[@]}" "https://${host}/v1/models" -H "Authorization: Bearer ${key}")
  info "models visible to this key: $(jq -r '[.data[].id] | join(", ")' <<<"$models" 2>/dev/null || echo "$models")"

  for m in "${MODELS[@]}"; do
    id=$(jq -r --arg m "$m" '[.data[]?.id | select(endswith($m))][0] // empty' <<<"$models" 2>/dev/null || true)
    id=${id:-$m}
    body=$(jq -n --arg id "$id" '{model:$id, max_tokens:60, messages:[{role:"user", content:"In one sentence: what is OpenShift AI?"}]}')
    url="https://${host}/v1/chat/completions"                         # body based routing
    code=$("${CURL[@]}" -o /tmp/maas-resp.json -w '%{http_code}' "$url" \
      -H "Authorization: Bearer ${key}" -H "Content-Type: application/json" -d "$body")
    if [[ "$code" == "404" ]]; then                                    # path based routing
      url="https://${host}/${MODELS_NS}/${m}/v1/chat/completions"
      body=$(jq --arg m "$m" '.model=$m' <<<"$body")
      code=$("${CURL[@]}" -o /tmp/maas-resp.json -w '%{http_code}' "$url" \
        -H "Authorization: Bearer ${key}" -H "Content-Type: application/json" -d "$body")
    fi
    if [[ "$code" == "200" ]]; then
      ok "${m}: $(jq -r '.choices[0].message.content' /tmp/maas-resp.json | tr '\n' ' ' | cut -c1-160)"
      info "tokens used: $(jq -c '.usage' /tmp/maas-resp.json)"
    else
      warn "${m}: HTTP ${code} from ${url}: $(head -c 300 /tmp/maas-resp.json)"
    fi
  done
  echo
  info "Use it from any OpenAI client:"
  info "  base_url = https://${host}/v1   api_key = <MaaS API key, sk-oai-...>"
}

# ----------------------------------------------------------------------------- usage
# Token consumption straight from the Limitador counters that enforce the subscriptions
# (authorized_hits = tokens, authorized_calls = requests, limited_calls = HTTP 429s),
# labelled by the MaaS TelemetryPolicy.
usage_report() {
  need oc; need curl; need jq
  local host token q
  host=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
  token=$(oc whoami -t)
  step "MaaS usage over the last ${USAGE_WINDOW}"
  prom() {
    curl -sk -G "https://${host}/api/v1/query" -H "Authorization: Bearer ${token}" --data-urlencode "query=$1" \
      | jq -r '.data.result[]? | [(.metric.model // "-"), (.metric.subscription // "-"), (.metric.user // "-"), (.value[1] | tonumber | floor)] | @tsv'
  }
  local by="model, subscription, user"
  {
    printf 'METRIC\tMODEL\tSUBSCRIPTION\tUSER\tVALUE\n'
    for q in authorized_hits:tokens authorized_calls:requests limited_calls:rate-limited; do
      prom "sum by (${by}) (increase(${q%%:*}[${USAGE_WINDOW}]))" | sed "s/^/${q##*:}\t/"
    done
  } | column -t -s $'\t'
  info "Empty? Send some traffic first (./deploy.sh test) and allow ~1 min for scraping."
  info "Dashboards: RHOAI dashboard > Observe & monitor (3.5) / Models as a service > Observability (3.4)"
}

# ----------------------------------------------------------------------------- status / render / destroy
status() {
  need oc
  step "MaaS status"
  oc get datasciencecluster default-dsc -o jsonpath='{"kserve.modelsAsService: "}{.spec.components.kserve.modelsAsService.managementState}{"\naigateway.modelsAsAService: "}{.spec.components.aigateway.modelsAsAService.managementState}{"\n"}' || true
  oc get kuadrant -n kuadrant-system 2>/dev/null || true
  oc get gateway maas-default-gateway -n openshift-ingress 2>/dev/null || true
  oc get tenants.maas.opendatahub.io -n "$MAAS_POLICY_NS" 2>/dev/null || true
  oc get llminferenceservice,maasmodelref -n "$MODELS_NS" -o wide 2>/dev/null || true
  oc get maassubscription,maasauthpolicy -n "$MAAS_POLICY_NS" 2>/dev/null || true
  oc get llamastackdistribution -n ai-tenants 2>/dev/null || true
  oc get pods -n "$MODELS_NS" 2>/dev/null || true
  oc get telemetrypolicies.extensions.kuadrant.io -n openshift-ingress 2>/dev/null || true
  oc get lokistack -n "$MONITORING_NS" 2>/dev/null || true
  oc get persesdashboard -n "$MONITORING_NS" 2>/dev/null || true
  oc get applications.argoproj.io -n "$GITOPS_NS" 2>/dev/null | grep -E 'NAME|maas-' || true
}

render() {
  local k; k=$(command -v kustomize >/dev/null && echo "kustomize build" || echo "oc kustomize")
  local v=${RHOAI_VERSION:-3.4}
  for d in "platform/overlays/rhoai-${v}" "models/overlays/${ACCELERATOR}" governance "observability/overlays/rhoai-${v}"; do
    echo "# ---------------- ${d}"; $k "${ROOT_DIR}/${d}"
  done
}

destroy() {
  need oc
  step "Removing MaaS small models setup"
  if oc get application.argoproj.io maas-platform -n "$GITOPS_NS" >/dev/null 2>&1; then
    oc delete application.argoproj.io maas-observability maas-governance maas-models maas-platform -n "$GITOPS_NS" --ignore-not-found --wait=true
    oc delete application.argoproj.io maas-operators -n "$GITOPS_NS" --ignore-not-found
    oc delete -f "${ROOT_DIR}/argocd/rbac.yaml" --ignore-not-found
  else
    oc delete -k "${ROOT_DIR}/governance" --ignore-not-found
    oc delete -k "${ROOT_DIR}/models/overlays/${ACCELERATOR}" --ignore-not-found --wait=true
    oc delete route maas-default-gateway-https -n openshift-ingress --ignore-not-found
    oc delete gateway maas-default-gateway -n openshift-ingress --ignore-not-found
    oc delete configmap maas-gateway-options -n openshift-ingress --ignore-not-found
    oc delete namespace "$DB_NS" --ignore-not-found
    oc delete lokistack usage -n "$MONITORING_NS" --ignore-not-found
    oc delete deployment/minio service/minio job/minio-create-bucket pvc/minio-data -n "$MONITORING_NS" --ignore-not-found
  fi
  oc delete secret minio-secret -n "$MONITORING_NS" --ignore-not-found
  oc delete secret maas-db-config -n "$RHOAI_APPS_NS" --ignore-not-found
  oc delete namespace "$MODELS_NS" --ignore-not-found
  if [[ "$DISABLE_MAAS" == true ]]; then
    preflight
    if [[ "$RHOAI_VERSION" == "3.4" ]]; then
      oc patch datasciencecluster default-dsc --type=merge -p '{"spec":{"components":{"kserve":{"modelsAsService":{"managementState":"Removed"}}}}}'
    else
      oc patch datasciencecluster default-dsc --type=merge -p '{"spec":{"components":{"aigateway":{"modelsAsAService":{"managementState":"Removed"}}}}}'
    fi
    ok "MaaS set to Removed in default-dsc"
  fi
  info "Kept on purpose (possibly shared): Kuadrant instance, GatewayClass openshift-default, Authorino TLS"
  info "settings, observability operators and the DSCI monitoring stack"
}

done_banner() {
  echo
  step "Done"
  info "Endpoint : https://$(param MAAS_HOSTNAME)/v1"
  info "Test     : ./deploy.sh test"
  info "API keys : RHOAI dashboard > Gen AI studio > API keys, or POST /maas-api/v1/api-keys"
  info "Premium  : oc adm groups add-users maas-premium-users <user>"
  info "Playground: RHOAI dashboard > Gen AI studio > Playground (project ai-tenants; declared in platform/60-playground)"
  [[ "$WITH_OBSERVABILITY" == true ]] && info "Usage    : ./deploy.sh usage   (dashboards: RHOAI dashboard > Observe & monitor)"
  true
}

# ----------------------------------------------------------------------------- main
[[ $# -ge 1 ]] || usage 1
CMD=$1; shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --rhoai-version) RHOAI_VERSION=$2; shift 2 ;;
    --accelerator)   ACCELERATOR=$2; shift 2 ;;
    --with-operators) WITH_OPERATORS=true; shift ;;
    --postgres-url)  POSTGRES_URL=$2; shift 2 ;;
    --repo-url)      REPO_URL=$2; shift 2 ;;
    --revision)      REVISION=$2; shift 2 ;;
    --disable-maas)  DISABLE_MAAS=true; shift ;;
    --no-observability) WITH_OBSERVABILITY=false; shift ;;
    --capture-user)  CAPTURE_USER=true; shift ;;
    --model-timeout) MODEL_TIMEOUT_MIN=$2; shift 2 ;;
    --window)        USAGE_WINDOW=$2; shift 2 ;;
    -h|--help)       usage 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ "$ACCELERATOR" == "cpu" || "$ACCELERATOR" == "gpu" ]] || die "--accelerator must be cpu or gpu"

case $CMD in
  configure) need oc; configure ;;
  oc)        deploy_oc ;;
  argocd)    deploy_argocd ;;
  test)      test_models ;;
  wait)      need oc; wait_models; wait_modelrefs; [[ -z "$FAILED_MODELS" ]] || exit 1 ;;
  usage)     usage_report ;;
  observability) preflight; configure; bootstrap; deploy_observability_oc ;;
  playground) preflight; enable_playground ;;
  hf-check)  hf_check_cmd ;;
  status)    status ;;
  render)    render ;;
  destroy)   destroy ;;
  -h|--help|help) usage 0 ;;
  *) usage 1 ;;
esac

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
#   --disable-maas            (destroy) Also set MaaS to Removed in the DataScienceCluster
#
# Environment
#   HF_TOKEN   Hugging Face token of an account that accepted the Gemma license
# =============================================================================
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS_FILE="${ROOT_DIR}/platform/30-gateway/cluster-params.env"

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

# ----------------------------------------------------------------------------- logging
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step() { echo "${B}==> $*${N}"; }
info() { echo "    $*"; }
ok()   { echo "    ${G}OK${N} $*"; }
warn() { echo "    ${Y}WARN${N} $*" >&2; }
die()  { echo "${R}ERROR${N} $*" >&2; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ----------------------------------------------------------------------------- helpers
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }

# wait_until <timeout-seconds> <description> <command...>
wait_until() {
  local timeout=$1 desc=$2; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start >= timeout )) && { warn "timed out after ${timeout}s waiting for: ${desc}"; return 1; }
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
  local ns
  for ns in "$GATEWAY_INFRA_NS_35" "$RHOAI_APPS_NS"; do
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
EOF
  ok "MAAS_HOSTNAME=${host}"
  ok "TLS_SECRET_NAME=${cert} (wildcard *.${domain} cert served by the gateway)"
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
    ok "secret ${MODELS_NS}/hf-token already present"
  else
    die "HF_TOKEN is not set. google/gemma-3-270m-it is gated: accept the license on huggingface.co, then export HF_TOKEN=hf_..."
  fi

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

# ----------------------------------------------------------------------------- glue
# Steps that touch operator owned objects or namespaces that only exist later.
authorino_tls_env() {
  wait_until 300 "Authorino deployment exists" oc get deployment authorino -n kuadrant-system
  if oc get deployment authorino -n kuadrant-system -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -q SSL_CERT_FILE; then
    ok "Authorino trusts the service CA"
  else
    oc -n kuadrant-system set env deployment/authorino \
      SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
      REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt >/dev/null
    ok "Authorino configured to trust the service CA"
  fi
}

maas_api_glue() {
  wait_until 600 "MaaS CRDs installed" crd_exists maasmodelrefs.maas.opendatahub.io
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

# KServe storage-initializer can hang on the Hugging Face Xet protocol; fall back to HTTP.
xet_workaround() {
  local m=$1 dep="${1}-kserve"
  oc get deployment "$dep" -n "$MODELS_NS" >/dev/null 2>&1 || return 0
  oc get deployment "$dep" -n "$MODELS_NS" -o jsonpath='{.spec.template.spec.initContainers[0].env}' 2>/dev/null \
    | grep -q HF_HUB_DISABLE_XET && return 0
  if oc get pods -n "$MODELS_NS" --no-headers 2>/dev/null | grep "^${dep}" | grep -q 'Init:0/1'; then
    warn "${m}: storage-initializer still downloading after 5 min, applying HF_HUB_DISABLE_XET=1"
    oc patch deployment "$dep" -n "$MODELS_NS" --type=json \
      -p '[{"op":"add","path":"/spec/template/spec/initContainers/0/env/-","value":{"name":"HF_HUB_DISABLE_XET","value":"1"}}]' >/dev/null || true
  fi
}

wait_models() {
  step "Waiting for models (image pull + download + load can take 5-15 min)"
  local m start=$SECONDS patched=false
  for m in "${MODELS[@]}"; do
    until oc wait "llminferenceservice/${m}" -n "$MODELS_NS" --for=condition=Ready --timeout=20s >/dev/null 2>&1; do
      if (( SECONDS - start > 300 )) && [[ "$patched" == false ]]; then
        for x in "${MODELS[@]}"; do xet_workaround "$x"; done
        patched=true
      fi
      (( SECONDS - start > 1800 )) && { warn "${m} not Ready after 30 min: oc describe llminferenceservice ${m} -n ${MODELS_NS}"; break; }
      sleep 10
    done
    oc wait "llminferenceservice/${m}" -n "$MODELS_NS" --for=condition=Ready --timeout=1s >/dev/null 2>&1 && ok "${m} serving"
  done
}

wait_modelrefs() {
  local m
  for m in "${MODELS[@]}"; do
    wait_until 600 "MaaSModelRef ${m} Ready (subscription + auth policy paired)" \
      oc wait "maasmodelref/${m}" -n "$MODELS_NS" --for=jsonpath='{.status.phase}'=Ready --timeout=10s || true
  done
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
  sleep 10  # the dashboard operator sometimes resets flags right after enablement
  [[ "$(oc get odhdashboardconfig odh-dashboard-config -n "$RHOAI_APPS_NS" -o jsonpath='{.spec.dashboardConfig.modelAsService}')" == "true" ]] \
    || apply_k "${ROOT_DIR}/platform/50-rhoai/rhoai-${RHOAI_VERSION}"

  step "Models: Gemma 3 270M + Qwen3 0.6B (${ACCELERATOR})"
  apply_k "${ROOT_DIR}/models/overlays/${ACCELERATOR}"

  step "Governance: auth policy + free/premium subscriptions"
  apply_k "${ROOT_DIR}/governance"

  wait_models
  wait_modelrefs
  done_banner
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
  local before; before=$(cat "$PARAMS_FILE")
  configure
  if [[ "$before" != "$(cat "$PARAMS_FILE")" ]] || ! git -C "$ROOT_DIR" diff --quiet HEAD -- "$PARAMS_FILE"; then
    die "platform/30-gateway/cluster-params.env was updated for this cluster. Commit and push it, then re-run './deploy.sh argocd'"
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

  step "Post-sync glue (operator owned objects)"
  wait_platform
  authorino_tls_env
  maas_api_glue
  wait_models
  wait_modelrefs
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
  oc get pods -n "$MODELS_NS" 2>/dev/null || true
  oc get applications.argoproj.io -n "$GITOPS_NS" 2>/dev/null | grep -E 'NAME|maas-' || true
}

render() {
  local k; k=$(command -v kustomize >/dev/null && echo "kustomize build" || echo "oc kustomize")
  local v=${RHOAI_VERSION:-3.4}
  for d in "platform/overlays/rhoai-${v}" "models/overlays/${ACCELERATOR}" governance; do
    echo "# ---------------- ${d}"; $k "${ROOT_DIR}/${d}"
  done
}

destroy() {
  need oc
  step "Removing MaaS small models setup"
  if oc get application.argoproj.io maas-platform -n "$GITOPS_NS" >/dev/null 2>&1; then
    oc delete application.argoproj.io maas-governance maas-models maas-platform -n "$GITOPS_NS" --ignore-not-found --wait=true
    oc delete application.argoproj.io maas-operators -n "$GITOPS_NS" --ignore-not-found
    oc delete -f "${ROOT_DIR}/argocd/rbac.yaml" --ignore-not-found
  else
    oc delete -k "${ROOT_DIR}/governance" --ignore-not-found
    oc delete -k "${ROOT_DIR}/models/overlays/${ACCELERATOR}" --ignore-not-found --wait=true
    oc delete route maas-default-gateway-https -n openshift-ingress --ignore-not-found
    oc delete gateway maas-default-gateway -n openshift-ingress --ignore-not-found
    oc delete configmap maas-gateway-options -n openshift-ingress --ignore-not-found
    oc delete namespace "$DB_NS" --ignore-not-found
  fi
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
  info "Kept on purpose (possibly shared): Kuadrant instance, GatewayClass openshift-default, Authorino TLS settings"
}

done_banner() {
  echo
  step "Done"
  info "Endpoint : https://$(param MAAS_HOSTNAME)/v1"
  info "Test     : ./deploy.sh test"
  info "API keys : RHOAI dashboard > Gen AI studio > API keys, or POST /maas-api/v1/api-keys"
  info "Premium  : oc adm groups add-users maas-premium-users <user>"
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
  status)    status ;;
  render)    render ;;
  destroy)   destroy ;;
  -h|--help|help) usage 0 ;;
  *) usage 1 ;;
esac

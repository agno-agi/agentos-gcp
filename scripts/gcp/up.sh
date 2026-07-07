#!/bin/bash

############################################################################
#
#    Agno Google Cloud Setup (first-time provisioning)
#
#    Usage:     ./scripts/gcp/up.sh
#    Redeploy:  ./scripts/gcp/redeploy.sh
#    Sync env:  ./scripts/gcp/env-sync.sh
#    Teardown:  ./scripts/gcp/down.sh
#
#    Prerequisites:
#      - gcloud CLI installed and authenticated (`gcloud auth login`)
#      - A project selected (`gcloud config set project <id>`) with billing
#      - Docker running (the image is built locally and pushed)
#      - OPENAI_API_KEY set in environment (or .env / .env.production)
#
#    Provisions: Artifact Registry repo, Cloud SQL Postgres 17 (private IP,
#    pgvector via the app's CREATE EXTENSION), Secret Manager secrets, and
#    a Cloud Run service at 2 vCPU / 4 GiB with min 1 always-on instance.
#
#    Overrides: GCP_PROJECT_ID (default: current gcloud project),
#               GCP_REGION (default: us-central1)
#
############################################################################

set -e

# Colors
ORANGE='\033[38;5;208m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${ORANGE}"
cat << 'BANNER'
     █████╗  ██████╗ ███╗   ██╗ ██████╗
    ██╔══██╗██╔════╝ ████╗  ██║██╔═══██╗
    ███████║██║  ███╗██╔██╗ ██║██║   ██║
    ██╔══██║██║   ██║██║╚██╗██║██║   ██║
    ██║  ██║╚██████╔╝██║ ╚████║╚██████╔╝
    ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝
BANNER
echo -e "${NC}"

# Persist a resolved single-line value back into the env file so it stays a
# faithful record of the deploy (and env-sync.sh keeps managing it). Replaces
# an existing commented-or-uncommented `KEY=` line in place; appends if the key
# is absent. Rewrites via the original file (not `mv`) so the file keeps its
# inode + permissions. The `|` sed delimiter avoids clashing with URL slashes.
# No-op when the file is missing.
persist_env_var() {
    local key="$1" value="$2" file="$3" tmp
    [[ -z "$file" || ! -f "$file" ]] && return
    if grep -qE "^[#[:space:]]*${key}=" "$file"; then
        tmp="$(mktemp)"
        if sed -E "s|^[#[:space:]]*${key}=.*|${key}=${value}|" "$file" > "$tmp"; then
            cat "$tmp" > "$file"
        fi
        rm -f "$tmp"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# Persist a multi-line env value. Existing active KEY= blocks are removed before
# appending the new value; commented examples are left alone as documentation.
# The value is written quoted, matching example.env's documented PEM form so
# every parser (docker compose env_file included) reads it as one value.
persist_multiline_env_var() {
    local key="$1" value="$2" file="$3" tmp line skipping=0 value_part
    [[ -z "$file" ]] && return
    if [[ ! -f "$file" ]]; then
        printf '%s="%s"\n' "$key" "$value" > "$file"
        return
    fi

    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$skipping" == 1 ]]; then
            [[ "$line" == *"-----END"* ]] && skipping=0
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then
            value_part="${line#*=}"
            if [[ "$value_part" == *"-----BEGIN"* && "$value_part" != *"-----END"* ]]; then
                skipping=1
            fi
            continue
        fi

        printf '%s\n' "$line" >> "$tmp"
    done < "$file"

    [[ -s "$tmp" ]] && printf '\n' >> "$tmp"
    printf '%s="%s"\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Load env file — .env.production preferred, .env as fallback.
# Parsed line-by-line (not `source`d) so an unquoted multi-line PEM
# JWT_VERIFICATION_KEY isn't interpreted as shell. Mirrors the parser in
# env-sync.sh so both scripts read .env files identically. A function so
# the JWT pause below can re-read the file after the user edits it.
load_env_file() {
    local line current_key="" current_value=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$current_key" ]]; then
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        fi

        if [[ -z "$current_key" ]]; then
            current_key="${line%%=*}"
            current_value="${line#*=}"
        else
            current_value="${current_value}
${line}"
        fi

        # Still inside a PEM block — keep accumulating lines.
        if [[ "$current_value" == *"-----BEGIN"* && "$current_value" != *"-----END"* ]]; then
            continue
        fi

        # Strip surrounding quotes if present
        current_value="${current_value#\"}"
        current_value="${current_value%\"}"
        current_value="${current_value#\'}"
        current_value="${current_value%\'}"

        export "${current_key}=${current_value}"

        current_key=""
        current_value=""
    done < "$1"
}

# shellcheck disable=SC2034 # helper reused verbatim from the agentos-railway scripts
capture_pasted_jwt_verification_key() {
    local first_line="$1" line pasted="$1"

    pasted="${pasted#export JWT_VERIFICATION_KEY=}"
    pasted="${pasted#JWT_VERIFICATION_KEY=}"
    [[ "$pasted" != *"-----BEGIN"* ]] && return 1

    while [[ "$pasted" != *"-----END"* ]]; do
        if ! IFS= read -r line; then
            break
        fi
        pasted="${pasted}
${line}"
    done

    [[ "$pasted" != *"-----BEGIN"* || "$pasted" != *"-----END"* ]] && return 1

    pasted="${pasted#\"}"
    pasted="${pasted%\"}"
    pasted="${pasted#\'}"
    pasted="${pasted%\'}"

    JWT_VERIFICATION_KEY="$pasted"
    export JWT_VERIFICATION_KEY
}

# Create-or-update a Secret Manager secret from stdin, and let the runtime
# service account read it. Usage: put_secret <name> <value>
put_secret() {
    local name="$1" value="$2"
    if gcloud secrets describe "$name" --project "$PROJECT_ID" &> /dev/null; then
        printf '%s' "$value" | gcloud secrets versions add "$name" \
            --project "$PROJECT_ID" --data-file=- > /dev/null
    else
        printf '%s' "$value" | gcloud secrets create "$name" \
            --project "$PROJECT_ID" --replication-policy=automatic --data-file=- > /dev/null
    fi
    gcloud secrets add-iam-policy-binding "$name" \
        --project "$PROJECT_ID" \
        --member "serviceAccount:${RUNTIME_SA}" \
        --role roles/secretmanager.secretAccessor > /dev/null
}

ENV_FILE=""
[[ -f .env.production ]] && ENV_FILE=".env.production"
[[ -z "$ENV_FILE" && -f .env ]] && ENV_FILE=".env"

if [[ -n "$ENV_FILE" ]]; then
    load_env_file "$ENV_FILE"
    echo -e "${DIM}Loaded ${ENV_FILE}${NC}"
fi

# Preflight
if ! command -v gcloud &> /dev/null; then
    echo "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
    echo "Docker not running. The image is built locally and pushed to Artifact Registry."
    exit 1
fi

if [[ -z "$OPENAI_API_KEY" ]]; then
    echo "OPENAI_API_KEY not set. Add to .env (or .env.production) or export it."
    exit 1
fi

PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2> /dev/null)}"
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo "No GCP project set. Run: gcloud config set project <id>  (or export GCP_PROJECT_ID)"
    exit 1
fi

if ! gcloud auth print-access-token &> /dev/null; then
    echo "gcloud is not authenticated. Run: gcloud auth login"
    exit 1
fi

if ! gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2> /dev/null | grep -q True; then
    echo -e "${DIM}Warning: couldn't confirm billing is enabled on ${PROJECT_ID} — Cloud SQL/Run creation will fail without it.${NC}"
fi

REGION="${GCP_REGION:-us-central1}"
SERVICE_NAME="agent-os"
SQL_INSTANCE="agentos-db"
AR_REPO="agentos"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:latest"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
RUNTIME_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo ""
echo -e "${BOLD}Project ${PROJECT_ID}, region ${REGION}${NC}"

echo ""
echo -e "${BOLD}Enabling APIs (no-op if already on)...${NC}"
gcloud services enable \
    run.googleapis.com \
    sqladmin.googleapis.com \
    secretmanager.googleapis.com \
    artifactregistry.googleapis.com \
    servicenetworking.googleapis.com \
    compute.googleapis.com \
    --project "$PROJECT_ID"

echo ""
echo -e "${BOLD}Creating Artifact Registry repo...${NC}"
# Describe-guard + retry — replaces a bare
# `create … 2>/dev/null || echo "Repo already exists"`, which had two bugs:
#   1) Masking: `|| echo` mapped ANY create failure to a benign "already exists"
#      message, so set -e never fired and the run died far downstream at
#      `docker push` with a cryptic "Repository not found".
#   2) Propagation race: the create can be rejected in the seconds right after
#      `gcloud services enable artifactregistry.googleapis.com` (the freshly
#      enabled API isn't consistent yet) — a short retry rides it out.
# Only skip when the repo genuinely exists; a real create error aborts (set -e).
if gcloud artifacts repositories describe "$AR_REPO" \
    --project "$PROJECT_ID" --location "$REGION" &> /dev/null; then
    echo -e "${DIM}Repo already exists${NC}"
else
    for attempt in 1 2 3 4 5; do
        if gcloud artifacts repositories create "$AR_REPO" \
            --project "$PROJECT_ID" --repository-format=docker --location "$REGION"; then
            break
        fi
        # A concurrent create — or the API just becoming consistent — may have
        # made it exist between attempts; accept that and move on.
        if gcloud artifacts repositories describe "$AR_REPO" \
            --project "$PROJECT_ID" --location "$REGION" &> /dev/null; then
            break
        fi
        if [[ "$attempt" -eq 5 ]]; then
            echo "Failed to create Artifact Registry repo '${AR_REPO}' after 5 attempts." >&2
            exit 1
        fi
        echo -e "${DIM}Repo create failed (artifactregistry API may still be enabling) — retry ${attempt}/5 in 15s...${NC}"
        sleep 15
    done
fi
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

echo ""
echo -e "${BOLD}Building and pushing image (linux/amd64)...${NC}"
echo ""
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"

echo ""
echo -e "${BOLD}Setting up private networking for Cloud SQL...${NC}"
echo -e "${DIM}One-time per VPC; the peering step can take ~5 minutes on first run.${NC}"
gcloud compute addresses create google-managed-services-default \
    --project "$PROJECT_ID" \
    --global --purpose=VPC_PEERING --prefix-length=16 \
    --network=default 2> /dev/null || echo -e "${DIM}Peering range already allocated${NC}"
gcloud services vpc-peerings connect \
    --project "$PROJECT_ID" \
    --service=servicenetworking.googleapis.com \
    --ranges=google-managed-services-default \
    --network=default 2> /dev/null || echo -e "${DIM}Peering already connected${NC}"

echo ""
echo -e "${BOLD}Creating Cloud SQL Postgres 17 (private IP)...${NC}"
echo -e "${DIM}--edition=enterprise is load-bearing: PG16+ defaults to Enterprise Plus,${NC}"
echo -e "${DIM}whose cheapest machines cost hundreds of \$/mo; the shared-core db-g1-small${NC}"
echo -e "${DIM}(~\$25-35/mo) exists only in Enterprise. Takes 5-10 minutes.${NC}"
echo ""
if gcloud sql instances describe "$SQL_INSTANCE" --project "$PROJECT_ID" &> /dev/null; then
    echo -e "${DIM}Instance ${SQL_INSTANCE} already exists — reusing${NC}"
else
    gcloud sql instances create "$SQL_INSTANCE" \
        --project "$PROJECT_ID" \
        --database-version=POSTGRES_17 \
        --edition=enterprise \
        --tier=db-g1-small \
        --region "$REGION" \
        --network=default \
        --no-assign-ip
fi
gcloud sql databases create ai --instance "$SQL_INSTANCE" --project "$PROJECT_ID" 2> /dev/null \
    || echo -e "${DIM}Database ai already exists${NC}"
# Generate a password only when creating the user. Rotating on every run
# would strand the live service on the old password in the window between
# set-password and the deploy that ships the new secret version.
DB_PASSWORD=""
if gcloud sql users list --instance "$SQL_INSTANCE" --project "$PROJECT_ID" --format='value(name)' | grep -qx ai; then
    echo -e "${DIM}Existing DB user ai — password unchanged (rotate manually if needed)${NC}"
else
    DB_PASSWORD="$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24)"
    gcloud sql users create ai --instance "$SQL_INSTANCE" --project "$PROJECT_ID" --password "$DB_PASSWORD"
fi
DB_PRIVATE_IP="$(gcloud sql instances describe "$SQL_INSTANCE" --project "$PROJECT_ID" \
    --format='value(ipAddresses[0].ipAddress)')"
echo -e "${DIM}Cloud SQL private IP: ${DB_PRIVATE_IP}${NC}"

echo ""
echo -e "${BOLD}Storing secrets in Secret Manager...${NC}"
put_secret openai-api-key "$OPENAI_API_KEY"
# db-pass only gets a new version when the user was just created; on the
# reuse path the secret from the first run keeps serving the live service.
[[ -n "$DB_PASSWORD" ]] && put_secret db-pass "$DB_PASSWORD"
SET_SECRETS="OPENAI_API_KEY=openai-api-key:latest,DB_PASS=db-pass:latest"
if [[ -n "$PARALLEL_API_KEY" ]]; then
    put_secret parallel-api-key "$PARALLEL_API_KEY"
    SET_SECRETS="${SET_SECRETS},PARALLEL_API_KEY=parallel-api-key:latest"
fi
if [[ -n "$SLACK_BOT_TOKEN" ]]; then
    put_secret slack-bot-token "$SLACK_BOT_TOKEN"
    SET_SECRETS="${SET_SECRETS},SLACK_BOT_TOKEN=slack-bot-token:latest"
fi
if [[ -n "$SLACK_SIGNING_SECRET" ]]; then
    put_secret slack-signing-secret "$SLACK_SIGNING_SECRET"
    SET_SECRETS="${SET_SECRETS},SLACK_SIGNING_SECRET=slack-signing-secret:latest"
fi
echo -e "${DIM}Secrets stored + readable by ${RUNTIME_SA}${NC}"

# Non-secret env for the service. Direct VPC egress (network/subnet flags)
# keeps the DB connection plain TCP to the private IP — db/url.py builds the
# URL from these discrete DB_* vars.
ENV_VARS="DB_HOST=${DB_PRIVATE_IP},DB_PORT=5432,DB_USER=ai,DB_DATABASE=ai,DB_DRIVER=postgresql+psycopg,WAIT_FOR_DB=True"
[[ -n "$RUNTIME_ENV" ]] && ENV_VARS="${ENV_VARS},RUNTIME_ENV=${RUNTIME_ENV}"

echo ""
echo -e "${BOLD}Deploying to Cloud Run...${NC}"
echo -e "${DIM}--no-cpu-throttling is load-bearing: with request-based billing, idle CPU${NC}"
echo -e "${DIM}is throttled and the in-process scheduler + MCP streams die quietly.${NC}"
echo ""
# --set-env-vars/--set-secrets are replace-all: on an existing service they
# would silently drop everything env-sync.sh pushed since the first deploy.
# Re-runs therefore switch to the merge forms (--update-*); first runs keep
# the --set-* forms, where the two are identical because nothing exists yet.
if gcloud run services describe "$SERVICE_NAME" --project "$PROJECT_ID" --region "$REGION" \
    --format 'value(metadata.name)' &> /dev/null; then
    DEPLOY_ENV_ARGS=(--update-secrets "$SET_SECRETS" --update-env-vars "$ENV_VARS")
else
    DEPLOY_ENV_ARGS=(--set-secrets "$SET_SECRETS" --set-env-vars "$ENV_VARS")
fi
gcloud run deploy "$SERVICE_NAME" \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    --image "$IMAGE" \
    --port 8000 \
    --cpu 2 \
    --memory 4Gi \
    --min-instances 1 \
    --no-cpu-throttling \
    --allow-unauthenticated \
    --network default \
    --subnet default \
    --vpc-egress private-ranges-only \
    "${DEPLOY_ENV_ARGS[@]}"

APP_URL="$(gcloud run services describe "$SERVICE_NAME" \
    --project "$PROJECT_ID" --region "$REGION" --format='value(status.url)')"

# --allow-unauthenticated adds allUsers as run.invoker. Under a Domain Restricted
# Sharing org policy (constraints/iam.allowedPolicyMemberDomains) that binding is
# silently rejected — gcloud only prints a warning, the deploy still "succeeds",
# and the service ships PRIVATE: every unauthenticated request gets HTTP 403.
# Detect it and say so loudly instead of finishing with a misleading "Done".
# Read the policy once. Only warn when the read SUCCEEDED but allUsers is absent
# — otherwise a transient IAM read failure (or a caller lacking
# run.services.getIamPolicy) would cry wolf on a service that is actually public.
if IAM_MEMBERS="$(gcloud run services get-iam-policy "$SERVICE_NAME" \
    --project "$PROJECT_ID" --region "$REGION" \
    --format='value(bindings.members)' 2> /dev/null)" \
    && ! grep -q 'allUsers' <<< "$IAM_MEMBERS"; then
    echo ""
    echo -e "${BOLD}Warning: the service is NOT publicly reachable.${NC}"
    echo -e "${DIM}  --allow-unauthenticated could not grant allUsers run.invoker — this${NC}"
    echo -e "${DIM}  project's org likely enforces Domain Restricted Sharing${NC}"
    echo -e "${DIM}  (constraints/iam.allowedPolicyMemberDomains). Unauthenticated requests${NC}"
    echo -e "${DIM}  get HTTP 403. To expose the service, grant run.invoker to specific${NC}"
    echo -e "${DIM}  principals, or ask an org admin for an allUsers exception:${NC}"
    echo -e "${DIM}    gcloud run services add-iam-policy-binding ${SERVICE_NAME} --region ${REGION} \\${NC}"
    echo -e "${DIM}      --member=user:YOU@YOUR-DOMAIN --role=roles/run.invoker${NC}"
fi

AUTH_REQUIRES_JWT=1
[[ "${RUNTIME_ENV:-prd}" == "dev" ]] && AUTH_REQUIRES_JWT=""

# JWT auth is on in prd and the app refuses to serve without either a PEM
# verification key or a JWKS file. Now that the URL exists, the user can
# mint the key against it before the AGENTOS_URL revision below.
if [[ -n "$AUTH_REQUIRES_JWT" && -z "$JWT_VERIFICATION_KEY" && -z "$JWT_JWKS_FILE" && -t 0 ]]; then
    echo ""
    echo -e "${BOLD}JWT_VERIFICATION_KEY not set${NC} — AgentOS won't serve production traffic without auth."
    echo -e "  1. Open ${BOLD}https://os.agno.com${NC} -> Connect OS -> Live -> enter ${APP_URL:-your Cloud Run URL}"
    echo -e "  2. Name it ${BOLD}Live AgentOS${NC}"
    echo -e "  3. Note: Live AgentOS Connections are a paid feature; use ${BOLD}PLATFORM30${NC} to get 1 month off"
    echo -e "  4. Go to Settings -> OS & Security -> turn ${BOLD}Token-Based Authorization (JWT)${NC} on"
    echo -e "  5. Copy the public key"
    echo -e "  6. Paste the full PEM block at the prompt below, or save it in ${ENV_FILE:-.env.production}"
    echo -e "     Or set JWT_JWKS_FILE if you mount a JWKS file in the image."
    echo ""
    echo -e "  Paste JWT_VERIFICATION_KEY now, or press Enter after saving it:"
    JWT_INPUT=""
    IFS= read -r JWT_INPUT || true
    if [[ -n "$JWT_INPUT" ]]; then
        if capture_pasted_jwt_verification_key "$JWT_INPUT"; then
            ENV_FILE="${ENV_FILE:-.env.production}"
            persist_multiline_env_var JWT_VERIFICATION_KEY "$JWT_VERIFICATION_KEY" "$ENV_FILE"
            echo -e "${DIM}  Saved JWT_VERIFICATION_KEY to ${ENV_FILE}${NC}"
        else
            echo -e "${BOLD}Warning:${NC} couldn't parse the pasted JWT_VERIFICATION_KEY."
            echo -e "${DIM}  Save it to ${ENV_FILE:-.env.production} and run ./scripts/gcp/env-sync.sh if auth is still missing.${NC}"
        fi
    else
        [[ -f .env.production ]] && ENV_FILE=".env.production"
        [[ -z "$ENV_FILE" && -f .env ]] && ENV_FILE=".env"
    fi
    [[ -n "$ENV_FILE" ]] && load_env_file "$ENV_FILE"
fi

JWT_UPDATE_ARGS=()
if [[ -n "$JWT_VERIFICATION_KEY" ]]; then
    echo ""
    echo -e "${DIM}Storing JWT_VERIFICATION_KEY in Secret Manager${NC}"
    put_secret jwt-verification-key "$JWT_VERIFICATION_KEY"
    JWT_UPDATE_ARGS=(--update-secrets "JWT_VERIFICATION_KEY=jwt-verification-key:latest")
elif [[ -n "$JWT_JWKS_FILE" ]]; then
    JWT_UPDATE_ARGS=(--update-env-vars "JWT_JWKS_FILE=${JWT_JWKS_FILE}")
elif [[ -n "$AUTH_REQUIRES_JWT" ]]; then
    echo ""
    echo -e "${DIM}Deployed without JWT auth config — the app will refuse traffic until${NC}"
    echo -e "${DIM}you add JWT_VERIFICATION_KEY or JWT_JWKS_FILE to ${ENV_FILE:-.env.production} and run ./scripts/gcp/env-sync.sh.${NC}"
fi

# The scheduler reaches AgentOS over its public URL. Without AGENTOS_URL it
# defaults to http://127.0.0.1:8000, so scheduled jobs silently never fire in
# prod. Cloud Run only reveals the URL after the first deploy, so this is a
# second revision; the JWT key (when present) rides along in the same update.
if [[ -n "$APP_URL" ]]; then
    echo ""
    echo -e "${BOLD}Setting AGENTOS_URL (revision 2)...${NC}"
    gcloud run services update "$SERVICE_NAME" \
        --project "$PROJECT_ID" \
        --region "$REGION" \
        --update-env-vars "AGENTOS_URL=${APP_URL}" \
        "${JWT_UPDATE_ARGS[@]}"
    persist_env_var AGENTOS_URL "$APP_URL" "$ENV_FILE"
    echo -e "${DIM}Set AGENTOS_URL=${APP_URL} (Cloud Run${ENV_FILE:+ + ${ENV_FILE}})${NC}"
else
    echo -e "${BOLD}Warning:${NC} couldn't resolve the Cloud Run URL, so AGENTOS_URL is unset."
    echo -e "${DIM}  Scheduled jobs won't reach AgentOS until you set it:${NC}"
    echo -e "${DIM}  gcloud run services update ${SERVICE_NAME} --region ${REGION} --update-env-vars AGENTOS_URL=https://<url>${NC}"
fi

# Record the deploy region in the env file so down.sh targets the right
# region even in a shell where GCP_REGION isn't exported.
persist_env_var GCP_REGION "$REGION" "$ENV_FILE"

echo ""
echo -e "${BOLD}Done.${NC}"
echo -e "${DIM}URL:            ${APP_URL}${NC}"
echo -e "${DIM}Logs:           gcloud run services logs read ${SERVICE_NAME} --limit 100 --project ${PROJECT_ID} --region ${REGION}${NC}"
echo -e "${DIM}Sync env vars:  ./scripts/gcp/env-sync.sh  (defaults to .env.production)${NC}"
echo -e "${DIM}Teardown:       ./scripts/gcp/down.sh${NC}"
echo -e "${DIM}Cost:           ~\$110/mo Cloud Run (2 vCPU/4GiB always-on, list) + ~\$25-35/mo${NC}"
echo -e "${DIM}                Cloud SQL db-g1-small — see the README cost note for the budget knob.${NC}"
echo ""

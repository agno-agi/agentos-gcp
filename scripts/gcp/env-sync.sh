#!/bin/bash

############################################################################
#
#    Agno Google Cloud Environment Sync
#
#    Usage:
#      ./scripts/gcp/env-sync.sh             # syncs .env.production
#      ./scripts/gcp/env-sync.sh .env        # syncs .env instead
#
#    Reads the file and pushes every variable to the Cloud Run service in
#    one update (one new revision). Secret-shaped keys (API keys, DB_PASS,
#    JWT_VERIFICATION_KEY, Slack credentials) go to Secret Manager; the
#    rest become plain env vars. Multi-line values (e.g. PEM-formatted
#    JWT_VERIFICATION_KEY) are handled correctly.
#
#    Overrides: GCP_PROJECT_ID (default: current gcloud project),
#               GCP_REGION (default: us-central1)
#
############################################################################

set -e

# Colors
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

ENV_FILE="${1:-.env.production}"
SERVICE_NAME="agent-os"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "File not found: $ENV_FILE"
    echo "Usage: $0 [path/to/env] (default: .env.production)"
    exit 1
fi

if ! command -v gcloud &> /dev/null; then
    echo "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2> /dev/null)}"
REGION="${GCP_REGION:-us-central1}"
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo "No GCP project set. Run: gcloud config set project <id>  (or export GCP_PROJECT_ID)"
    exit 1
fi

if ! gcloud run services describe "$SERVICE_NAME" --project "$PROJECT_ID" --region "$REGION" &> /dev/null; then
    echo "Cloud Run service ${SERVICE_NAME} not found in ${PROJECT_ID}/${REGION}. Run ./scripts/gcp/up.sh first."
    exit 1
fi

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
RUNTIME_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Keys that must live in Secret Manager rather than plain env vars.
is_secret_key() {
    case "$1" in
        OPENAI_API_KEY|DB_PASS|JWT_VERIFICATION_KEY|PARALLEL_API_KEY|SLACK_BOT_TOKEN|SLACK_SIGNING_SECRET) return 0 ;;
        *) return 1 ;;
    esac
}

# Secret Manager names are lowercase-with-dashes versions of the env keys.
secret_name_for() {
    printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-'
}

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

echo ""
echo -e "${BOLD}Syncing env vars from ${ENV_FILE} to Cloud Run service ${SERVICE_NAME}...${NC}"
echo ""

# Parse the env file, treating PEM blocks (and other multiline values)
# as a single variable. Plain vars are joined with the | delimiter (gcloud's
# ^|^ escape syntax) so values containing commas survive; values containing
# '|' itself are rejected up front rather than silently corrupted.
ENV_UPDATES=""
SECRET_UPDATES=""
count=0
current_key=""
current_value=""

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments (only when not inside a multiline value)
    if [[ -z "$current_key" ]]; then
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    fi

    if [[ -z "$current_key" ]]; then
        # Start of a new variable
        current_key="${line%%=*}"
        current_value="${line#*=}"
    else
        # Continuation of a multiline value
        current_value="${current_value}
${line}"
    fi

    # Check if the value is complete (not in the middle of a PEM block)
    if [[ "$current_value" == *"-----BEGIN"* && "$current_value" != *"-----END"* ]]; then
        continue
    fi

    # Strip surrounding quotes if present
    current_value="${current_value#\"}"
    current_value="${current_value%\"}"
    current_value="${current_value#\'}"
    current_value="${current_value%\'}"

    if is_secret_key "$current_key"; then
        secret_name="$(secret_name_for "$current_key")"
        echo -e "${DIM}  Secret ${current_key} -> ${secret_name}${NC}"
        put_secret "$secret_name" "$current_value"
        SECRET_UPDATES="${SECRET_UPDATES:+${SECRET_UPDATES},}${current_key}=${secret_name}:latest"
    else
        if [[ "$current_value" == *"|"* ]]; then
            echo "Value of ${current_key} contains '|', which this sync's gcloud delimiter"
            echo "cannot carry. Set it directly instead:"
            echo "  gcloud run services update ${SERVICE_NAME} --region ${REGION} --update-env-vars ..."
            exit 1
        fi
        echo -e "${DIM}  Env var ${current_key}${NC}"
        ENV_UPDATES="${ENV_UPDATES:+${ENV_UPDATES}|}${current_key}=${current_value}"
    fi
    count=$((count + 1))

    current_key=""
    current_value=""
done < "$ENV_FILE"

if [[ $count -eq 0 ]]; then
    echo "Nothing to sync."
    exit 0
fi

UPDATE_ARGS=()
[[ -n "$ENV_UPDATES" ]] && UPDATE_ARGS+=(--update-env-vars "^|^${ENV_UPDATES}")
[[ -n "$SECRET_UPDATES" ]] && UPDATE_ARGS+=(--update-secrets "$SECRET_UPDATES")

echo ""
gcloud run services update "$SERVICE_NAME" \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    "${UPDATE_ARGS[@]}"

echo ""
echo -e "${BOLD}Done.${NC} Synced ${count} variable(s) — Cloud Run rolled a new revision."
echo ""

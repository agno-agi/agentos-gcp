#!/bin/bash

############################################################################
#
#    Agno Google Cloud Teardown
#
#    Usage:
#      ./scripts/gcp/down.sh          # asks before destroying
#      ./scripts/gcp/down.sh --yes    # no prompt (CI / automation)
#
#    Deletes the Cloud Run service, the Cloud SQL instance (ALL DATA), the
#    Artifact Registry repo, and the Secret Manager secrets created by
#    up.sh / env-sync.sh. The VPC peering + allocated range are left in
#    place: they are one-time-per-VPC infrastructure that other services
#    may share, and deleting them while any private-IP consumer exists
#    fails; they cost nothing while unused.
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
RED='\033[31m'
NC='\033[0m'

SERVICE_NAME="agent-os"
SQL_INSTANCE="agentos-db"
AR_REPO="agentos"
SECRETS=(openai-api-key db-pass jwt-verification-key mcp-connect-secret agentos-mcp-signing-key parallel-api-key slack-bot-token slack-signing-secret)

# Preflight
if ! command -v gcloud &> /dev/null; then
    echo "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2> /dev/null)}"
# Region precedence: explicit GCP_REGION > the region up.sh recorded in the
# env file > default. A region mismatch here would make every delete report
# not-found while the real resources keep billing in the deploy region.
REGION="$GCP_REGION"
if [[ -z "$REGION" ]]; then
    for f in .env.production .env; do
        [[ -f "$f" ]] && REGION="$(sed -nE 's/^GCP_REGION=(.*)$/\1/p' "$f" | head -1)" && [[ -n "$REGION" ]] && break
    done
fi
REGION="${REGION:-us-central1}"
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo "No GCP project set. Run: gcloud config set project <id>  (or export GCP_PROJECT_ID)"
    exit 1
fi

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Google Cloud Teardown${NC}"
echo ""
echo -e "This deletes from project ${PROJECT_ID} (region ${REGION}):"
echo -e "  - Cloud Run service        ${SERVICE_NAME}"
echo -e "  - Cloud SQL instance       ${SQL_INSTANCE}  ${RED}(all data deleted)${NC}"
echo -e "  - Artifact Registry repo   ${AR_REPO}"
echo -e "  - Secrets                  ${SECRETS[*]}"
echo -e "${DIM}Kept: VPC peering + allocated range (shared, one-time-per-VPC infra).${NC}"
echo ""

if [[ "$1" != "--yes" ]]; then
    printf "Type the SQL instance name (%s) to confirm: " "$SQL_INSTANCE"
    IFS= read -r CONFIRM
    if [[ "$CONFIRM" != "$SQL_INSTANCE" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Deleting Cloud Run service${NC}"
# Describe-guard: a not-found here usually means a region mismatch rather than
# a clean teardown — deleting blind would look like success while the service
# keeps billing in the region it was actually deployed to.
if gcloud run services describe "$SERVICE_NAME" --project "$PROJECT_ID" --region "$REGION" \
    --format 'value(metadata.name)' &> /dev/null; then
    echo -e "${DIM}> gcloud run services delete ${SERVICE_NAME} --project ${PROJECT_ID} --region ${REGION} --quiet${NC}"
    gcloud run services delete "$SERVICE_NAME" --project "$PROJECT_ID" --region "$REGION" --quiet
else
    echo -e "${RED}${BOLD}Warning:${NC} Cloud Run service ${SERVICE_NAME} not found in region ${REGION}."
    echo -e "${DIM}  If it was deployed to another region, rerun with GCP_REGION=<actual> ./scripts/gcp/down.sh${NC}"
    echo -e "${DIM}  Continuing: Cloud SQL and secrets are deleted by name, not region, below.${NC}"
fi

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Deleting Cloud SQL instance (takes a few minutes)${NC}"
echo -e "${DIM}> gcloud sql instances delete ${SQL_INSTANCE} --project ${PROJECT_ID} --quiet${NC}"
gcloud sql instances delete "$SQL_INSTANCE" --project "$PROJECT_ID" --quiet \
    || echo -e "${DIM}Instance already gone${NC}"

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Deleting Artifact Registry repo${NC}"
echo -e "${DIM}> gcloud artifacts repositories delete ${AR_REPO} --project ${PROJECT_ID} --location ${REGION} --quiet${NC}"
gcloud artifacts repositories delete "$AR_REPO" --project "$PROJECT_ID" --location "$REGION" --quiet \
    || echo -e "${DIM}Repo already gone${NC}"

echo ""
echo -e "${ORANGE}▸${NC} ${BOLD}Deleting secrets${NC}"
for secret in "${SECRETS[@]}"; do
    gcloud secrets delete "$secret" --project "$PROJECT_ID" --quiet 2> /dev/null \
        && echo -e "${DIM}  Deleted ${secret}${NC}" \
        || echo -e "${DIM}  ${secret} not present${NC}"
done

echo ""
echo -e "${BOLD}Done.${NC} Verify nothing is left billing:"
echo -e "${DIM}  gcloud run services list --project ${PROJECT_ID}${NC}"
echo -e "${DIM}  gcloud sql instances list --project ${PROJECT_ID}${NC}"
echo -e "${DIM}  gcloud artifacts repositories list --project ${PROJECT_ID}${NC}"
echo ""

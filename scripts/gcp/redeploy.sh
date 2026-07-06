#!/bin/bash

############################################################################
#
#    Agno Google Cloud Redeploy
#
#    Usage: ./scripts/gcp/redeploy.sh
#
#    Rebuilds the image, pushes it, and rolls the Cloud Run service to the
#    new build. Env vars, secrets, sizing, and networking carry over from
#    the running revision. Run ./scripts/gcp/up.sh first for initial
#    provisioning.
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

SERVICE_NAME="agent-os"
AR_REPO="agentos"

# Preflight
if ! command -v gcloud &> /dev/null; then
    echo "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
    echo "Docker not running. The image is built locally and pushed to Artifact Registry."
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

IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:latest"

echo ""
echo -e "${BOLD}Building and pushing image (linux/amd64)...${NC}"
echo ""
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"

echo ""
echo -e "${BOLD}Rolling ${SERVICE_NAME} to the new image...${NC}"
echo ""
gcloud run deploy "$SERVICE_NAME" \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    --image "$IMAGE"

echo ""
echo -e "${BOLD}Done.${NC}"
echo -e "${DIM}Logs: gcloud run services logs read ${SERVICE_NAME} --limit 100 --project ${PROJECT_ID} --region ${REGION}${NC}"
echo ""

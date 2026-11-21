#!/bin/bash
# deploy.sh
# Creates or updates the weekly-cleanup Code Engine job with the persistent
# data store mount (ce-pds-9ef3, backed by rst-usage-bucket-9yk456iwqnolk6p
# in ca-tor). Reports land in the bucket under the cleanup/ prefix.
#
# Required environment:
#   CE_PROJECT         Code Engine project name
#   IMAGE              container image for the job
#   IBMCLOUD_API_KEY   API key stored as the cleanup-api-key secret

set -euo pipefail

: "${CE_PROJECT:?CE_PROJECT is required}"
: "${IMAGE:?IMAGE is required}"
: "${IBMCLOUD_API_KEY:?IBMCLOUD_API_KEY is required}"

JOB_NAME="weekly-cleanup"
SECRET_NAME="cleanup-api-key"
MOUNT="/mnt/reports=ce-pds-9ef3:/cleanup"

ibmcloud ce project select --name "$CE_PROJECT"

if ibmcloud ce secret get --name "$SECRET_NAME" >/dev/null 2>&1; then
    ibmcloud ce secret update --name "$SECRET_NAME" \
        --from-literal "IBMCLOUD_API_KEY=${IBMCLOUD_API_KEY}"
else
    ibmcloud ce secret create --name "$SECRET_NAME" \
        --from-literal "IBMCLOUD_API_KEY=${IBMCLOUD_API_KEY}"
fi

if ibmcloud ce job get --name "$JOB_NAME" >/dev/null 2>&1; then
    ibmcloud ce job update --name "$JOB_NAME" \
        --image "$IMAGE" \
        --mount-data-store "$MOUNT" \
        --env-from-secret "$SECRET_NAME"
else
    ibmcloud ce job create --name "$JOB_NAME" \
        --image "$IMAGE" \
        --mount-data-store "$MOUNT" \
        --env-from-secret "$SECRET_NAME"
fi

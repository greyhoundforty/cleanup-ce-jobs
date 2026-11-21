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
#   REGISTRY_SECRET    Code Engine registry secret for pulling IMAGE
#
# Safe to re-run: an existing job is updated, adding only what it lacks.

set -euo pipefail

: "${CE_PROJECT:?CE_PROJECT is required}"
: "${IMAGE:?IMAGE is required}"
: "${IBMCLOUD_API_KEY:?IBMCLOUD_API_KEY is required}"
: "${REGISTRY_SECRET:?REGISTRY_SECRET is required}"

JOB_NAME="weekly-cleanup"
SECRET_NAME="cleanup-api-key"
MOUNT_DIR="/mnt/reports"
MOUNT_SUBPATH="cleanup"
MOUNT="${MOUNT_DIR}=ce-pds-9ef3:${MOUNT_SUBPATH}"

ibmcloud ce project select --name "$CE_PROJECT"

if ibmcloud ce secret get --name "$SECRET_NAME" >/dev/null 2>&1; then
    ibmcloud ce secret update --name "$SECRET_NAME" \
        --from-literal "IBMCLOUD_API_KEY=${IBMCLOUD_API_KEY}"
else
    ibmcloud ce secret create --name "$SECRET_NAME" \
        --from-literal "IBMCLOUD_API_KEY=${IBMCLOUD_API_KEY}"
fi

if ibmcloud ce job get --name "$JOB_NAME" >/dev/null 2>&1; then
    # The mount and secret flags are add-only on update and fail as duplicates,
    # so only pass the ones the job does not already have.
    JOB_JSON=$(ibmcloud ce job get --name "$JOB_NAME" --output json)
    EXISTING_SUBPATH=$(echo "$JOB_JSON" | jq -r --arg d "$MOUNT_DIR" \
        '[.spec.template.containers[0].volumeMounts[]? | select(.mountPath == $d) | .subPath // ""][0] // "none"')
    HAS_SECRET=$(echo "$JOB_JSON" | jq -r --arg s "$SECRET_NAME" \
        '[.spec.template.containers[0].envFrom[]?.secretRef.name | select(. == $s)] | length')

    if [ "$EXISTING_SUBPATH" != "none" ] && [ "$EXISTING_SUBPATH" != "$MOUNT_SUBPATH" ]; then
        ibmcloud ce job update --name "$JOB_NAME" --mount-rm "$MOUNT_DIR"
        EXISTING_SUBPATH="none"
    fi

    UPDATE_ARGS=(--image "$IMAGE" --registry-secret "$REGISTRY_SECRET")
    [ "$EXISTING_SUBPATH" = "none" ] && UPDATE_ARGS+=(--mount-data-store "$MOUNT")
    [ "$HAS_SECRET" = "0" ] && UPDATE_ARGS+=(--env-from-secret "$SECRET_NAME")
    ibmcloud ce job update --name "$JOB_NAME" "${UPDATE_ARGS[@]}"
else
    ibmcloud ce job create --name "$JOB_NAME" \
        --image "$IMAGE" \
        --mount-data-store "$MOUNT" \
        --env-from-secret "$SECRET_NAME" \
        --registry-secret "$REGISTRY_SECRET"
fi

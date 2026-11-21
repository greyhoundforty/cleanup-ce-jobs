#!/bin/bash
# deploy.sh
# Creates or updates the weekly-cleanup Code Engine job with the persistent
# data store mount (ce-pds-9ef3, backed by rst-usage-bucket-9yk456iwqnolk6p
# in ca-tor). Reports land in the bucket under the cleanup/ prefix.
#
# Required environment:
#   CE_PROJECT         Code Engine project name
#   IMAGE              container image for the job. Use the private registry
#                      hostname (private.ca.icr.io/<namespace>/<image>:<tag>):
#                      the registry secret holds credentials for that host only,
#                      and pulling from ca.icr.io fails with a 401.
#   IBMCLOUD_API_KEY   API key stored as the cleanup-api-key secret
#   REGISTRY_SECRET    Code Engine registry secret for pulling IMAGE
#
# Requires a prior `ibmcloud login` (and a target resource group), and jq.
# Safe to re-run: an existing job is updated, adding only what it lacks, and the
# weekly cron subscription is created or updated.

set -euo pipefail

: "${CE_PROJECT:?CE_PROJECT is required}"
: "${IMAGE:?IMAGE is required}"
: "${IBMCLOUD_API_KEY:?IBMCLOUD_API_KEY is required}"
: "${REGISTRY_SECRET:?REGISTRY_SECRET is required}"

if ! ibmcloud target >/dev/null 2>&1; then
    echo "ERROR: not logged in to IBM Cloud (run: ibmcloud login)" >&2
    exit 1
fi

case "$IMAGE" in
    private.*) ;;
    *.icr.io/*)
        echo "WARNING: IMAGE uses a public registry hostname; the registry secret is for private.ca.icr.io and the pull will likely fail with a 401." >&2
        ;;
esac

JOB_NAME="weekly-cleanup"
CRON_NAME="weekly-cleanup-cron"
CRON_SCHEDULE="0 13 * * 1"   # Mondays 13:00 UTC
CRON_TZ="UTC"
SECRET_NAME="cleanup-api-key"
MOUNT_DIR="/mnt/reports"
MOUNT_SUBPATH="cleanup"
MOUNT="${MOUNT_DIR}=ce-pds-9ef3:${MOUNT_SUBPATH}"

ibmcloud ce project select --name "$CE_PROJECT"

# Pass the API key through a private temp file so it never appears in the
# process list.
ENV_FILE=$(mktemp)
trap 'rm -f "$ENV_FILE"' EXIT
chmod 600 "$ENV_FILE"
printf 'IBMCLOUD_API_KEY=%s\n' "$IBMCLOUD_API_KEY" > "$ENV_FILE"

if ibmcloud ce secret get --name "$SECRET_NAME" >/dev/null 2>&1; then
    ibmcloud ce secret update --name "$SECRET_NAME" --from-env-file "$ENV_FILE"
else
    ibmcloud ce secret create --name "$SECRET_NAME" --from-env-file "$ENV_FILE"
fi

if ibmcloud ce job get --name "$JOB_NAME" >/dev/null 2>&1; then
    # The mount and secret flags are add-only on update and fail as duplicates,
    # so only pass the ones the job does not already have.
    JOB_JSON=$(ibmcloud ce job get --name "$JOB_NAME" --output json)
    EXISTING_SUBPATH=$(echo "$JOB_JSON" | jq -r --arg d "$MOUNT_DIR" \
        '[.spec.template.containers[0].volumeMounts[]? | select(.mountPath == $d) | .subPath // ""][0] // "none"')
    HAS_SECRET=$(echo "$JOB_JSON" | jq -r --arg s "$SECRET_NAME" \
        '[.spec.template.containers[0].envFrom[]?.secretRef.name | select(. == $s)] | length')
    HAS_COS_ENV=$(echo "$JOB_JSON" | jq -r \
        '[.spec.template.containers[0].env[]? | select(.name == "COS_BUCKET_NAME")] | length')

    if [ "$EXISTING_SUBPATH" != "none" ] && [ "$EXISTING_SUBPATH" != "$MOUNT_SUBPATH" ]; then
        ibmcloud ce job update --name "$JOB_NAME" --mount-rm "$MOUNT_DIR"
        EXISTING_SUBPATH="none"
    fi

    UPDATE_ARGS=(--image "$IMAGE" --registry-secret "$REGISTRY_SECRET")
    [ "$EXISTING_SUBPATH" = "none" ] && UPDATE_ARGS+=(--mount-data-store "$MOUNT")
    [ "$HAS_SECRET" = "0" ] && UPDATE_ARGS+=(--env-from-secret "$SECRET_NAME")
    # Left over from the old CLI-upload version of the job.
    [ "$HAS_COS_ENV" != "0" ] && UPDATE_ARGS+=(--env-rm COS_BUCKET_NAME)
    ibmcloud ce job update --name "$JOB_NAME" "${UPDATE_ARGS[@]}"
else
    ibmcloud ce job create --name "$JOB_NAME" \
        --image "$IMAGE" \
        --mount-data-store "$MOUNT" \
        --env-from-secret "$SECRET_NAME" \
        --registry-secret "$REGISTRY_SECRET"
fi

if ibmcloud ce subscription cron get --name "$CRON_NAME" >/dev/null 2>&1; then
    ibmcloud ce subscription cron update --name "$CRON_NAME" \
        --schedule "$CRON_SCHEDULE" --time-zone "$CRON_TZ"
else
    ibmcloud ce subscription cron create --name "$CRON_NAME" \
        --destination-type job --destination "$JOB_NAME" \
        --schedule "$CRON_SCHEDULE" --time-zone "$CRON_TZ"
fi

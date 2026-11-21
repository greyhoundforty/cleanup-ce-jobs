#!/bin/bash
# deploy_deleteme.sh
# Creates or updates the deleteme-cleanup Code Engine job (issue #2): a reviewed
# CSV uploaded under review/ in the review bucket triggers it. The job is
# deployed in dry-run mode unless DELETEME_DRY_RUN=false.
#
# Required environment (from .env.deploy):
#   CE_PROJECT          Code Engine project name
#   IMAGE               image (private.ca.icr.io/<namespace>/<image>:<tag>)
#   REGISTRY_SECRET     Code Engine registry secret for pulling IMAGE
#   DELETEME_API_KEY    API key with delete rights, stored as the deleteme-api-key secret
#   REVIEW_BUCKET       COS bucket (ca-tor) the reviewed CSVs are uploaded to
#   REVIEW_HMAC_SECRET  Code Engine HMAC secret for REVIEW_BUCKET
# Optional:
#   PROTECTED_CRNS      comma-separated CRNs never to delete (adds to the built-in list)
#   DELETEME_DRY_RUN    "false" to deploy live; anything else deploys a dry run
#
# The bucket, HMAC credential/secret, service ID and the Notifications Manager
# authorization are created by hand beforehand. Requires `ibmcloud login` and jq.
# Never touches the weekly-cleanup report job.

set -euo pipefail

: "${CE_PROJECT:?CE_PROJECT is required}"
: "${IMAGE:?IMAGE is required}"
: "${REGISTRY_SECRET:?REGISTRY_SECRET is required}"
: "${DELETEME_API_KEY:?DELETEME_API_KEY is required}"
: "${REVIEW_BUCKET:?REVIEW_BUCKET is required}"
: "${REVIEW_HMAC_SECRET:?REVIEW_HMAC_SECRET is required}"

if ! ibmcloud target >/dev/null 2>&1; then
    echo "ERROR: not logged in to IBM Cloud (run: ibmcloud login)" >&2
    exit 1
fi

JOB_NAME="deleteme-cleanup"
SECRET_NAME="deleteme-api-key"
PDS_NAME="deleteme-review-pds"
SUB_NAME="deleteme-cleanup-cos"
REPORTS_DIR="/mnt/reports"
REVIEW_DIR="/mnt/review"
REPORTS_MOUNT="${REPORTS_DIR}=ce-pds-9ef3:cleanup"
REVIEW_MOUNT="${REVIEW_DIR}=${PDS_NAME}"
DRY_RUN_VALUE="true"
[ "${DELETEME_DRY_RUN:-true}" = "false" ] && DRY_RUN_VALUE="false"

ENV_ARGS=(--env "CLEANUP_SCRIPT=/opt/cleanup/deleteme_cleanup.py"
          --env "DRY_RUN=${DRY_RUN_VALUE}"
          --env "PROTECTED_CRNS=${PROTECTED_CRNS:-}")

ibmcloud ce project select --name "$CE_PROJECT"

# Pass the API key through a private temp file so it never appears in the
# process list. The job's entrypoint reads it as IBMCLOUD_API_KEY.
ENV_FILE=$(mktemp)
trap 'rm -f "$ENV_FILE"' EXIT
chmod 600 "$ENV_FILE"
printf 'IBMCLOUD_API_KEY=%s\n' "$DELETEME_API_KEY" > "$ENV_FILE"

if ibmcloud ce secret get --name "$SECRET_NAME" >/dev/null 2>&1; then
    ibmcloud ce secret update --name "$SECRET_NAME" --from-env-file "$ENV_FILE"
else
    ibmcloud ce secret create --name "$SECRET_NAME" --from-env-file "$ENV_FILE"
fi

if ! ibmcloud ce pds get --name "$PDS_NAME" >/dev/null 2>&1; then
    ibmcloud ce pds create --name "$PDS_NAME" --cos-bucket-name "$REVIEW_BUCKET" \
        --cos-bucket-location ca-tor --cos-access-secret "$REVIEW_HMAC_SECRET"
fi

if ibmcloud ce job get --name "$JOB_NAME" >/dev/null 2>&1; then
    # Mount and secret flags are add-only on update and fail as duplicates.
    JOB_JSON=$(ibmcloud ce job get --name "$JOB_NAME" --output json)
    has_mount() {
        echo "$JOB_JSON" | jq -r --arg d "$1" \
            '[.spec.template.containers[0].volumeMounts[]? | select(.mountPath == $d)] | length'
    }
    HAS_SECRET=$(echo "$JOB_JSON" | jq -r --arg s "$SECRET_NAME" \
        '[.spec.template.containers[0].envFrom[]?.secretRef.name | select(. == $s)] | length')

    UPDATE_ARGS=(--image "$IMAGE" --registry-secret "$REGISTRY_SECRET" "${ENV_ARGS[@]}")
    [ "$(has_mount "$REPORTS_DIR")" = "0" ] && UPDATE_ARGS+=(--mount-data-store "$REPORTS_MOUNT")
    [ "$(has_mount "$REVIEW_DIR")" = "0" ] && UPDATE_ARGS+=(--mount-data-store "$REVIEW_MOUNT")
    [ "$HAS_SECRET" = "0" ] && UPDATE_ARGS+=(--env-from-secret "$SECRET_NAME")
    ibmcloud ce job update --name "$JOB_NAME" "${UPDATE_ARGS[@]}"
else
    ibmcloud ce job create --name "$JOB_NAME" \
        --image "$IMAGE" \
        --registry-secret "$REGISTRY_SECRET" \
        --mount-data-store "$REPORTS_MOUNT" \
        --mount-data-store "$REVIEW_MOUNT" \
        --env-from-secret "$SECRET_NAME" \
        "${ENV_ARGS[@]}"
fi

if ! ibmcloud ce subscription cos get --name "$SUB_NAME" >/dev/null 2>&1; then
    ibmcloud ce subscription cos create --name "$SUB_NAME" \
        --destination-type job --destination "$JOB_NAME" \
        --bucket "$REVIEW_BUCKET" --event-type write \
        --prefix review/ --suffix .csv
fi

echo "Deployed ${JOB_NAME} (DRY_RUN=${DRY_RUN_VALUE})."

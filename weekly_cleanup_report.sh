#!/bin/bash
# weekly_cleanup_report.sh
# Lists all resources tagged with owner:ryantiffany for weekly cleanup.
# Writes the report to a Code Engine persistent data store mount
# (backed by Cloud Object Storage), so no upload step is needed.

set -o pipefail

TAG="owner:ryantiffany"
TIMESTAMP=$(date +"%Y-%m-%d")
DEFAULT_REPORT_DIR="/mnt/reports"
REPORT_DIR="${REPORT_DIR:-$DEFAULT_REPORT_DIR}"
OUTPUT_FILE="${REPORT_DIR}/cleanup_report_${TIMESTAMP}.txt"
TMP_FILE="${OUTPUT_FILE}.tmp"

# The default path must be a real mount; otherwise the report would land in
# the container's ephemeral filesystem and be lost.
if [ "$REPORT_DIR" = "$DEFAULT_REPORT_DIR" ] && ! grep -qs " ${DEFAULT_REPORT_DIR} " /proc/mounts; then
    echo "ERROR: ${DEFAULT_REPORT_DIR} is not mounted (is PDS ce-pds-9ef3 attached to the job?)" >&2
    exit 1
fi

if ! mkdir -p "$REPORT_DIR" || [ ! -w "$REPORT_DIR" ]; then
    echo "ERROR: REPORT_DIR not writable: ${REPORT_DIR}" >&2
    exit 1
fi

echo "Searching for resources with tag: ${TAG}..."

# Execute search and format output using jq
if ! ibmcloud resource search "tags:\"${TAG}\"" --output json \
    | jq -r '.items[] | "\(.name) | \(.region) | \(.service_name) | \(.crn)"' > "$TMP_FILE"; then
    echo "ERROR: resource search failed." >&2
    rm -f "$TMP_FILE"
    exit 1
fi

if [ -s "$TMP_FILE" ]; then
    mv -f "$TMP_FILE" "$OUTPUT_FILE"
    echo "Report generated successfully: $OUTPUT_FILE"
else
    echo "No resources found with tag ${TAG}."
    rm -f "$TMP_FILE"
fi

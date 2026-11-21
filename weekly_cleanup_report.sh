#!/bin/bash
# weekly_cleanup_report.sh
# Lists all resources tagged with owner:ryantiffany for weekly cleanup.
# Writes the report to a Code Engine persistent data store mount
# (backed by Cloud Object Storage), so no upload step is needed.

set -o pipefail

TAG="owner:ryantiffany"
TIMESTAMP=$(date +"%Y-%m-%d")
REPORT_DIR="${REPORT_DIR:-/mnt/reports}"
OUTPUT_FILE="${REPORT_DIR}/cleanup_report_${TIMESTAMP}.txt"

if ! mkdir -p "$REPORT_DIR" || [ ! -w "$REPORT_DIR" ]; then
    echo "ERROR: REPORT_DIR not writable: ${REPORT_DIR}" >&2
    exit 1
fi

echo "Searching for resources with tag: ${TAG}..."

# Execute search and format output using jq
if ! ibmcloud resource search "tags:\"${TAG}\"" --output json \
    | jq -r '.items[] | "\(.name) | \(.region) | \(.service_name) | \(.crn)"' > "$OUTPUT_FILE"; then
    echo "ERROR: resource search failed." >&2
    rm -f "$OUTPUT_FILE"
    exit 1
fi

if [ -s "$OUTPUT_FILE" ]; then
    echo "Report generated successfully: $OUTPUT_FILE"
else
    echo "No resources found with tag ${TAG}."
    rm -f "$OUTPUT_FILE"
fi

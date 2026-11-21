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
BASE="${REPORT_DIR}/cleanup_report_${TIMESTAMP}"
TXT_FILE="${BASE}.txt"
JSON_FILE="${BASE}.json"
CSV_FILE="${BASE}.csv"
SEARCH_TMP="${BASE}.search.tmp"
CSV_HEADER="delete,name,service_name,type,region,resource_group_id,creation_date,tags,crn"

cleanup_tmp() {
    rm -f "$SEARCH_TMP" "${TXT_FILE}.tmp" "${JSON_FILE}.tmp" "${CSV_FILE}.tmp"
}

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

# One search; every report format is rendered from this single result.
if ! ibmcloud resource search "tags:\"${TAG}\"" --output json > "$SEARCH_TMP" \
    || ! jq -e '.items | type == "array"' "$SEARCH_TMP" >/dev/null 2>&1; then
    echo "ERROR: resource search failed." >&2
    cleanup_tmp
    exit 1
fi

# An empty result still writes all three files ([] JSON, header-only CSV and a
# "No resources found" text line), so "ran and found nothing" is distinguishable
# from "did not run".
if [ "$(jq '.items | length' "$SEARCH_TMP")" -eq 0 ]; then
    echo "No resources found with tag ${TAG}."
fi

# Render all formats to temp files; only move them into place if every one
# succeeds, so a failure never leaves a partial set or clobbers an earlier report.
if ! { jq -r --arg tag "$TAG" 'if (.items | length) == 0 then "No resources found with tag \($tag)."
            else .items[] | "\(.name) | \(.region) | \(.service_name) | \(.crn)" end' "$SEARCH_TMP" > "${TXT_FILE}.tmp" \
    && jq '.items' "$SEARCH_TMP" > "${JSON_FILE}.tmp" \
    && printf '%s\n' "$CSV_HEADER" > "${CSV_FILE}.tmp" \
    && jq -r '.items[] | ["no", .name, .service_name, .type, .region, .resource_group_id,
            .creation_date, ((.tags // []) | join(";")), .crn] | map(. // "") | @csv' \
        "$SEARCH_TMP" >> "${CSV_FILE}.tmp"; }; then
    echo "ERROR: report write failed." >&2
    cleanup_tmp
    exit 1
fi

mv -f "${TXT_FILE}.tmp" "$TXT_FILE" \
    && mv -f "${JSON_FILE}.tmp" "$JSON_FILE" \
    && mv -f "${CSV_FILE}.tmp" "$CSV_FILE" || { echo "ERROR: report write failed." >&2; cleanup_tmp; exit 1; }
rm -f "$SEARCH_TMP"
echo "Report generated successfully: ${BASE}.{txt,json,csv}"

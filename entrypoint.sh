#!/bin/bash
# entrypoint.sh
# Logs in to IBM Cloud non-interactively, then runs the cleanup report.
# Fails fast with a clear message if the API key is missing or login fails,
# instead of letting the report script fail later with a confusing error.

CLEANUP_SCRIPT="${CLEANUP_SCRIPT:-/usr/local/bin/weekly_cleanup_report.sh}"

if [ -z "${IBMCLOUD_API_KEY:-}" ]; then
    echo "ERROR: IBMCLOUD_API_KEY is not set (is the cleanup-api-key secret attached to the job?)" >&2
    exit 1
fi

# Without -r or --no-region, `ibmcloud login` prompts for a region and fails
# with EOF in a job. Code Engine sets CE_REGION; IBMCLOUD_REGION overrides it.
REGION="${IBMCLOUD_REGION:-${CE_REGION:-}}"
if [ -n "$REGION" ]; then
    REGION_ARGS=(-r "$REGION")
else
    REGION_ARGS=(--no-region)
fi

if ! LOGIN_OUTPUT=$(ibmcloud login --apikey "$IBMCLOUD_API_KEY" "${REGION_ARGS[@]}" -q 2>&1); then
    echo "ERROR: ibmcloud login failed:" >&2
    echo "${LOGIN_OUTPUT//$IBMCLOUD_API_KEY/[redacted]}" >&2
    exit 1
fi

exec "$CLEANUP_SCRIPT"

#!/bin/bash
# Tests for deploy_deleteme.sh using a stubbed ibmcloud that logs every call.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy_deleteme.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

mkdir -p "$TMP/bin"
cat > "$TMP/bin/ibmcloud" <<'EOF2'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
case "$*" in
    "ce job get"*"--output json"*) cat "$STUB_JOB_JSON"; exit 0 ;;
    "ce job get"*) [ "$STUB_JOB_EXISTS" = 1 ]; exit $? ;;
    "ce secret get"*) exit 0 ;;
    "ce pds get"*) [ "${STUB_PDS_EXISTS:-0}" = 1 ]; exit $? ;;
    "ce subscription cos get"*) [ "${STUB_SUB_EXISTS:-0}" = 1 ]; exit $? ;;
    "target"*) exit 0 ;;
esac
exit 0
EOF2
chmod +x "$TMP/bin/ibmcloud"

# job_json <has-mounts 0|1> <has-secret 0|1>
job_json() {
    local mounts='[]' envfrom='[]'
    [ "$1" = 1 ] && mounts='[{"mountPath":"/mnt/reports","subPath":"cleanup"},{"mountPath":"/mnt/review"}]'
    [ "$2" = 1 ] && envfrom='[{"secretRef":{"name":"deleteme-api-key"}}]'
    echo "{\"spec\":{\"template\":{\"containers\":[{\"volumeMounts\":${mounts},\"envFrom\":${envfrom},\"env\":[]}]}}}" > "$TMP/job.json"
}

# run_deploy <job-exists 0|1> [extra VAR=value ...]: sets RC, log in $LOG.
run_deploy() {
    LOG="$TMP/calls.log"
    : > "$LOG"
    local exists="$1"; shift
    env STUB_LOG="$LOG" STUB_JOB_JSON="$TMP/job.json" STUB_JOB_EXISTS="$exists" \
        PATH="$TMP/bin:$PATH" CE_PROJECT=p IMAGE=private.ca.icr.io/ns/img:v6 \
        REGISTRY_SECRET=reg DELETEME_API_KEY=d3l3te-key-value REVIEW_BUCKET=rev-bucket \
        REVIEW_HMAC_SECRET=rev-hmac "$@" \
        bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
    RC=$?
}

check() {
    if [ "$2" = "ok" ]; then PASS=$((PASS + 1)); echo "PASS: $1"; else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}

jobcall() { grep -E "^ce job (update|create)" "$LOG"; }

test_requires_env() {
    job_json 0 0
    run_deploy 0 REVIEW_BUCKET=
    if [ "$RC" -ne 0 ] && ! grep -q "^ce job" "$LOG"; then check requires_env ok; else check requires_env fail; fi
}

test_create_sets_mounts_secret_env() {
    job_json 0 0
    run_deploy 0
    local c; c=$(jobcall)
    if [ "$RC" -eq 0 ] && echo "$c" | grep -q "^ce job create --name deleteme-cleanup" \
        && echo "$c" | grep -q -- "--mount-data-store /mnt/reports=ce-pds-9ef3:cleanup" \
        && echo "$c" | grep -q -- "--mount-data-store /mnt/review=deleteme-review-pds" \
        && echo "$c" | grep -q -- "--env-from-secret deleteme-api-key" \
        && echo "$c" | grep -q -- "--env DRY_RUN=true" \
        && echo "$c" | grep -q -- "--env CLEANUP_SCRIPT=/opt/cleanup/deleteme_cleanup.py" \
        && echo "$c" | grep -q -- "--registry-secret reg"; then
        check create_sets_mounts_secret_env ok
    else
        check create_sets_mounts_secret_env fail
    fi
}

test_api_key_not_on_command_line() {
    job_json 0 0
    run_deploy 0
    if [ "$RC" -eq 0 ] && ! grep -q "d3l3te-key-value" "$LOG" \
        && grep -q "^ce secret update --name deleteme-api-key --from-env-file" "$LOG"; then
        check api_key_not_on_command_line ok
    else
        check api_key_not_on_command_line fail
    fi
}

test_dry_run_override() {
    job_json 0 0
    run_deploy 0 DELETEME_DRY_RUN=false
    if [ "$RC" -eq 0 ] && jobcall | grep -q -- "--env DRY_RUN=false"; then
        check dry_run_override ok
    else
        check dry_run_override fail
    fi
}

test_protected_crns_passed() {
    job_json 0 0
    run_deploy 0 PROTECTED_CRNS=crn:a,crn:b
    if [ "$RC" -eq 0 ] && jobcall | grep -q -- "--env PROTECTED_CRNS=crn:a,crn:b"; then
        check protected_crns_passed ok
    else
        check protected_crns_passed fail
    fi
}

test_update_skips_existing_mounts() {
    job_json 1 1
    run_deploy 1
    local c; c=$(jobcall)
    if [ "$RC" -eq 0 ] && echo "$c" | grep -q "^ce job update --name deleteme-cleanup" \
        && ! echo "$c" | grep -q -- "--mount-data-store" \
        && ! echo "$c" | grep -q -- "--env-from-secret" \
        && echo "$c" | grep -q -- "--env DRY_RUN=true"; then
        check update_skips_existing_mounts ok
    else
        check update_skips_existing_mounts fail
    fi
}

test_update_adds_missing_mounts() {
    job_json 0 0
    run_deploy 1
    local c; c=$(jobcall)
    if [ "$RC" -eq 0 ] && echo "$c" | grep -q "^ce job update" \
        && [ "$(echo "$c" | grep -o -- "--mount-data-store" | wc -l | tr -d ' ')" = 2 ] \
        && echo "$c" | grep -q -- "--env-from-secret deleteme-api-key"; then
        check update_adds_missing_mounts ok
    else
        check update_adds_missing_mounts fail
    fi
}

test_creates_pds_and_cos_sub_when_missing() {
    job_json 0 0
    run_deploy 0
    if [ "$RC" -eq 0 ] \
        && grep -q "^ce pds create --name deleteme-review-pds --cos-bucket-name rev-bucket --cos-bucket-location ca-tor --cos-access-secret rev-hmac" "$LOG" \
        && grep -q "^ce subscription cos create --name deleteme-cleanup-cos --destination-type job --destination deleteme-cleanup --bucket rev-bucket --event-type write --prefix review/ --suffix .csv" "$LOG"; then
        check creates_pds_and_cos_sub_when_missing ok
    else
        check creates_pds_and_cos_sub_when_missing fail
    fi
}

test_skips_pds_and_cos_sub_when_present() {
    job_json 1 1
    run_deploy 1 STUB_PDS_EXISTS=1 STUB_SUB_EXISTS=1
    if [ "$RC" -eq 0 ] && ! grep -q "^ce pds create" "$LOG" \
        && ! grep -q "^ce subscription cos create" "$LOG"; then
        check skips_pds_and_cos_sub_when_present ok
    else
        check skips_pds_and_cos_sub_when_present fail
    fi
}

test_pds_created_before_job() {
    job_json 0 0
    run_deploy 0
    local pds job
    pds=$(grep -n "^ce pds create" "$LOG" | cut -d: -f1)
    job=$(grep -n "^ce job create" "$LOG" | cut -d: -f1)
    if [ -n "$pds" ] && [ -n "$job" ] && [ "$pds" -lt "$job" ]; then
        check pds_created_before_job ok
    else
        check pds_created_before_job fail
    fi
}

test_never_touches_weekly_job() {
    job_json 0 0
    run_deploy 0
    if [ "$RC" -eq 0 ] && ! grep -q "weekly-cleanup" "$LOG"; then
        check never_touches_weekly_job ok
    else
        check never_touches_weekly_job fail
    fi
}

test_requires_env
test_create_sets_mounts_secret_env
test_api_key_not_on_command_line
test_dry_run_override
test_protected_crns_passed
test_update_skips_existing_mounts
test_update_adds_missing_mounts
test_creates_pds_and_cos_sub_when_missing
test_skips_pds_and_cos_sub_when_present
test_pds_created_before_job
test_never_touches_weekly_job

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

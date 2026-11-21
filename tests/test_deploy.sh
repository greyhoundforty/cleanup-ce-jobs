#!/bin/bash
# Tests for deploy.sh using a stubbed ibmcloud that logs every call.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

mkdir -p "$TMP/bin"
cat > "$TMP/bin/ibmcloud" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
case "$*" in
    "ce job get"*"--output json"*) cat "$STUB_JOB_JSON"; exit 0 ;;
    "ce job get"*) [ "$STUB_JOB_EXISTS" = 1 ]; exit $? ;;
    "ce secret get"*) exit 0 ;;
    "target"*) [ "${STUB_LOGGED_IN:-1}" = 1 ]; exit $? ;;
    "ce subscription cron get"*) [ "${STUB_CRON_EXISTS:-0}" = 1 ]; exit $? ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/ibmcloud"

# job_json <mountPath|none> <subPath> <secret|none> [env var name]
job_json() {
    local mounts='[]' envfrom='[]' env='[]'
    [ -n "$4" ] && env="[{\"name\":\"$4\",\"value\":\"x\"}]"
    [ "$1" != none ] && mounts="[{\"name\":\"m\",\"mountPath\":\"$1\",\"subPath\":\"$2\"}]"
    [ "$3" != none ] && envfrom="[{\"secretRef\":{\"name\":\"$3\"}}]"
    echo "{\"spec\":{\"template\":{\"containers\":[{\"volumeMounts\":${mounts},\"envFrom\":${envfrom},\"env\":${env}}]}}}" > "$TMP/job.json"
}

# run_deploy <job-exists 0|1>: sets RC, log in $LOG.
run_deploy() {
    LOG="$TMP/calls.log"
    : > "$LOG"
    STUB_LOG="$LOG" STUB_JOB_JSON="$TMP/job.json" STUB_JOB_EXISTS="$1" \
        PATH="$TMP/bin:$PATH" CE_PROJECT=p IMAGE="${IMAGE_UNDER_TEST:-private.ca.icr.io/ns/img:v1}" \
        IBMCLOUD_API_KEY=s3cr3t-key-value REGISTRY_SECRET=reg \
        bash "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
    RC=$?
}

check() {
    if [ "$2" = "ok" ]; then PASS=$((PASS + 1)); echo "PASS: $1"; else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}

# The ce job update/create lines only (not 'job get').
calls() { grep -E "^ce job (update|create)" "$LOG"; }

test_update_skips_existing_mount_and_secret() {
    job_json /mnt/reports cleanup cleanup-api-key
    run_deploy 1
    local c
    c=$(calls)
    if [ "$RC" -eq 0 ] && echo "$c" | grep -q "job update" \
        && ! echo "$c" | grep -q -- "--mount-data-store" \
        && ! echo "$c" | grep -q -- "--env-from-secret" \
        && echo "$c" | grep -q -- "--registry-secret reg"; then
        check update_skips_existing_mount_and_secret ok
    else
        check update_skips_existing_mount_and_secret fail
    fi
}

test_update_adds_missing_mount_and_secret() {
    job_json none "" none
    run_deploy 1
    local c
    c=$(calls)
    if [ "$RC" -eq 0 ] && echo "$c" | grep -q -- "--mount-data-store /mnt/reports=ce-pds-9ef3:cleanup" \
        && echo "$c" | grep -q -- "--env-from-secret cleanup-api-key"; then
        check update_adds_missing_mount_and_secret ok
    else
        check update_adds_missing_mount_and_secret fail
    fi
}

test_update_replaces_mount_with_different_subpath() {
    job_json /mnt/reports old-prefix cleanup-api-key
    run_deploy 1
    local rm_line add_line
    rm_line=$(calls | grep -n -- "--mount-rm /mnt/reports" | head -1 | cut -d: -f1)
    add_line=$(calls | grep -n -- "--mount-data-store" | head -1 | cut -d: -f1)
    if [ "$RC" -eq 0 ] && [ -n "$rm_line" ] && [ -n "$add_line" ] && [ "$rm_line" -lt "$add_line" ]; then
        check update_replaces_mount_with_different_subpath ok
    else
        check update_replaces_mount_with_different_subpath fail
    fi
}

test_create_sets_mount_secret_and_registry() {
    job_json none "" none
    run_deploy 0
    local c
    c=$(calls)
    if [ "$RC" -eq 0 ] && echo "$c" | grep -q "job create" \
        && echo "$c" | grep -q -- "--mount-data-store /mnt/reports=ce-pds-9ef3:cleanup" \
        && echo "$c" | grep -q -- "--env-from-secret cleanup-api-key" \
        && echo "$c" | grep -q -- "--registry-secret reg"; then
        check create_sets_mount_secret_and_registry ok
    else
        check create_sets_mount_secret_and_registry fail
    fi
}


test_api_key_not_on_command_line() {
    job_json none "" none
    run_deploy 1
    if [ "$RC" -eq 0 ] && ! grep -q 's3cr3t-key-value' "$LOG" && grep -q -- '--from-env-file' "$LOG"; then
        check api_key_not_on_command_line ok
    else
        check api_key_not_on_command_line fail
    fi
}

test_fails_when_not_logged_in() {
    job_json none "" none
    STUB_LOGGED_IN=0 run_deploy 1
    if [ "$RC" -ne 0 ] && grep -qi 'not logged in' "$TMP/err" && ! grep -q 'secret' "$LOG"; then
        check fails_when_not_logged_in ok
    else
        check fails_when_not_logged_in fail
    fi
}

test_removes_legacy_cos_env() {
    job_json /mnt/reports cleanup cleanup-api-key COS_BUCKET_NAME
    run_deploy 1
    if [ "$RC" -eq 0 ] && calls | grep -q -- '--env-rm COS_BUCKET_NAME'; then
        check removes_legacy_cos_env ok
    else
        check removes_legacy_cos_env fail
    fi
}

test_no_env_rm_when_absent() {
    job_json /mnt/reports cleanup cleanup-api-key
    run_deploy 1
    if [ "$RC" -eq 0 ] && ! calls | grep -q -- '--env-rm'; then
        check no_env_rm_when_absent ok
    else
        check no_env_rm_when_absent fail
    fi
}

test_creates_cron_when_missing() {
    job_json /mnt/reports cleanup cleanup-api-key
    STUB_CRON_EXISTS=0 run_deploy 1
    if [ "$RC" -eq 0 ] && grep -q 'subscription cron create --name weekly-cleanup-cron' "$LOG" \
        && grep -q -- "--schedule 0 13 \* \* 1" "$LOG" && grep -q -- '--time-zone UTC' "$LOG"; then
        check creates_cron_when_missing ok
    else
        check creates_cron_when_missing fail
    fi
}

test_updates_cron_when_present() {
    job_json /mnt/reports cleanup cleanup-api-key
    STUB_CRON_EXISTS=1 run_deploy 1
    if [ "$RC" -eq 0 ] && grep -q 'subscription cron update --name weekly-cleanup-cron' "$LOG" \
        && ! grep -q 'subscription cron create' "$LOG"; then
        check updates_cron_when_present ok
    else
        check updates_cron_when_present fail
    fi
}

test_warns_on_public_registry_hostname() {
    job_json /mnt/reports cleanup cleanup-api-key
    IMAGE_UNDER_TEST=ca.icr.io/ns/img:v1 run_deploy 1
    if grep -q 'private.ca.icr.io' "$TMP/err"; then
        check warns_on_public_registry_hostname ok
    else
        check warns_on_public_registry_hostname fail
    fi
}

test_update_skips_existing_mount_and_secret
test_update_adds_missing_mount_and_secret
test_update_replaces_mount_with_different_subpath
test_create_sets_mount_secret_and_registry
test_api_key_not_on_command_line
test_fails_when_not_logged_in
test_removes_legacy_cos_env
test_no_env_rm_when_absent
test_creates_cron_when_missing
test_updates_cron_when_present
test_warns_on_public_registry_hostname

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

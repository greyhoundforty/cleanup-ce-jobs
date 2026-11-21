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
esac
exit 0
EOF
chmod +x "$TMP/bin/ibmcloud"

# job_json <mountPath|none> <subPath> <secret|none>
job_json() {
    local mounts='[]' envfrom='[]'
    [ "$1" != none ] && mounts="[{\"name\":\"m\",\"mountPath\":\"$1\",\"subPath\":\"$2\"}]"
    [ "$3" != none ] && envfrom="[{\"secretRef\":{\"name\":\"$3\"}}]"
    echo "{\"spec\":{\"template\":{\"containers\":[{\"volumeMounts\":${mounts},\"envFrom\":${envfrom}}]}}}" > "$TMP/job.json"
}

# run_deploy <job-exists 0|1>: sets RC, log in $LOG.
run_deploy() {
    LOG="$TMP/calls.log"
    : > "$LOG"
    STUB_LOG="$LOG" STUB_JOB_JSON="$TMP/job.json" STUB_JOB_EXISTS="$1" \
        PATH="$TMP/bin:$PATH" CE_PROJECT=p IMAGE=img:v1 IBMCLOUD_API_KEY=k \
        REGISTRY_SECRET=reg bash "$SCRIPT" >/dev/null 2>&1
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

test_update_skips_existing_mount_and_secret
test_update_adds_missing_mount_and_secret
test_update_replaces_mount_with_different_subpath
test_create_sets_mount_secret_and_registry

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

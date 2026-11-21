#!/bin/bash
# Tests for entrypoint.sh using a stubbed ibmcloud and a stub cleanup script.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRYPOINT="$ROOT/entrypoint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

mkdir -p "$TMP/bin"
cat > "$TMP/bin/ibmcloud" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
if [ "${STUB_LOGIN_OK:-1}" != 1 ]; then
    echo "Unable to authenticate: invalid API key" >&2
    exit 1
fi
exit 0
EOF
chmod +x "$TMP/bin/ibmcloud"

# Stub cleanup script: records that it ran and exits with STUB_SCRIPT_RC.
cat > "$TMP/cleanup.sh" <<'EOF'
#!/bin/bash
echo ran >> "$STUB_LOG"
exit "${STUB_SCRIPT_RC:-0}"
EOF
chmod +x "$TMP/cleanup.sh"

# run_entrypoint [VAR=value ...]: sets RC, log in $LOG.
run_entrypoint() {
    LOG="$TMP/calls.log"
    : > "$LOG"
    env -i PATH="$TMP/bin:$PATH" STUB_LOG="$LOG" CLEANUP_SCRIPT="$TMP/cleanup.sh" \
        "$@" bash "$ENTRYPOINT" >"$TMP/out" 2>"$TMP/err"
    RC=$?
}

check() {
    if [ "$2" = "ok" ]; then PASS=$((PASS + 1)); echo "PASS: $1"; else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}

test_login_failure_stops_with_message() {
    run_entrypoint IBMCLOUD_API_KEY=bad-key-123 STUB_LOGIN_OK=0
    if [ "$RC" -ne 0 ] && grep -q 'ibmcloud login failed' "$TMP/err" \
        && grep -q 'invalid API key' "$TMP/err" && ! grep -q '^ran' "$LOG"; then
        check login_failure_stops_with_message ok
    else
        check login_failure_stops_with_message fail
    fi
}

test_missing_api_key_stops_with_message() {
    run_entrypoint
    if [ "$RC" -ne 0 ] && grep -q 'IBMCLOUD_API_KEY is not set' "$TMP/err" && ! grep -q '^ran' "$LOG"; then
        check missing_api_key_stops_with_message ok
    else
        check missing_api_key_stops_with_message fail
    fi
}

test_login_then_runs_script() {
    run_entrypoint IBMCLOUD_API_KEY=good-key-123
    if [ "$RC" -eq 0 ] && grep -q '^login' "$LOG" && grep -q '^ran' "$LOG"; then
        check login_then_runs_script ok
    else
        check login_then_runs_script fail
    fi
}

test_script_exit_code_propagates() {
    run_entrypoint IBMCLOUD_API_KEY=good-key-123 STUB_SCRIPT_RC=7
    if [ "$RC" -eq 7 ]; then
        check script_exit_code_propagates ok
    else
        check script_exit_code_propagates fail
    fi
}

test_api_key_not_echoed() {
    run_entrypoint IBMCLOUD_API_KEY=good-key-123 STUB_LOGIN_OK=0
    if ! grep -q 'good-key-123' "$TMP/out" "$TMP/err"; then
        check api_key_not_echoed ok
    else
        check api_key_not_echoed fail
    fi
}

test_login_targets_ce_region() {
    run_entrypoint IBMCLOUD_API_KEY=good-key-123 CE_REGION=ca-tor
    if [ "$RC" -eq 0 ] && grep -q '^login .* -r ca-tor' "$LOG"; then
        check login_targets_ce_region ok
    else
        check login_targets_ce_region fail
    fi
}

test_login_region_override() {
    run_entrypoint IBMCLOUD_API_KEY=good-key-123 CE_REGION=ca-tor IBMCLOUD_REGION=us-south
    if [ "$RC" -eq 0 ] && grep -q '^login .* -r us-south' "$LOG"; then
        check login_region_override ok
    else
        check login_region_override fail
    fi
}

test_login_without_region_env_skips_region() {
    run_entrypoint IBMCLOUD_API_KEY=good-key-123
    if [ "$RC" -eq 0 ] && grep -q '^login .*--no-region' "$LOG"; then
        check login_without_region_env_skips_region ok
    else
        check login_without_region_env_skips_region fail
    fi
}

test_login_failure_stops_with_message
test_missing_api_key_stops_with_message
test_login_then_runs_script
test_script_exit_code_propagates
test_api_key_not_echoed
test_login_targets_ce_region
test_login_region_override
test_login_without_region_env_skips_region

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

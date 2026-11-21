#!/bin/bash
# Tests for weekly_cleanup_report.sh using a stubbed ibmcloud on PATH.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/weekly_cleanup_report.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# make_stub <json> <exit-code>: install a fake ibmcloud that prints json.
make_stub() {
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/ibmcloud" <<EOF
#!/bin/bash
cat <<'JSON'
$1
JSON
exit $2
EOF
    chmod +x "$TMP/bin/ibmcloud"
}

# run_script <report_dir>: sets RC and ERR.
run_script() {
    ERR="$TMP/stderr"
    PATH="$TMP/bin:$PATH" REPORT_DIR="$1" bash "$SCRIPT" >"$TMP/stdout" 2>"$ERR"
    RC=$?
}

check() {
    if [ "$2" = "ok" ]; then
        PASS=$((PASS + 1))
        echo "PASS: $1"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $1"
    fi
}

ITEMS='{"items":[{"name":"vm1","region":"ca-tor","service_name":"is","crn":"crn:v1:abc"}]}'

test_writes_report_in_report_dir() {
    local dir="$TMP/t1"
    mkdir -p "$dir"
    make_stub "$ITEMS" 0
    run_script "$dir"
    local f
    f=$(ls "$dir"/cleanup_report_*.txt 2>/dev/null | head -1)
    if [ "$RC" -eq 0 ] && [ -n "$f" ] && grep -q 'vm1 | ca-tor | is | crn:v1:abc' "$f"; then
        check writes_report_in_report_dir ok
    else
        check writes_report_in_report_dir fail
    fi
}

test_creates_missing_dir() {
    local dir="$TMP/t2/nested/reports"
    make_stub "$ITEMS" 0
    run_script "$dir"
    if [ "$RC" -eq 0 ] && ls "$dir"/cleanup_report_*.txt >/dev/null 2>&1; then
        check creates_missing_dir ok
    else
        check creates_missing_dir fail
    fi
}

test_unwritable_dir_fails() {
    local dir="$TMP/t3"
    mkdir -p "$dir"
    chmod 555 "$dir"
    make_stub "$ITEMS" 0
    run_script "$dir"
    chmod 755 "$dir"
    if [ "$RC" -ne 0 ] && grep -q 'not writable' "$ERR"; then
        check unwritable_dir_fails ok
    else
        check unwritable_dir_fails fail
    fi
}

test_no_results_leaves_no_file() {
    local dir="$TMP/t4"
    mkdir -p "$dir"
    make_stub '{"items":[]}' 0
    run_script "$dir"
    if [ "$RC" -eq 0 ] && [ -z "$(ls -A "$dir")" ]; then
        check no_results_leaves_no_file ok
    else
        check no_results_leaves_no_file fail
    fi
}

test_search_failure_fails() {
    local dir="$TMP/t5"
    mkdir -p "$dir"
    make_stub '' 1
    run_script "$dir"
    if [ "$RC" -ne 0 ] && [ -z "$(ls -A "$dir")" ]; then
        check search_failure_fails ok
    else
        check search_failure_fails fail
    fi
}

test_writes_report_in_report_dir
test_creates_missing_dir
test_unwritable_dir_fails
test_no_results_leaves_no_file
test_search_failure_fails

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

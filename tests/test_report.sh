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

test_empty_result_writes_empty_reports() {
    local dir="$TMP/t4"
    mkdir -p "$dir"
    make_stub '{"items":[]}' 0
    run_script "$dir"
    local t j c
    t=$(report "$dir" txt); j=$(report "$dir" json); c=$(report "$dir" csv)
    if [ "$RC" -eq 0 ] && [ -n "$t" ] && [ -n "$j" ] && [ -n "$c" ] \
        && [ "$(jq -c . "$j")" = '[]' ] \
        && [ "$(cat "$c")" = "$CSV_HEADER" ] \
        && [ "$(cat "$t")" = 'No resources found with tag owner:ryantiffany.' ] \
        && ! ls "$dir"/*.tmp >/dev/null 2>&1; then
        check empty_result_writes_empty_reports ok
    else
        check empty_result_writes_empty_reports fail
    fi
}

test_empty_rerun_replaces_earlier_report() {
    local dir="$TMP/t13"
    mkdir -p "$dir"
    make_stub "$ITEMS" 0
    run_script "$dir"
    make_stub '{"items":[]}' 0
    run_script "$dir"
    local t c
    t=$(report "$dir" txt); c=$(report "$dir" csv)
    local j
    j=$(report "$dir" json)
    if [ "$RC" -eq 0 ] && [ "$(cat "$c")" = "$CSV_HEADER" ] && grep -q 'No resources found' "$t" \
        && [ "$(jq -c . "$j")" = '[]' ]; then
        check empty_rerun_replaces_earlier_report ok
    else
        check empty_rerun_replaces_earlier_report fail
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

test_failed_rerun_keeps_existing_report() {
    local dir="$TMP/t6"
    mkdir -p "$dir"
    make_stub "$ITEMS" 0
    run_script "$dir"
    make_stub '' 1
    run_script "$dir"
    local f
    f=$(ls "$dir"/cleanup_report_*.txt 2>/dev/null | head -1)
    if [ "$RC" -ne 0 ] && [ -n "$f" ] && grep -q 'vm1' "$f" && ! ls "$dir"/*.tmp >/dev/null 2>&1 \
        && [ -n "$(report "$dir" json)" ] && [ -n "$(report "$dir" csv)" ]; then
        check failed_rerun_keeps_existing_report ok
    else
        check failed_rerun_keeps_existing_report fail
    fi
}

test_default_dir_requires_mount() {
    make_stub "$ITEMS" 0
    ERR="$TMP/stderr"
    env -u REPORT_DIR PATH="$TMP/bin:$PATH" bash "$SCRIPT" >"$TMP/stdout" 2>"$ERR"
    RC=$?
    if [ "$RC" -ne 0 ] && grep -q 'not mounted' "$ERR"; then
        check default_dir_requires_mount ok
    else
        check default_dir_requires_mount fail
    fi
}

ITEMS2='{"items":[
 {"name":"vm1","region":"ca-tor","service_name":"is","type":"resource-instance","resource_group_id":"rg1","creation_date":"2026-01-02T03:04:05Z","tags":["owner:ryantiffany","deleteme"],"crn":"crn:v1:abc"},
 {"name":"a, \"b\"","service_name":"kms","type":"key","crn":"crn:v1:def"}]}'

CSV_HEADER='delete,name,service_name,type,region,resource_group_id,creation_date,tags,crn'

# report <dir> <ext>: path of the report with that extension, or empty.
report() { ls "$1"/cleanup_report_*."$2" 2>/dev/null | head -1; }

test_writes_all_three_formats() {
    local dir="$TMP/t8"
    mkdir -p "$dir"
    make_stub "$ITEMS2" 0
    run_script "$dir"
    local t j c
    t=$(report "$dir" txt); j=$(report "$dir" json); c=$(report "$dir" csv)
    if [ "$RC" -eq 0 ] && [ -n "$t" ] && [ -n "$j" ] && [ -n "$c" ] \
        && grep -q 'vm1 | ca-tor | is | crn:v1:abc' "$t"; then
        check writes_all_three_formats ok
    else
        check writes_all_three_formats fail
    fi
}

test_csv_header_and_rows() {
    local dir="$TMP/t9"
    mkdir -p "$dir"
    make_stub "$ITEMS2" 0
    run_script "$dir"
    local c
    c=$(report "$dir" csv)
    if [ "$RC" -eq 0 ] && [ -n "$c" ] \
        && [ "$(sed -n 1p "$c")" = "$CSV_HEADER" ] \
        && [ "$(sed -n 2p "$c")" = '"no","vm1","is","resource-instance","ca-tor","rg1","2026-01-02T03:04:05Z","owner:ryantiffany;deleteme","crn:v1:abc"' ] \
        && [ "$(sed -n 3p "$c")" = '"no","a, ""b""","kms","key","","","","","crn:v1:def"' ] \
        && [ "$(wc -l < "$c" | tr -d ' ')" = 3 ]; then
        check csv_header_and_rows ok
    else
        check csv_header_and_rows fail
    fi
}

test_json_matches_items() {
    local dir="$TMP/t10"
    mkdir -p "$dir"
    make_stub "$ITEMS2" 0
    run_script "$dir"
    local j
    j=$(report "$dir" json)
    if [ "$RC" -eq 0 ] && [ -n "$j" ] \
        && [ "$(jq -S . "$j")" = "$(echo "$ITEMS2" | jq -S .items)" ]; then
        check json_matches_items ok
    else
        check json_matches_items fail
    fi
}

test_non_json_output_fails() {
    local dir="$TMP/t11"
    mkdir -p "$dir"
    make_stub 'not json' 0
    run_script "$dir"
    if [ "$RC" -ne 0 ] && [ -z "$(ls -A "$dir")" ]; then
        check non_json_output_fails ok
    else
        check non_json_output_fails fail
    fi
}

test_rerun_replaces_all_three() {
    local dir="$TMP/t12"
    mkdir -p "$dir"
    make_stub "$ITEMS" 0
    run_script "$dir"
    make_stub "$ITEMS2" 0
    run_script "$dir"
    local t j c
    t=$(report "$dir" txt); j=$(report "$dir" json); c=$(report "$dir" csv)
    if [ "$RC" -eq 0 ] && [ -n "$c" ] && [ "$(wc -l < "$c" | tr -d ' ')" = 3 ] \
        && [ "$(jq length "$j")" = 2 ] && grep -q 'crn:v1:def' "$t"; then
        check rerun_replaces_all_three ok
    else
        check rerun_replaces_all_three fail
    fi
}

test_failed_csv_move_leaves_no_mixed_set() {
    local dir="$TMP/t14"
    mkdir -p "$dir" "$TMP/mvbin"
    make_stub "$ITEMS" 0
    run_script "$dir"
    # mv that fails only when moving the CSV into place
    cat > "$TMP/mvbin/mv" <<'EOF'
#!/bin/bash
case "${@: -1}" in *.csv) exit 1 ;; esac
exec /bin/mv "$@"
EOF
    chmod +x "$TMP/mvbin/mv"
    make_stub "$ITEMS2" 0
    ERR="$TMP/stderr"
    PATH="$TMP/mvbin:$TMP/bin:$PATH" REPORT_DIR="$dir" bash "$SCRIPT" >"$TMP/stdout" 2>"$ERR"
    RC=$?
    local c
    c=$(report "$dir" csv)
    # The earlier CSV survives intact; no newer txt/json sits beside it.
    if [ "$RC" -ne 0 ] && [ "$(wc -l < "$c" | tr -d ' ')" = 2 ] \
        && [ -z "$(report "$dir" txt)" ] && [ -z "$(report "$dir" json)" ] \
        && ! ls "$dir"/*.tmp >/dev/null 2>&1; then
        check failed_csv_move_leaves_no_mixed_set ok
    else
        check failed_csv_move_leaves_no_mixed_set fail
    fi
}

test_writes_report_in_report_dir
test_creates_missing_dir
test_unwritable_dir_fails
test_empty_result_writes_empty_reports
test_search_failure_fails
test_failed_rerun_keeps_existing_report
test_default_dir_requires_mount
test_writes_all_three_formats
test_csv_header_and_rows
test_json_matches_items
test_non_json_output_fails
test_rerun_replaces_all_three
test_empty_rerun_replaces_earlier_report
test_failed_csv_move_leaves_no_mixed_set

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

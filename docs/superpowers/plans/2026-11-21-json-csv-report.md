# JSON + CSV Weekly Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `weekly_cleanup_report.sh` writes `.txt`, `.json` and `.csv` reports from one search, all-or-nothing, including on empty results.

**Architecture:** One `ibmcloud resource search` into a temp file; three `jq` renders into `<file>.tmp`; `mv -f` all three only when every step succeeded, otherwise remove every `.tmp` and exit 1.

**Tech Stack:** bash, jq, shell tests with a stubbed `ibmcloud` (`tests/test_report.sh`).

**Spec:** `docs/superpowers/specs/2026-11-21-json-csv-report-design.md`

## Global Constraints

- File names: `cleanup_report_YYYY-MM-DD.txt|.json|.csv` in `REPORT_DIR` (default `/mnt/reports`; the existing `/proc/mounts` and writability checks stay as they are).
- CSV header, exactly: `delete,name,service_name,type,region,resource_group_id,creation_date,tags,crn`
- CSV `delete` is always `no`; `tags` joined with `;`; quoting via `jq` `@csv`; missing fields become `""`.
- JSON is the search's `.items` array (pretty-printed). Text line format unchanged: `name | region | service_name | crn`.
- Empty result text, exactly: `No resources found with tag owner:ryantiffany.`
- Do not change `entrypoint.sh`, `deploy.sh` or `Dockerfile`. All three test files must pass.
- `shellcheck` is not installed: run `bash -n weekly_cleanup_report.sh`.

## Review Focus

- A resource with no `tags` or no `region` field: CSV cell is empty, never the string `null` (test in Task 1).
- A name containing a comma and a double quote: CSV stays one correctly quoted row (test in Task 1).
- `ibmcloud` exits 0 but prints non-JSON: treated as failure, no files, no `.tmp` (test in Task 1).
- A successful same-day re-run with different results replaces all three files (test in Task 1).
- Empty-result run on top of an earlier report the same day replaces all three with the empty versions (test in Task 2).

---

### Task 1: Write three formats from one search, all-or-nothing

**Files:**
- Modify: `weekly_cleanup_report.sh:13-44`
- Test: `tests/test_report.sh`

**Interfaces:**
- Produces: the three files above; exit 0 on success, 1 on any search/render failure. Task 2 relies on a helper or code path where the empty case still goes through the same tmp + `mv` sequence.

- [ ] **Step 1: Write the failing tests** in `tests/test_report.sh` (add a helper `report <dir> <ext>` that echoes `ls "$dir"/cleanup_report_*.<ext> | head -1`). Use this fixture:

```bash
ITEMS2='{"items":[
 {"name":"vm1","region":"ca-tor","service_name":"is","type":"resource-instance","resource_group_id":"rg1","creation_date":"2026-01-02T03:04:05Z","tags":["owner:ryantiffany","deleteme"],"crn":"crn:v1:abc"},
 {"name":"a, \"b\"","service_name":"kms","type":"key","crn":"crn:v1:def"}]}'
```

  - `test_writes_all_three_formats`: RC 0; `.txt`, `.json`, `.csv` all exist; `.txt` contains `vm1 | ca-tor | is | crn:v1:abc`.
  - `test_csv_header_and_rows`: line 1 of the CSV equals the Global Constraints header exactly (unquoted); line 2 equals `"no","vm1","is","resource-instance","ca-tor","rg1","2026-01-02T03:04:05Z","owner:ryantiffany;deleteme","crn:v1:abc"`; line 3 equals `"no","a, ""b""","kms","key","","","","","crn:v1:def"`; `wc -l` is 3.
  - `test_json_matches_items`: `jq -S . "$json"` equals `echo "$ITEMS2" | jq -S .items`.
  - `test_non_json_output_fails`: stub prints `not json` with exit 0 → RC ≠ 0, directory empty (no reports, no `.tmp`).
  - `test_rerun_replaces_all_three`: run with `$ITEMS`, then with `$ITEMS2` → `.csv` has 3 lines, `.json` length 2, `.txt` contains `crn:v1:def`.
  - Update `test_failed_rerun_keeps_existing_report` to also assert `.json` and `.csv` still exist, and that no `*.tmp` remains.

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `bash tests/test_report.sh`
Expected: the five new/updated tests FAIL (no `.json`/`.csv`), the others PASS.

- [ ] **Step 3: Implement in `weekly_cleanup_report.sh`**

  - `BASE="${REPORT_DIR}/cleanup_report_${TIMESTAMP}"`; outputs `${BASE}.txt|.json|.csv`; temps are each output plus `.tmp`, plus `${BASE}.search.tmp` for the raw search.
  - A `cleanup_tmp` function removing all four temps; call it on every failure path before `exit 1`.
  - Search: `ibmcloud resource search "tags:\"${TAG}\"" --output json > "$SEARCH_TMP"`; then validate with `jq -e '.items | type == "array"'` (fails on non-JSON and missing `items`) → on failure print `ERROR: resource search failed.` and exit 1.
  - Renders (each must succeed, chained with `&&` or checked individually): text as today; JSON `jq '.items'`; CSV header written as the plain header line (`printf '%s\n'`), then `jq -r '.items[] | ["no", .name, .service_name, .type, .region, .resource_group_id, .creation_date, ((.tags // []) | join(";")), .crn] | map(. // "") | @csv'` appended. Render failure prints `ERROR: report write failed.` (this also fixes the deferred "write failure reported as search failure" minor).
  - On success `mv -f` each `.tmp` onto its output, remove the search temp, print `Report generated successfully: ${BASE}.{txt,json,csv}`.
  - Leave the empty-result branch as it is for now (Task 2 changes it); it must still clean up all temps.

- [ ] **Step 4: Run all tests**

Run: `bash -n weekly_cleanup_report.sh && bash tests/test_report.sh && bash tests/test_deploy.sh && bash tests/test_entrypoint.sh`
Expected: all PASS (the existing `test_no_results_leaves_no_file` still passes at this point).

- [ ] **Step 5: Commit**

```bash
git add weekly_cleanup_report.sh tests/test_report.sh
git commit -m "feat: write JSON and CSV reports alongside text (#1)"
```

### Task 2: Empty results write all three files; update docs

**Files:**
- Modify: `weekly_cleanup_report.sh` (empty-result branch)
- Test: `tests/test_report.sh`
- Modify: `CLAUDE.md` (In progress section → describe the new outputs; drop the fixed deferred minor)

**Interfaces:**
- Consumes: Task 1's temp/`mv` sequence and `cleanup_tmp`.

- [ ] **Step 1: Write the failing tests**
  - Replace `test_no_results_leaves_no_file` with `test_empty_result_writes_empty_reports`: stub `{"items":[]}` → RC 0; `.json` content is `[]` (`jq -c . file` equals `[]`); `.csv` is exactly the header line (1 line); `.txt` equals `No resources found with tag owner:ryantiffany.`; no `*.tmp`.
  - `test_empty_rerun_replaces_earlier_report`: run with `$ITEMS`, then `{"items":[]}` → `.csv` has 1 line, `.txt` contains `No resources found`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_report.sh`
Expected: the two new tests FAIL.

- [ ] **Step 3: Implement**: when `.items` is empty, write the text line from Global Constraints to the text temp (JSON and CSV renders already yield `[]` and header-only), then go through the same `mv -f` path. Print `No resources found with tag ${TAG}.` to stdout as well.

- [ ] **Step 4: Run all tests**

Run: `bash -n weekly_cleanup_report.sh && bash tests/test_report.sh && bash tests/test_deploy.sh && bash tests/test_entrypoint.sh`
Expected: all PASS.

- [ ] **Step 5: Update `CLAUDE.md`**: Layout line for the report script mentions txt/json/csv; replace the "In progress" status with "implemented on `main`, ships as v4 (not yet built)"; remove the "write failure is reported as resource search failed" deferred minor; note the CSV column contract that issue #2 will read.

- [ ] **Step 6: Commit**

```bash
git add weekly_cleanup_report.sh tests/test_report.sh CLAUDE.md
git commit -m "feat: empty runs write empty JSON/CSV/text reports (#1)"
```

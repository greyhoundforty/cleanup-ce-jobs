# JSON + CSV weekly report — design

Issue: https://github.com/greyhoundforty/cleanup-ce-jobs/issues/1
Status: approved 2026-11-21. Size: small change.

## Intent

The weekly report becomes the first half of a review-then-delete flow:

1. The report job runs the day before cleanup and writes a CSV to the PDS mount
   (bucket `rst-usage-bucket-9yk456iwqnolk6p`, prefix `cleanup/`).
2. The user edits the CSV, marking rows to delete, and uploads it to a separate bucket.
3. A cleanup job (issue #2, out of scope here) starts when a CSV lands in that
   bucket and deletes only resources marked `yes` **and** tagged both `deleteme`
   and `owner:ryantiffany`.

The JSON is for the user's own tracking, and possibly a future review file if a
frontend editor that loads JSON from COS turns up. It is never edited by this flow.

## Goals

- Write `cleanup_report_YYYY-MM-DD.json` and `.csv` alongside the existing `.txt`.
- CSV is a spreadsheet-friendly review sheet that a script can read back reliably.
- JSON keeps every field the search returns.

## Non-goals

- Reading the CSV back, the second bucket, COS event subscriptions, deleting anything (issue #2).
- Changing `entrypoint.sh`, `deploy.sh`, the cron, the mount or the image layout.
- Resolving resource group IDs to names.

## Anti-goals

- A CSV that could cause a delete without an explicit edit: `delete` is always `no` as generated.
- A partial set of files from a failed run, or a failed re-run clobbering an earlier good report.

## Approaches considered

- **Single search, render three formats with `jq` in the existing bash script (picked).**
  Fits the project (bash + jq + stub-based shell tests), one search keeps the files consistent.
- Rewrite in Python: changes the image and the test harness for no gain.
- One search per format: three files could disagree.

## Design

**Files** in `REPORT_DIR` (default `/mnt/reports`, existing mount check unchanged):

| File | Content |
|------|---------|
| `cleanup_report_YYYY-MM-DD.txt` | Unchanged: one line per resource, `name \| region \| service_name \| crn` |
| `cleanup_report_YYYY-MM-DD.json` | The search's `.items` array as returned (pretty-printed) |
| `cleanup_report_YYYY-MM-DD.csv` | Header row plus one row per resource (below) |

**CSV columns**, in order:

```
delete,name,service_name,type,region,resource_group_id,creation_date,tags,crn
```

- `delete`: always `no` as generated (the user changes it to `yes`).
- `tags`: the resource's `tags` joined with `;`.
- All fields quoted with `jq`'s `@csv`; missing fields become empty strings.
- `delete` first for easy editing; `crn` last because it is long and is the key
  issue #2 will match on.

**All-or-nothing write**: the search runs once into memory/a temp file; each format
renders to `<file>.tmp`; only if all three renders succeed are they `mv -f`'d into
place. On any failure every `.tmp` is removed, existing reports are untouched, and
the script exits non-zero.

**Empty result** (behavior change; previously no file): write all three files.
JSON is `[]`, CSV is the header row only, text contains
`No resources found with tag owner:ryantiffany.` This distinguishes "ran, found
nothing" from "did not run".

## Testing

Additions/changes in `tests/test_report.sh` (stubbed `ibmcloud`):

- all three files written; text line format unchanged
- CSV header exact; a name containing a comma and a quote is quoted correctly
- every CSV row has `delete` = `no`; tags joined with `;`
- JSON equals the stub's `.items`
- empty result writes `[]`, header-only CSV and the "No resources found" text
  (replaces `test_no_results_leaves_no_file`)
- search failure leaves no files and no `.tmp`; failed re-run keeps all three earlier files

Existing entrypoint and deploy tests must keep passing.

## Left to the builder

- Exact `jq` expressions and temp-file handling.
- Whether the search result is held in a variable or a temp file.

## Rollout

Ships as image v4 with the entrypoint fix already on `main` (`43fd5fe`), pushed to
`private.ca.icr.io/rst-icr-ca/weekly-cleanup:v4` and applied with `deploy.sh`.

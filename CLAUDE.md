# cleanup-code-engine

Weekly IBM Cloud Code Engine job that lists resources tagged `owner:ryantiffany`
and writes a report to a persistent data store (PDS) mount backed by COS.
Repo: `greyhoundforty/cleanup-ce-jobs` (origin, branch `main`).

## Layout
- `weekly_cleanup_report.sh`: one search, writes `cleanup_report_YYYY-MM-DD.txt|.json|.csv` to `${REPORT_DIR:-/mnt/reports}` (all-or-nothing; empty runs write `[]`, header-only CSV, "No resources found" text)
- `entrypoint.sh`: validates `IBMCLOUD_API_KEY`, `ibmcloud login`, then execs the report script
- `Dockerfile`: ubuntu:24.04 + jq + IBM Cloud CLI; copies both scripts
- `deploy.sh`: idempotent create/update of secret, job and cron subscription
- `tests/test_report.sh`, `tests/test_deploy.sh`, `tests/test_entrypoint.sh`: shell tests using a stubbed `ibmcloud`
- `docs/superpowers/specs|plans/`: designs and plans (PDS mount: done; JSON/CSV report: done)

## Run the tests
```bash
bash tests/test_report.sh && bash tests/test_deploy.sh && bash tests/test_entrypoint.sh
```
`shellcheck` is not installed locally; use `bash -n` plus review (or install it).

## Deployed state (as of 2026-11-21)
- Project `rst-ce-demo`, job `weekly-cleanup`, cron `weekly-cleanup-cron` (`0 13 * * 1` UTC)
- PDS `ce-pds-9ef3` -> bucket `rst-usage-bucket-9yk456iwqnolk6p` (ca-tor), mounted at `/mnt/reports` with subpath `cleanup`
- Job runs image `private.ca.icr.io/rst-icr-ca/weekly-cleanup:v5` (JSON/CSV report + login region fix). v4 is broken (login region prompt); do not use.
- Secrets: `cleanup-api-key` (job env `IBMCLOUD_API_KEY`), registry secret `ca-rst-icr-key`
- Verified with jobrun `cleanup-v5-test-1` plus a `--command` listing run: txt/json/csv written to `/mnt/reports`, same-day `mv -f` overwrite works on the PDS, so the PDS credential can write.

## Build and deploy
- Build: `docker build --platform linux/amd64 -t ca.icr.io/rst-icr-ca/weekly-cleanup:vN .` then `docker push` (push via `ca.icr.io`; `private.ca.icr.io` is only reachable inside IBM Cloud, but the job pulls from it).
- Deploy: the user keeps `.env.deploy` (git-ignored, mode 600; template `.env.deploy.example`). Never read or print it. Run
  `set -a; . ./.env.deploy; set +a; ./deploy.sh` (override `IMAGE=...` inline if the file lags behind).
- Inspect the mount without COS CLI config: `ibmcloud ce jobrun submit --job weekly-cleanup --name <n> --command /bin/sh --argument -c --argument 'ls -la /mnt/reports'`.

## Gotchas learned the hard way
- Registry host: the registry secret is for `private.ca.icr.io`. Using `ca.icr.io` gives a 401 on pull. `ca-tor.icr.io` does not exist. Build for `--platform linux/amd64`.
- `--mount-data-store` subpath must NOT start with `/` (`ce-pds-9ef3:cleanup`).
- `job update` mount/secret flags are add-only and fail as duplicates; `deploy.sh` checks the live job and adds only what is missing.
- `ibmcloud login` has no `--non-interactive` flag, and `--apikey ... -q` still prompts for a region (EOF in a job) unless given `-r REGION` or `--no-region`; `entrypoint.sh` uses `IBMCLOUD_REGION`, else `CE_REGION`, else `--no-region`.
- Never print `ibmcloud ce registry get` output: it includes the encoded credentials (the key behind `ca-rst-icr-key` leaked into a session once; user is rotating it and will move to a new secret name, which means changing `SECRET_NAME` in `deploy.sh` and the `REGISTRY_SECRET` env var).
- Default `REPORT_DIR` must be a real mount (`/proc/mounts` check) so reports are never silently written to ephemeral storage.

## JSON + CSV report (issue #1)
https://github.com/greyhoundforty/cleanup-ce-jobs/issues/1

Status (2026-11-21): **implemented on branch `feat/json-csv-report`** (spec
`docs/superpowers/specs/2026-11-21-json-csv-report-design.md`, plan
`docs/superpowers/plans/2026-11-21-json-csv-report.md`). Merged (PR #3); deployed as v5.

Why (drives the CSV contract): the CSV is a review sheet. The user edits it the day before
cleanup (sets `delete` to `yes`), uploads it to a separate bucket, and issue #2's cleanup job
triggers on that upload and deletes only rows marked `yes` AND tagged both `deleteme` and
`owner:ryantiffany`. The JSON is for the user's own tracking (maybe a future review file).
CSV contract issue #2 will read: unquoted header
`delete,name,service_name,type,region,resource_group_id,creation_date,tags,crn`; data rows fully
quoted via `@csv`; `delete` generated as `no`; `tags` joined with `;`; missing fields empty; key is `crn`.


## Backlog: delete resources tagged `deleteme` (issue #2)
https://github.com/greyhoundforty/cleanup-ce-jobs/issues/2

Not started; needs brainstorming and an approved design first (it is destructive). Open
questions are listed in the issue: exact tag form, whether to also require `owner:ryantiffany`,
dry-run by default, resource types and deletion order, reclaim vs permanent delete, same job vs
separate job, audit log, and the broader IAM access the API key would need.

Notes from the #1 final review the #2 reader must handle:
- Re-check `deleteme` + `owner:ryantiffany` on the live resource; the CSV `tags` column is an editable snapshot.
- Use a real CSV parser (names could contain newlines/commas/quotes); tolerate CRLF and a BOM (Excel re-saves).
- Skip rows with an empty `crn`; consider spreadsheet formula-injection when values start with `= + - @`.

## Deferred minors (from final review)
- Deferred minors from the #1 review (M1-M8) are listed in PR #3

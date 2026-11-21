# cleanup-code-engine

Weekly IBM Cloud Code Engine job that lists resources tagged `owner:ryantiffany`
and writes a report to a persistent data store (PDS) mount backed by COS.
Repo: `greyhoundforty/cleanup-ce-jobs` (origin, branch `main`).

## Layout
- `weekly_cleanup_report.sh`: one search, writes `cleanup_report_YYYY-MM-DD.txt|.json|.csv` to `${REPORT_DIR:-/mnt/reports}` (all-or-nothing; empty runs write `[]`, header-only CSV, "No resources found" text)
- `entrypoint.sh`: validates `IBMCLOUD_API_KEY`, `ibmcloud login`, then execs the report script
- `deleteme_cleanup.py` + `deleteme/` (csvin, protect, cloud, engine): issue #2 cleanup job (Python 3.12 stdlib, shells out to `ibmcloud`); run via `CLEANUP_SCRIPT=/opt/cleanup/deleteme_cleanup.py`
- `Dockerfile`: ubuntu:24.04 + jq + python3 + IBM Cloud CLI; copies the report script, entrypoint and the deleteme package
- `deploy.sh`: idempotent create/update of secret, job and cron subscription (report job)
- `deploy_deleteme.sh`: idempotent create/update of the `deleteme-cleanup` job, its secret, review PDS and COS subscription
- `tests/test_report.sh`, `tests/test_deploy.sh`, `tests/test_entrypoint.sh`, `tests/test_deploy_deleteme.sh`: shell tests using a stubbed `ibmcloud`
- `tests/test_*.py`: pytest for the deleteme job; `tests/stub/ibmcloud` answers from fixture JSON and records calls
- `docs/superpowers/specs|plans/`: designs and plans (PDS mount, JSON/CSV report: done; deleteme cleanup: in progress)
- `docs/test-resources.md`: tagged ce-test-* resources in ca-tor for exercising the cleanup job

## Run the tests
```bash
bash tests/test_report.sh && bash tests/test_deploy.sh && bash tests/test_entrypoint.sh && bash tests/test_deploy_deleteme.sh
uvx --python 3.12 pytest tests -q && ruff check deleteme deleteme_cleanup.py tests && ruff format --check deleteme deleteme_cleanup.py tests
```
pytest is not installed locally; `uvx --python 3.12` matches the image's Python (plain `uvx` picks an older one).
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
- deleteme job: `set -a; . ./.env.deploy; set +a; ./deploy_deleteme.sh` (needs the `DELETEME_*`/`REVIEW_*` vars; deploys `DRY_RUN=true` unless `DELETEME_DRY_RUN=false`).
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


## deleteme cleanup job (issue #2)
https://github.com/greyhoundforty/cleanup-ce-jobs/issues/2

Status (2026-11-21): **implemented on branch `feat/deleteme-cleanup`**, not deployed (spec
`docs/superpowers/specs/2026-11-21-deleteme-cleanup-design.md`, plan
`docs/superpowers/plans/2026-11-21-deleteme-cleanup.md`). Rollout (plan Task 6) waits on the user
creating the review bucket, HMAC secret, service ID/key and Notifications Manager authorization.

Safety rules (do not weaken): delete only `yes` rows whose LIVE resource has both `deleteme` and
`owner:ryantiffany`, is not protected (built-in: `rst-ce-demo`, `rst-cos-instance`; plus
`CE_PROJECT_ID` and `PROTECTED_CRNS`), and only when `DRY_RUN` is exactly `false`. VPC `yes`
cascades only through subnets/gateways that carry both tags; any untagged, protected, `no`-marked
child or attached resource blocks the whole VPC. Service instances go to reclamation.
A CRN marked `yes` on one row and `no` on another is skipped (`SKIP_CONFLICT`).
The report writes `no` on every row, so to delete a VPC mark the VPC and its subnets/gateways `yes`.

## Deferred minors (from final review)
- Deferred minors from the #1 review (M1-M8) are listed in PR #3

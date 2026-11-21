# cleanup-code-engine

Weekly IBM Cloud Code Engine job that lists resources tagged `owner:ryantiffany`
and writes a report to a persistent data store (PDS) mount backed by COS.
Repo: `greyhoundforty/cleanup-ce-jobs` (origin, branch `main`).

## Layout
- `weekly_cleanup_report.sh`: search + write report to `${REPORT_DIR:-/mnt/reports}`
- `entrypoint.sh`: validates `IBMCLOUD_API_KEY`, `ibmcloud login`, then execs the report script
- `Dockerfile`: ubuntu:24.04 + jq + IBM Cloud CLI; copies both scripts
- `deploy.sh`: idempotent create/update of secret, job and cron subscription
- `tests/test_report.sh`, `tests/test_deploy.sh`, `tests/test_entrypoint.sh`: shell tests using a stubbed `ibmcloud`
- `docs/superpowers/specs|plans/`: design and plan for the PDS-mount work (done)

## Run the tests
```bash
bash tests/test_report.sh && bash tests/test_deploy.sh && bash tests/test_entrypoint.sh
```
`shellcheck` is not installed locally; use `bash -n` plus review (or install it).

## Deployed state (as of 2026-11-21)
- Project `rst-ce-demo`, job `weekly-cleanup`, cron `weekly-cleanup-cron` (`0 13 * * 1` UTC)
- PDS `ce-pds-9ef3` -> bucket `rst-usage-bucket-9yk456iwqnolk6p` (ca-tor), mounted at `/mnt/reports` with subpath `cleanup`
- Job runs image `private.ca.icr.io/rst-icr-ca/weekly-cleanup:v3` (v3 predates the entrypoint fix; not yet rebuilt)
- Secrets: `cleanup-api-key` (job env `IBMCLOUD_API_KEY`), registry secret `ca-rst-icr-key`
- A test jobrun succeeded and wrote `/mnt/reports/cleanup_report_<date>.txt`; the file in the bucket under `cleanup/` has NOT been confirmed from here (local `ibmcloud cos` plugin has no CRN configured)

## Gotchas learned the hard way
- Registry host: the registry secret is for `private.ca.icr.io`. Using `ca.icr.io` gives a 401 on pull. `ca-tor.icr.io` does not exist. Build for `--platform linux/amd64`.
- `--mount-data-store` subpath must NOT start with `/` (`ce-pds-9ef3:cleanup`).
- `job update` mount/secret flags are add-only and fail as duplicates; `deploy.sh` checks the live job and adds only what is missing.
- `ibmcloud login` has no `--non-interactive` flag; `--apikey ... -q` is already non-interactive.
- Never print `ibmcloud ce registry get` output: it includes the encoded credentials (the key behind `ca-rst-icr-key` leaked into a session once; user is rotating it and will move to a new secret name, which means changing `SECRET_NAME` in `deploy.sh` and the `REGISTRY_SECRET` env var).
- Default `REPORT_DIR` must be a real mount (`/proc/mounts` check) so reports are never silently written to ephemeral storage.

## In progress: JSON + CSV report (issue #1)
https://github.com/greyhoundforty/cleanup-ce-jobs/issues/1

Status: **brainstorming, waiting on the user's answer.** No design doc, plan or code yet
(the brainstorming gate applies: get the design approved, write the spec in
`docs/superpowers/specs/`, then use `superpowers:writing-plans`).

What is known:
- Current report: `name | region | service | crn`, built with `jq` from one `ibmcloud resource search` call.
- Search items also have `type`, `resource_group_id`, `creation_date`, `modification_date`, `tags`, `access_tags`, `service_tags`, `family`, `provider`, `resource_id`. Resource types seen: `key`, `resource-instance`, `vpc`.
- Draft approach (proposal only): one search, render txt/JSON/CSV with `jq` (`@csv`, header row), write all three to temp files and `mv` into place only if all succeed.

Open question asked of the user (unanswered): what reads these files and which fields/columns it needs.
Also unsettled: keep the text report or replace it; empty-run behavior (`[]` / header-only CSV vs no file).

Ships as image v4 together with the entrypoint fix already on `main` (commit `43fd5fe`). The user chose to hold v4 until this work is done.

## Backlog: delete resources tagged `deleteme` (issue #2)
https://github.com/greyhoundforty/cleanup-ce-jobs/issues/2

Not started; needs brainstorming and an approved design first (it is destructive). Open
questions are listed in the issue: exact tag form, whether to also require `owner:ryantiffany`,
dry-run by default, resource types and deletion order, reclaim vs permanent delete, same job vs
separate job, audit log, and the broader IAM access the API key would need. Do #1 first.

## Deferred minors (from final review)
- A report write failure is reported as "resource search failed" (`weekly_cleanup_report.sh`); probe-write the directory instead
- PDS credential's COS role (needs Writer) has not been verified
- `deploy.sh` has not been run end to end since the cron/env-file/env-rm changes (tests use a stub)

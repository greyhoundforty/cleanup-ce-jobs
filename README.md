# cleanup-ce-jobs

Two IBM Cloud Code Engine jobs for keeping a shared account tidy: a read-only weekly report of
everything tagged `owner:ryantiffany`, and a review-then-delete job that removes only what a
human has marked for deletion.

```
Monday 13:00 UTC          you                                  on upload
weekly-cleanup  ──▶  cleanup_report_YYYY-MM-DD.csv  ──▶  edit, set delete=yes  ──▶  deleteme-cleanup
(read-only)          in the reports bucket               upload to review/         (dry run by default)
```

## The jobs

### `weekly-cleanup` (report)

Runs every Monday at 13:00 UTC (cron `weekly-cleanup-cron`). It searches for resources tagged
`owner:ryantiffany` and writes three files to the reports bucket (`rst-usage-bucket-9yk456iwqnolk6p`,
prefix `cleanup/`), mounted at `/mnt/reports`:

| File | Content |
|---|---|
| `cleanup_report_YYYY-MM-DD.txt` | one line per resource: `name \| region \| service_name \| crn` |
| `cleanup_report_YYYY-MM-DD.json` | the full search result (`.items`) |
| `cleanup_report_YYYY-MM-DD.csv` | the review sheet (below) |

All three are written or none are, and an empty result still writes empty reports, so "ran and
found nothing" is distinguishable from "did not run".

CSV columns: `delete,name,service_name,type,region,resource_group_id,creation_date,tags,crn`.
`delete` is always generated as `no`.

### `deleteme-cleanup` (delete)

Triggered when a `.csv` is uploaded under `review/` in the review bucket
(`rst-cleanup-bucket-9yk456iwqnolk6p`). Files elsewhere in the bucket are ignored.

A row is deleted only when **all** of these hold:

1. its `delete` cell is `yes` (case-insensitive);
2. the **live** resource is tagged both `deleteme` and `owner:ryantiffany` (the CSV `tags`
   column is ignored);
3. it is not protected: the `rst-ce-demo` project, `rst-cos-instance`, the project the job runs
   in, and anything in `PROTECTED_CRNS` (a bucket CRN protects its COS instance);
4. the job runs with `DRY_RUN` set to exactly `false`. Anything else is a dry run that only logs
   what it would do. **The job is deployed as a dry run.**

Supported types:

- **VPC**: deleted with its subnets and public gateways (detach, subnets, gateways, then the VPC).
  Mark the VPC **and** its subnets and gateways `yes`: the report writes `no` on every row, and a
  child left at `no` blocks its VPC. So does a child missing either tag, a protected child, or
  anything attached (instances, load balancers, VPN or endpoint gateways, custom security groups,
  ACLs or routing tables). A blocked VPC is left untouched.
- **Service instances** (e.g. a Code Engine project, COS, Key Protect): deleted into IBM's 7-day
  reclamation, so they can be restored with `ibmcloud resource reclamation-restore`.
- Anything else is skipped and logged.

A CRN marked `yes` on one row and `no` on another is skipped. A failure on one row does not stop
the others; the run exits 1 if anything failed, and failed runs are not retried automatically.

Every run writes an audit log to the reports bucket, `cleanup_run_YYYY-MM-DDTHHMMSSZ.log`, with
the mode, the input file, one line per row and a summary. Outcomes: `DELETED`, `WOULD_DELETE`,
`ALREADY_GONE`, `SKIP_TAGS`, `SKIP_PROTECTED`, `SKIP_CHILD`, `SKIP_UNSUPPORTED`, `SKIP_NO_CRN`,
`SKIP_CONFLICT`, `FAILED`. The same lines appear in `ibmcloud ce jobrun logs`.

## Using it

1. Download the latest `cleanup_report_*.csv` from the reports bucket.
2. Set `delete` to `yes` on the rows to remove (for a VPC, also its subnets and gateways).
   Tag those resources `deleteme` if they are not already.
3. Upload the file to the review bucket with a key under `review/`, e.g. `review/2026-11-23.csv`.
4. Read the run's log (`ibmcloud ce jobrun list`, then `ibmcloud ce jobrun logs --name <run>`).

While the job is a dry run, a live delete of a reviewed file is a single manual run that does not
change the job:

```bash
ibmcloud ce jobrun submit --job deleteme-cleanup \
  --env DRY_RUN=false --env CSV_FILE=/mnt/review/review/<file>.csv
```

## Layout

| Path | Purpose |
|---|---|
| `weekly_cleanup_report.sh` | report job (bash + jq) |
| `entrypoint.sh` | logs in with `IBMCLOUD_API_KEY`, then runs `$CLEANUP_SCRIPT` (the report by default) |
| `deleteme_cleanup.py`, `deleteme/` | delete job (Python 3.12 stdlib, calls the `ibmcloud` CLI) |
| `Dockerfile` | one image for both jobs: Ubuntu 24.04, jq, python3, IBM Cloud CLI + VPC plugin |
| `deploy.sh` | creates/updates the report job, its secret and cron |
| `deploy_deleteme.sh` | creates/updates the delete job, its secret, the review mount and the COS trigger |
| `tests/` | shell and pytest suites; `ibmcloud` is always a stub, nothing touches real resources |
| `docs/superpowers/` | designs and implementation plans |
| `docs/test-resources.md` | the tagged test resources used for the live test, and how to recreate them |

## Build and deploy

```bash
docker build --platform linux/amd64 -t ca.icr.io/rst-icr-ca/weekly-cleanup:vN .
docker push ca.icr.io/rst-icr-ca/weekly-cleanup:vN
```

Push to `ca.icr.io`; the jobs pull from `private.ca.icr.io` using the `ca-rst-icr-key` registry
secret.

Deploy settings live in `.env.deploy` (git-ignored; copy `.env.deploy.example`). With an
`ibmcloud login` session:

```bash
set -a; . ./.env.deploy; set +a; ./deploy.sh            # report job
set -a; . ./.env.deploy; set +a; ./deploy_deleteme.sh   # delete job (dry run unless DELETEME_DRY_RUN=false)
```

The delete job needs, created by hand first: the review bucket, its HMAC credential and Code
Engine HMAC secret, a service ID and API key with delete rights (`DELETEME_API_KEY`), and an IAM
authorization for Code Engine to receive COS notifications from the bucket.

## Tests

```bash
bash tests/test_report.sh && bash tests/test_deploy.sh \
  && bash tests/test_entrypoint.sh && bash tests/test_deploy_deleteme.sh
uvx --python 3.12 pytest tests -q
ruff check deleteme deleteme_cleanup.py tests && ruff format --check deleteme deleteme_cleanup.py tests
```

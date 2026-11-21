# `deleteme` cleanup job — design

Issue: https://github.com/greyhoundforty/cleanup-ce-jobs/issues/2
Status: approved 2026-11-21 (builder-checked). Size: project.

## Intent

This is the second half of the review-then-delete flow that started with issue #1:

1. Monday 13:00 UTC: the `weekly-cleanup` job writes `cleanup_report_YYYY-MM-DD.csv` to the
   reports bucket (unchanged, read-only).
2. The user downloads the CSV, changes `delete` from `no` to `yes` on the rows to remove,
   and uploads it to a separate review bucket under `review/`.
3. That upload triggers a new `deleteme-cleanup` job, which deletes only the rows marked `yes`
   whose live resource is tagged both `deleteme` and `owner:ryantiffany`.

Why it matters: this is the user's own account. A resource that only belongs to someone else, or
one that was never meant to go, must never be deleted. The edited CSV is the user's decision;
the two tags are a second, independent check made on the live resource at delete time.

## Goals

- Delete what the user marked, safely, with a full audit log next to the reports.
- Cascade VPC deletion through subnets and public gateways that are tagged the same way.
- Ship in dry-run mode: the job only logs what it would do until the user turns that off.
- Free test resources in ca-tor that exercise every path, so the first real run is predictable.

## Non-goals

- Changes to the report job, its CSV contract or its schedule.
- Resource types beyond VPC (with subnets and public gateways) and service instances.
- A UI or JSON review file (the JSON stays for tracking only).
- Restoring anything (service instances can be restored by hand within the reclamation window).

## Anti-goals (failure even if it "works")

- Deleting anything without `delete = yes` in the uploaded CSV **and** both tags on the live
  resource at delete time. (A VPC's `yes` covers its subnets and public gateways, which must
  each carry both tags themselves; see the cascade rules.)
- Deleting a protected resource (the job's own project, the COS instances behind its mounts,
  anything in `PROTECTED_CRNS`), whatever the CSV and tags say.
- Deleting anything while `DRY_RUN` is anything other than exactly `false`.
- Deleting a VPC child (or the VPC) that is not tagged both ways. Such a child blocks the
  whole VPC.
- The report job gaining delete rights: the cleanup job uses its own API key secret.
- Tests touching real resources.

## Constraints

- Existing pattern: Code Engine jobs in project `rst-ce-demo` (ca-tor), image built from this
  repo, PDS mounts backed by COS, `entrypoint.sh` login (it already runs `$CLEANUP_SCRIPT`).
- Tests stub `ibmcloud` on PATH, like the existing shell suites.
- CSV input as produced by #1: unquoted header
  `delete,name,service_name,type,region,resource_group_id,creation_date,tags,crn`, fully quoted
  rows. It may come back from Excel or Numbers with CRLF, a UTF-8 BOM, reordered columns or
  unquoted values.

## Approaches considered

1. **Python standard library calling the `ibmcloud` CLI (picked by the user).** Stdlib `csv`
   parses Excel output correctly; `subprocess` runs `ibmcloud` with `--output json`. Same image,
   no pip dependencies, pytest with the same stub-`ibmcloud`-on-PATH approach. Costs: it depends
   on CLI JSON shapes, which can change between CLI versions.
2. Python with IBM SDKs (`ibm-vpc`, `ibm-platform-services`): typed calls, but pinned
   dependencies, SDK-mock tests, and a second auth path next to the CLI already in the image.
3. Bash, converting CSV to JSON with a Python one-liner and then jq: closest to the report
   script, but the cascade and child checks become hard to read and test in bash.

## Design

### Trigger and input

- New COS bucket for reviews in ca-tor (created by the user), mounted on the cleanup job as a second PDS at
  `/mnt/review` (read-only use). Reports PDS `ce-pds-9ef3:cleanup` is also mounted at
  `/mnt/reports` for the audit log.
- COS subscription `deleteme-cleanup-cos` → destination type `job`, `--event-type write`,
  `--prefix review/`, `--suffix .csv`.
- The job learns the object key from the event (Code Engine passes event fields to jobs as
  environment variables, e.g. `CE_SUBJECT` / `CE_DATA`; the builder confirms which with a
  probe run) and reads `/mnt/review/<key minus the review/ prefix if the mount uses it>`.
- A manual run can pass `CSV_FILE=/mnt/review/...` instead of an event.
- Rejected inputs (log + non-zero exit, nothing deleted): key not under `review/`, not `.csv`,
  file missing, header missing `delete` or `crn`.

### Per-row decision (in CSV order, services and VPCs mixed)

1. Parse with `csv.DictReader` (open with `encoding="utf-8-sig"`, `newline=""`), so BOM, CRLF,
   quoting and column order are all handled. Values are stripped.
2. Skip rows where `delete` (case-insensitive) is not `yes`. Skip rows with an empty `crn`
   (logged).
3. Look up the live resource by CRN (`ibmcloud resource search 'crn:"<crn>"'`). Not found →
   `ALREADY_GONE`. Tags are always taken from this lookup, never from the CSV `tags` column.
4. CRN on the protected list → `SKIP_PROTECTED` (checked before tags, and again for every
   VPC child).
5. Missing `deleteme` or `owner:ryantiffany` → `SKIP_TAGS`.
6. Dispatch on the live resource type:
   - **VPC**: list its subnets, public gateways, and blockers (instances, bare metal, load
     balancers, VPN gateways/servers, endpoint gateways, custom security groups, custom
     network ACLs, custom routing tables, and anything else attached). Any blocker, or any
     subnet/gateway missing either tag, or a child whose own CSV row is explicitly `no`, or a
     protected child → `SKIP_CHILD` naming the child. The floating IP that IBM auto-creates
     for a public gateway is not a blocker; it is released with the gateway. Otherwise: detach
     each gateway from its subnets, delete subnets, delete gateways, delete the VPC (default
     security group, ACL and routing table go with it). The VPC is not reclaimable.
   - **Service instance** (`resource-instance`, including a Code Engine project):
     `ibmcloud resource service-instance-delete <id> --recursive -f`. It goes into IBM's
     reclamation (7 days by default), never `reclamation-delete`.
   - **Subnet or public gateway on its own row** (marked `yes`, VPC not marked) →
     `SKIP_UNSUPPORTED`; v1 only removes them through their VPC's cascade.
   - **Anything else** → `SKIP_UNSUPPORTED`.
7. The whole CSV is read before anything is deleted, so a child row's explicit `no` is known
   whatever the row order. A CRN listed twice is acted on once; a later attempt that finds it
   gone logs `ALREADY_GONE`.

### Protected resources

- Built into the script (cannot be removed by config): the Code Engine project the job runs in
  (`rst-ce-demo`, `crn:v1:bluemix:public:codeengine:ca-tor:a/db1a8b544a184fd7ac339c243684a9b7:661a5a9d-20c7-435c-af3b-a68806e905ea::`,
  and also whatever project `CE_PROJECT_ID` names at run time) and the COS instance behind the
  reports bucket `rst-usage-bucket-9yk456iwqnolk6p`: `rst-cos-instance`,
  `crn:v1:bluemix:public:cloud-object-storage:global:a/db1a8b544a184fd7ac339c243684a9b7:4c2b8b6a-2217-422b-ad57-e48380ae1ba4::`
  (confirmed by the user).
- `PROTECTED_CRNS` env (comma-separated) adds more, e.g. the review bucket's COS instance; the
  deploy script sets it from `.env.deploy`.
- Matching is on the instance part of the CRN, so a CRN with or without trailing segments still
  matches.

### Dry run

- `DRY_RUN` defaults to true. Only the exact string `false` enables deletion; anything else
  (unset, `False`, `no`, a typo) is a dry run.
- A dry run performs every lookup and check and logs `WOULD_DELETE <crn>` (and each child, in
  order) instead of running a delete command.
- The job is deployed with `DRY_RUN=true`. The user switches it to `false` after watching a dry
  run and a live run against the test resources.

### Audit log

- `/mnt/reports/cleanup_run_YYYY-MM-DDTHHMMSSZ.log` (one per run, never overwritten).
- First lines: mode (DRY RUN / LIVE), input file, row counts. Then one line per action:
  UTC timestamp, outcome (`DELETED`, `WOULD_DELETE`, `ALREADY_GONE`, `SKIP_TAGS`,
  `SKIP_PROTECTED`, `SKIP_CHILD`, `SKIP_UNSUPPORTED`, `SKIP_NO_CRN`, `FAILED`), type, name, CRN and reason.
  Last line: summary counts.
- The same lines go to stdout so `ibmcloud ce jobrun logs` shows them.
- Failure on one row is logged as `FAILED` with the CLI's error text, and the run continues.
  Exit code 1 if any row `FAILED` or the input was rejected, else 0. Skips are not failures.

### Credentials and deployment

- New secret `deleteme-api-key` (a new service ID's API key with the access below), attached as
  `IBMCLOUD_API_KEY`. The `cleanup-api-key` secret and the report job are unchanged.
- IAM for the new key: Editor (or a custom role with delete) on VPC Infrastructure Services,
  and Editor on the resource groups that hold the target service instances, plus Viewer for
  global search/tagging. The user creates the service ID and key; Claude never sees it.
- The user creates, by hand: the review bucket, its HMAC credential, the Code Engine HMAC
  secret, the service ID + `deleteme-api-key` key, and the IAM authorization for Code Engine to
  receive COS notifications (Notifications Manager). The user records their names (and the
  API key value) in `.env.deploy`; `.env.deploy.example` gains the new variables
  (e.g. `REVIEW_BUCKET`, `REVIEW_HMAC_SECRET`, `DELETEME_API_KEY`, `PROTECTED_CRNS`).
- The deploy script creates or updates only Code Engine objects: the `deleteme-api-key` secret
  (from the env value, never printed), the review PDS, the job and the COS subscription.
- Same image (Dockerfile gains `python3`, copies `deleteme_cleanup.py`). Job `deleteme-cleanup`
  sets `CLEANUP_SCRIPT=/usr/local/bin/deleteme_cleanup.py`, so `entrypoint.sh` logs in and runs
  it. Deployed by a separate `deploy_deleteme.sh` (or a mode of `deploy.sh`, builder's call),
  idempotent like today's, using the existing `.env.deploy` flow plus the new secret's key
  supplied the same way.

### Test resources (created once the design is approved)

All in ca-tor, no VMs, no floating IPs, no data, so no running cost:

| Resource | Tags | Expected outcome |
|---|---|---|
| `ce-test-vpc-a` + subnet `ce-test-a-sn` + public gateway `ce-test-a-pgw` | `deleteme`, `owner:ryantiffany` on all | deleted in cascade order |
| `ce-test-vpc-b` | `owner:ryantiffany` | `SKIP_TAGS` |
| `ce-test-vpc-c` | `deleteme` | `SKIP_TAGS` |
| `ce-test-vpc-d` (both tags) + subnet `ce-test-d-sn` | subnet has `owner:ryantiffany` only | `SKIP_CHILD` |
| `ce-test-proj` (empty Code Engine project) | `deleteme`, `owner:ryantiffany` | deleted to reclamation |

They are created with the CLI by Claude from the user's logged-in session, recorded in
`docs/test-resources.md` with a teardown command per resource, and kept until the user removes
them. Resources that are deleted by a live test run can be recreated with the same commands.

## Testing

pytest (`tests/test_deleteme_cleanup.py`) with a stub `ibmcloud` on PATH that answers from
fixture JSON and records every call to a file; assertions are on outcomes and the recorded
calls. Cases:

- protected CRN (built-in and `PROTECTED_CRNS`) is never deleted, even with `yes` and both tags;
  a protected VPC child blocks its VPC
- child row explicitly `no` blocks its VPC even when listed after the VPC row; standalone
  subnet/gateway `yes` rows are `SKIP_UNSUPPORTED`
- dry run is the default and issues no delete commands; `DRY_RUN=False`/`no`/unset are dry
- only `yes` rows act; tags come from the live lookup (CSV says both tags, live has one → skip)
- CSV with BOM, CRLF, reordered columns, unquoted values, a name with comma/quote/newline
- empty `crn`, unknown CRN (`ALREADY_GONE`), duplicate CRN, unsupported type
- VPC cascade order: detach → subnets → gateways → VPC; any untagged child or blocker skips the
  whole VPC and issues no deletes for it
- service instance deleted with `--recursive`, never `reclamation-delete`
- one failing delete is logged, the rest continue, exit 1
- rejected inputs (wrong prefix/suffix, missing file, bad header) delete nothing, exit 1
- audit log written to the reports dir with mode, per-row lines and summary

Existing shell suites keep passing. End-to-end: dry run against the test resources, check the
log, then one live run with `DRY_RUN=false` set on a single jobrun, then back to dry-run default.

## Left to the builder

- Exact CLI commands and JSON paths for VPC child listing, detach and deletes, and how the
  target region is set per row.
- Which env var carries the COS object key (probe run), and the key-to-path mapping.
- Separate deploy script vs a mode of `deploy.sh`.
- Log line format details.

## Rollout

1. Create test resources; record them.
2. Implement + tests; image v6 (report job may move to v6 too, behavior unchanged).
3. User creates the review bucket, HMAC credential and secret, service ID/key and IAM
   authorization, and updates `.env.deploy`; Claude runs the deploy with
   `DRY_RUN=true`.
4. Upload a CSV marking the test rows `yes` → check dry-run log.
5. One live jobrun against test resources only → verify outcomes.
6. Leave the job at `DRY_RUN=true` until the user decides otherwise.

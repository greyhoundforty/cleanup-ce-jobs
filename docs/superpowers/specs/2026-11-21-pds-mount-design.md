# Code Engine persistent data store mount (approved)

## Intent
Replace the `ibmcloud cos` upload in the weekly cleanup job with a Code Engine
persistent data store mount, so the report is written as a normal file and
lands in Cloud Object Storage with no upload step.

## Facts
- PDS: `ce-pds-9ef3`; bucket `rst-usage-bucket-9yk456iwqnolk6p`; region `ca-tor`.
- Bucket and region are bound to the PDS; the script does not need them.

## Goals
- Script writes the report to `${REPORT_DIR:-/mnt/reports}`.
- Reports appear in the bucket under the `cleanup/` prefix.
- Fewer moving parts: no `cos` plugin, no `COS_BUCKET_NAME`.

## Non-goals
- No change to the resource search or report format.
- No larger rewrite of the entrypoint.

## Approaches
1. **Mount PDS, write files directly (chosen):** simplest, matches the request.
2. Keep CLI upload and add mount: redundant.
3. Rewrite in Python/boto3: unnecessary.

## Design
1. `weekly_cleanup_report.sh`: create `REPORT_DIR` if missing, fail if not
   writable, write the report there; remove the COS upload block.
2. `Dockerfile`: drop the `cos` plugin install.
3. `deploy.sh`: `ibmcloud ce job create/update` with
   `--mount-data-store /mnt/reports=ce-pds-9ef3:cleanup`; API key from a secret.

## Builder's calls
- Mount path `/mnt/reports`; overridable via `REPORT_DIR`.
- Drop the uncommitted `object-put` edit, since the mount replaces it.

# `deleteme` Cleanup Job Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `deleteme-cleanup` Code Engine job, triggered by a reviewed CSV landing in the review bucket, that deletes only `yes` rows whose live resource has both tags and is not protected, dry-run by default, with an audit log.

**Architecture:** Python stdlib package `deleteme/` (CSV reader, protected list, `ibmcloud` adapter, decision engine) plus an entry script `deleteme_cleanup.py`, run by the existing `entrypoint.sh` via `CLEANUP_SCRIPT`. Same image; a new idempotent `deploy_deleteme.sh` creates the Code Engine pieces.

**Tech Stack:** Python 3.12 stdlib (image is ubuntu:24.04), `ibmcloud` CLI via `subprocess`, pytest run with `uvx pytest` (not installed locally), bash for the deploy script and its stub test.

**Spec:** `docs/superpowers/specs/2026-11-21-deleteme-cleanup-design.md`

## Global Constraints

- Delete only when: CSV `delete` is `yes` (case-insensitive, trimmed) **and** the live resource has both `deleteme` and `owner:ryantiffany` **and** it is not protected **and** `DRY_RUN` is exactly `false`.
- `DRY_RUN`: only the exact string `false` is live; unset, `False`, `no`, anything else is a dry run.
- Tags always come from the live lookup, never from the CSV `tags` column.
- Built-in protected CRNs (in code, not removable by config):
  - `crn:v1:bluemix:public:codeengine:ca-tor:a/db1a8b544a184fd7ac339c243684a9b7:661a5a9d-20c7-435c-af3b-a68806e905ea::` (`rst-ce-demo`)
  - `crn:v1:bluemix:public:cloud-object-storage:global:a/db1a8b544a184fd7ac339c243684a9b7:4c2b8b6a-2217-422b-ad57-e48380ae1ba4::` (`rst-cos-instance`)
  - plus the project named by `CE_PROJECT_ID`, plus comma-separated `PROTECTED_CRNS`.
- Outcomes, exactly: `DELETED`, `WOULD_DELETE`, `ALREADY_GONE`, `SKIP_TAGS`, `SKIP_PROTECTED`, `SKIP_CHILD`, `SKIP_UNSUPPORTED`, `SKIP_NO_CRN`, `SKIP_CONFLICT`, `FAILED`.
- Service instances: `ibmcloud resource service-instance-delete <crn> --recursive -f`; never `reclamation-delete`.
- Audit log: `${REPORT_DIR:-/mnt/reports}/cleanup_run_YYYY-MM-DDTHHMMSSZ.log` (UTC), never overwritten; same lines to stdout.
- Input: object key must start with `review/` and end with `.csv` (case-insensitive suffix); file read from `${REVIEW_DIR:-/mnt/review}/<key>` and must resolve inside `REVIEW_DIR`.
- Exit 1 if input rejected or any `FAILED`; skips are not failures.
- Python must run on 3.12 (no newer syntax). Lint with `ruff check deleteme deleteme_cleanup.py tests` and `ruff format --check` on the same paths.
- Tests never touch real resources: `ibmcloud` is always the stub `tests/stub/ibmcloud` on PATH.
- Never read or print `.env.deploy`; API keys never on a command line.
- Do not change `weekly_cleanup_report.sh`, `entrypoint.sh` or `deploy.sh` behavior. All existing suites must pass.

## Review Focus

- A VPC child that disappears between listing and delete (already gone): treated as `ALREADY_GONE` for that child and the cascade continues to the VPC (test in Task 3).
- Region: a VPC row in a region other than the login region must target that region before any `is` command (test in Task 3).
- A CSV saved by Excel with only `\r` line endings or a trailing blank line: no crash, blank rows ignored (test in Task 1).
- `CE_DATA` with a URL-encoded key (`review/my%20file.csv`): decoded before validation (test in Task 4).
- Log directory unwritable: exit 1 before any lookup or delete (test in Task 4).

---

### Task 1: CSV reader and protected list

**Files:**
- Create: `deleteme/__init__.py` (empty), `deleteme/csvin.py`, `deleteme/protect.py`
- Test: `tests/test_csvin.py`, `tests/test_protect.py`

**Interfaces:**
- Produces:
  - `class InputError(Exception)` in `deleteme/csvin.py`
  - `@dataclass(frozen=True) class Row: line: int; delete: bool; explicit_no: bool; name: str; type: str; crn: str`
  - `read_rows(path: str | Path) -> list[Row]` — opens with `encoding="utf-8-sig", newline=""`, `csv.DictReader`, header names stripped and lowercased, values stripped; rows where every value is empty are dropped; `line` is the 1-based data-row number. Raises `InputError` if the header lacks `delete` or `crn`, or the file is not valid UTF-8 / unreadable.
  - `crn_key(crn: str) -> tuple[str, str, str, str]` in `deleteme/protect.py` — `(service_name, service_instance, resource_type, resource)` from CRN segments 4, 7, 8, 9, lowercased, missing segments `""`.
  - `BUILTIN_PROTECTED: tuple[str, ...]` (the two CRNs above)
  - `build_protected(env: Mapping[str, str]) -> frozenset[tuple[str, str, str, str]]`
  - `is_protected(crn: str, protected: frozenset) -> bool`

- [ ] **Step 1: Write failing tests**

`tests/test_csvin.py` (write CSV fixtures with `tmp_path`, raw bytes where it matters):
- `test_reads_report_csv`: the #1 format (unquoted header, quoted rows) → rows with `delete` False/True from `"no"`/`"yes"`, `explicit_no` True for `"no"`.
- `test_bom_and_crlf`: `b"\xef\xbb\xbfdelete,name,crn\r\n\"Yes\",\"a\",\"crn:1\"\r\n"` → one row, `delete is True`, `crn == "crn:1"`.
- `test_cr_only_and_trailing_blank`: `b"delete,crn\r\"yes\",\"crn:1\"\r\r"` → one row.
- `test_reordered_and_unquoted`: `crn,name,delete\ncrn:1,a,YES\n` → `delete is True`.
- `test_name_with_comma_quote_newline`: name `"a, ""b""\nc"` → `name == 'a, "b"\nc'`, row count 1.
- `test_other_values_not_yes`: `delete` of `y`, `true`, `""` → `delete is False`, `explicit_no is False`.
- `test_missing_crn_header_raises` and `test_missing_delete_header_raises` → `InputError`.
- `test_not_utf8_raises`: bytes `b"delete,crn\n\xff\xfe\n"` → `InputError`.

`tests/test_protect.py`:
- `test_builtin_project_and_cos_protected`: both CRNs in Global Constraints → `is_protected(...)` True with `build_protected({})`.
- `test_trailing_segments_match`: `"crn:v1:bluemix:public:cloud-object-storage:global:a/db1a8b544a184fd7ac339c243684a9b7:4c2b8b6a-2217-422b-ad57-e48380ae1ba4"` (no `::`) → True.
- `test_env_extra_crns`: `PROTECTED_CRNS=" crn:v1:bluemix:public:is:ca-tor:a/x::vpc:r038-1 , "` → that VPC CRN protected; empty items ignored.
- `test_ce_project_id_protected`: `CE_PROJECT_ID="ABC-123"` → `crn:v1:bluemix:public:codeengine:ca-tor:a/x:abc-123::` protected.
- `test_unrelated_not_protected`: `ce-test-proj` CRN `crn:v1:bluemix:public:codeengine:ca-tor:a/db1a8b544a184fd7ac339c243684a9b7:d6095178-b1de-4861-898a-cd0035a2b236::` → False.

- [ ] **Step 2: Run to verify they fail**

Run: `uvx pytest tests/test_csvin.py tests/test_protect.py -q`
Expected: collection errors / FAIL (module `deleteme` missing).

- [ ] **Step 3: Implement** `deleteme/csvin.py` and `deleteme/protect.py` per the Interfaces block. Add `tests/conftest.py` that puts the repo root on `sys.path`.

- [ ] **Step 4: Run tests and lint**

Run: `uvx pytest tests/test_csvin.py tests/test_protect.py -q && ruff check deleteme tests && ruff format --check deleteme tests`
Expected: all PASS, no lint findings.

- [ ] **Step 5: Commit**

```bash
git add deleteme tests/conftest.py tests/test_csvin.py tests/test_protect.py
git commit -m "feat: CSV reader and protected list for deleteme cleanup (#2)"
```

### Task 2: `ibmcloud` adapter and stub

**Files:**
- Create: `deleteme/cloud.py`, `tests/stub/ibmcloud` (executable Python), `tests/test_cloud.py`
- Modify: `tests/conftest.py` (add the `stub` fixture)

**Interfaces:**
- Produces, in `deleteme/cloud.py`:
  - `class CloudError(Exception)` (message = CLI stderr/stdout, trimmed)
  - `@dataclass(frozen=True) class Resource: crn: str; name: str; type: str; region: str; resource_id: str; tags: frozenset[str]`
  - `@dataclass(frozen=True) class Child: id: str; crn: str; name: str; kind: str; gateway_id: str = ""` (`kind` is `"subnet"` or `"public-gateway"`)
  - `@dataclass(frozen=True) class VpcChildren: subnets: list[Child]; gateways: list[Child]; blockers: list[str]`
  - `class Cloud:` `__init__(self, binary: str = "ibmcloud")`, and methods:
    - `lookup(crn: str) -> Resource | None` — `resource search crn:"<crn>" --output json`; first item or `None`; when `resource_id` is empty it falls back to the CRN's resource segment (9), else its service-instance segment (7).
    - `target_region(region: str) -> None` — `target -r <region> -q`; no call if already targeted by this object.
    - `vpc_children(vpc_id: str) -> VpcChildren`
    - `detach_gateway(subnet_id: str)`, `delete_subnet(subnet_id: str)`, `delete_gateway(gateway_id: str)`, `delete_vpc(vpc_id: str)`, `delete_service_instance(crn: str)` — all `-> None`
    - `remaining(vpc_id: str, subnet_ids: set[str], gateway_ids: set[str]) -> set[str]` — ids from the two sets still listed.
  - Every call raises `CloudError` on non-zero exit or non-JSON where JSON is expected.
- Exact commands (`--output JSON` for `is`, `--output json` for `resource search`):
  - subnets: `is subnets --vpc <vpc_id> --output JSON` (`.id .crn .name .public_gateway.id`)
  - gateways: `is public-gateways --all-resource-groups --output JSON`, keep `.vpc.id == vpc_id`
  - defaults: `is vpc <vpc_id> --output JSON` → `.default_security_group.id`, `.default_network_acl.id`
  - blockers, each a human-readable string:
    - per subnet `is subnet-reserved-ips <subnet_id> --output JSON`, any entry with `owner == "user"` → `"subnet <name>: attached <target.resource_type or name>"`
    - `is security-groups --vpc <vpc_id> --output JSON` minus the default → `"security group <name>"`
    - `is network-acls --all-resource-groups --output JSON`, `.vpc.id == vpc_id`, minus the default → `"network ACL <name>"`
    - `is vpc-routing-tables <vpc_id> --output JSON` with `is_default` false → `"routing table <name>"`
  - detach `is subnet-public-gateway-detach <id> -f`; deletes `is subnet-delete <id> -f`, `is public-gateway-delete <id> -f`, `is vpc-delete <id> -f`, `resource service-instance-delete <crn> --recursive -f`
- Stub contract (`tests/stub/ibmcloud`): reads JSON from `$STUB_FIXTURE`: a list of `{"match": "<argv prefix joined by spaces>", "responses": [{"stdout": <str or JSON value>, "rc": 0, "stderr": ""}]}`; first entry whose `match` is a prefix of the joined argv wins; responses are consumed in order and the last repeats; no match → rc 0, empty stdout. Appends each argv as a JSON array line to `$STUB_CALLS`. Fixture `stub(tmp_path, monkeypatch)` in conftest returns an object with `.set(entries)` and `.calls() -> list[list[str]]`, and puts `tests/stub` first on `PATH`.

- [ ] **Step 1: Write failing tests** in `tests/test_cloud.py` (fixture JSON shaped like the real output probed from `ce-test-vpc-a`):
  - `test_lookup_returns_tags_and_type`: search item for `ce-test-vpc-a` with tags `["deleteme","owner:ryantiffany"]` → `Resource.type == "vpc"`, `tags == frozenset({...})`, `resource_id == "r038-3e07..."`.
  - `test_lookup_missing_returns_none`: `{"items": []}` → `None`.
  - `test_lookup_resource_id_fallback`: CE project item with `"resource_id": ""` and CRN `...:d6095178-b1de-4861-898a-cd0035a2b236::` → `resource_id == "d6095178-b1de-4861-898a-cd0035a2b236"`.
  - `test_vpc_children_lists_subnets_and_gateways`: subnet with `public_gateway.id` → `Child.gateway_id` set; gateways from another VPC are excluded.
  - `test_default_sg_acl_rt_and_provider_ips_are_not_blockers`: only provider reserved IPs, default SG/ACL, `is_default` routing table → `blockers == []`.
  - `test_attached_and_custom_items_are_blockers`: one `owner:"user"` reserved IP with `target.resource_type:"network_interface"`, one extra SG, ACL and routing table → four blocker strings naming each.
  - `test_cli_failure_raises`: delete returns rc 1 stderr `"Error: not authorized"` → `CloudError` containing `not authorized`.
  - `test_service_delete_command`: recorded call == `["resource","service-instance-delete","<crn>","--recursive","-f"]`.
  - `test_target_region_once`: two `target_region("us-south")` calls → one recorded `target` call.

- [ ] **Step 2: Run to verify they fail**

Run: `uvx pytest tests/test_cloud.py -q`
Expected: FAIL (`deleteme.cloud` missing).

- [ ] **Step 3: Implement** the stub, the conftest fixture, and `deleteme/cloud.py` (`subprocess.run([...], capture_output=True, text=True)`; never `shell=True`).

- [ ] **Step 4: Run tests and lint**

Run: `uvx pytest tests -q && ruff check deleteme tests && ruff format --check deleteme tests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add deleteme/cloud.py tests/stub/ibmcloud tests/conftest.py tests/test_cloud.py
git commit -m "feat: ibmcloud adapter and stub for deleteme cleanup (#2)"
```

### Task 3: Decision engine

**Files:**
- Create: `deleteme/engine.py`, `tests/test_engine.py`

**Interfaces:**
- Consumes: `Row`, `read_rows` (Task 1); `build_protected`, `is_protected`, `crn_key` (Task 1); `Cloud`, `CloudError`, `Resource`, `VpcChildren` (Task 2).
- Produces:
  - Outcome string constants (Global Constraints names) in `deleteme/engine.py`.
  - `@dataclass(frozen=True) class Event: outcome: str; type: str; name: str; crn: str; reason: str = ""`
  - `run(rows: list[Row], cloud: Cloud, *, dry_run: bool, protected: frozenset, emit: Callable[[Event], None], sleep: Callable[[float], None] = time.sleep, wait_timeout: float = 600, poll: float = 10) -> list[Event]`
- Rules (spec "Per-row decision"), in CSV order after reading every row:
  1. `explicit_no` = `crn_key` of every row whose `explicit_no` is True.
  2. Rows not `delete` → no event. `delete` with empty `crn` → `SKIP_NO_CRN` (name from the CSV).
  3. A key already acted on in this run → skipped silently; a later lookup that finds nothing → `ALREADY_GONE`.
  4. `is_protected` → `SKIP_PROTECTED` (before lookup and tags).
  5. `cloud.lookup`; `None` → `ALREADY_GONE`; `CloudError` → `FAILED` with the message.
  6. Missing either tag → `SKIP_TAGS` with the missing tag names in `reason`.
  7. `type == "vpc"`: `cloud.target_region(resource.region)`, then `vpc_children`. Collect reasons: each blocker; each subnet/gateway that is protected, has its key in `explicit_no`, or whose live lookup lacks a tag (a child lookup returning `None` is ignored as gone). Any reason → one `SKIP_CHILD` for the VPC, `reason` = reasons joined by `"; "`, no delete calls.
     Otherwise dry run → `WOULD_DELETE` for each subnet, each gateway, then the VPC (gateway reason `"detach from <subnet names>, then delete"`). Live → detach every subnet that has a gateway, delete subnets, delete gateways (one `DELETED` each), poll `cloud.remaining` with `sleep(poll)` until empty or `wait_timeout`, then delete the VPC → `DELETED`. A `CloudError` on a child step → re-run `cloud.lookup(child.crn)`: `None` → `ALREADY_GONE` for that child and continue; otherwise `FAILED` for that item and stop this VPC (no VPC delete). A `CloudError` on the VPC delete → `FAILED`. A timeout → `FAILED` on the VPC with reason `"children still deleting after <n>s"`.
  8. `type == "resource-instance"`: dry run → `WOULD_DELETE`; live → `delete_service_instance(crn)` → `DELETED` (reason `"to reclamation"`) or `FAILED`.
  9. `type` `subnet` / `public-gateway` / anything else → `SKIP_UNSUPPORTED` with the type in `reason`.
  Every event is passed to `emit` as it happens and returned in order.

- [ ] **Step 1: Write failing tests** in `tests/test_engine.py`, using the `stub` fixture and a real `Cloud`; helper `rows(*tuples)` builds `Row`s; `sleep` is a no-op lambda; assert on events and on `stub.calls()`; "delete calls" means any call containing `-delete` or `-detach`.
  - `test_dry_run_issues_no_deletes`: vpc-a cascade + CE project, `dry_run=True` → `WOULD_DELETE` for subnet, gateway, VPC, project; zero delete calls.
  - `test_live_vpc_cascade_order`: `dry_run=False` → delete calls in this order: detach subnet, delete subnet, delete gateway, delete vpc; `remaining` answered `[]`; events `DELETED` ×3.
  - `test_waits_for_children_before_vpc`: subnets list responses: first `[subnet]`, then `[]` → VPC delete happens after the second poll; `sleep` called once.
  - `test_wait_timeout_fails_vpc`: children never go, `wait_timeout=20, poll=10` → `FAILED` VPC with `"still deleting"`, no `vpc-delete` call.
  - `test_child_gone_before_delete`: `subnet-delete` rc 1, and the follow-up search for the subnet CRN returns `{"items": []}` → `ALREADY_GONE` for the subnet, and the `vpc-delete` call still happens.
  - `test_child_delete_failure_stops_vpc`: `subnet-delete` rc 1 and the subnet still found → `FAILED` for the subnet, no `vpc-delete` call.
  - `test_tags_from_live_lookup_not_csv`: CSV tags column says both; live has only `owner:ryantiffany` → `SKIP_TAGS` with `deleteme` in reason; no delete calls.
  - `test_protected_never_deleted`: `rst-cos-instance` CRN marked yes with both tags, `dry_run=False` → `SKIP_PROTECTED`, no `resource search` call for it.
  - `test_protected_child_blocks_vpc`: subnet CRN in `PROTECTED_CRNS` → `SKIP_CHILD` naming it.
  - `test_untagged_child_blocks_vpc`: vpc-d fixture (subnet only `owner:ryantiffany`) → `SKIP_CHILD` with `ce-test-d-sn` in reason; no delete calls.
  - `test_child_explicit_no_after_vpc_row`: subnet row with `no` listed after the VPC row → `SKIP_CHILD`.
  - `test_blocker_blocks_vpc`: a `user`-owned reserved IP → `SKIP_CHILD` with `attached` in reason.
  - `test_standalone_subnet_unsupported`: subnet row `yes`, its VPC row absent → `SKIP_UNSUPPORTED`.
  - `test_unknown_type_unsupported`: type `key` → `SKIP_UNSUPPORTED`.
  - `test_missing_crn_logged`: `yes` with empty crn → `SKIP_NO_CRN`.
  - `test_already_gone`: search `{"items": []}` → `ALREADY_GONE`.
  - `test_duplicate_crn_acted_once`: same project CRN twice, live → one `service-instance-delete` call.
  - `test_failure_continues`: project delete rc 1, second project OK → `FAILED` then `DELETED`.
  - `test_targets_vpc_region`: VPC with `region: "us-south"` → a `target -r us-south -q` call recorded before the first `is` call.

- [ ] **Step 2: Run to verify they fail**

Run: `uvx pytest tests/test_engine.py -q`
Expected: FAIL (`deleteme.engine` missing).

- [ ] **Step 3: Implement `run` in `deleteme/engine.py`** per the rules.

- [ ] **Step 4: Run tests and lint**

Run: `uvx pytest tests -q && ruff check deleteme tests && ruff format --check deleteme tests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add deleteme/engine.py tests/test_engine.py
git commit -m "feat: deleteme decision engine with VPC cascade and dry run (#2)"
```

### Task 4: Entry script, input resolution and audit log

**Files:**
- Create: `deleteme_cleanup.py` (executable, `#!/usr/bin/env python3`), `tests/test_main.py`

**Interfaces:**
- Consumes: `read_rows`, `InputError`, `build_protected` (Task 1); `Cloud` (Task 2); `run`, `Event`, outcome constants (Task 3).
- Produces:
  - `resolve_input(env: Mapping[str, str]) -> Path` — `CSV_FILE` if set (must exist and end `.csv`); else the key from `CE_SUBJECT`, else `json.loads(CE_DATA)["key"]`; `urllib.parse.unquote` it; enforce the `review/` prefix, `.csv` suffix, and that `(REVIEW_DIR / key).resolve()` is inside `REVIEW_DIR.resolve()`; missing file → `InputError`.
  - `main(env: Mapping[str, str] = os.environ, now: datetime | None = None) -> int`
- Behavior of `main`:
  1. Open the log `REPORT_DIR/cleanup_run_<now:%Y-%m-%dT%H%M%SZ>.log` with mode `"x"` first; on `OSError` print `ERROR: cannot write audit log: <path>` to stderr and return 1 (no other `ibmcloud` call made).
  2. Write and print header lines `mode: DRY RUN` or `mode: LIVE`, then `input: <path or key>`.
  3. `resolve_input` + `read_rows`; on `InputError` write `REJECTED: <message>` and return 1.
  4. Write `rows: <n>, marked yes: <m>`, then `run(...)` with `emit` writing each event as tab-separated `<UTC ISO time>\t<outcome>\t<type>\t<name>\t<crn>\t<reason>` (newlines in values replaced by spaces).
  5. Write `summary: ` + `OUTCOME=count` pairs (only non-zero, in Global Constraints order). Return 1 if any `FAILED`, else 0.
  - `if __name__ == "__main__": sys.exit(main())`; the script adds its own directory to `sys.path` so `deleteme/` imports from `/opt/cleanup`.

- [ ] **Step 1: Write failing tests** in `tests/test_main.py` (in-process `main(env, now=fixed)` with `REPORT_DIR`, `REVIEW_DIR` under `tmp_path` and the stub on PATH; one subprocess test runs `python3 deleteme_cleanup.py`):
  - `test_default_is_dry_run`: no `DRY_RUN` → log line `mode: DRY RUN`, no delete calls; also for `DRY_RUN` of `False`, `no`, `true`.
  - `test_live_only_with_exact_false`: `DRY_RUN=false` → `mode: LIVE` and the project delete call.
  - `test_ce_subject_key`: `CE_SUBJECT=review/r.csv` → reads `REVIEW_DIR/review/r.csv`.
  - `test_ce_data_urlencoded_key`: `CE_DATA='{"key":"review/my%20file.csv"}'` → reads `review/my file.csv`.
  - `test_rejects_wrong_prefix_suffix_and_traversal`: `other/r.csv`, `review/r.txt`, `review/../x.csv` → return 1, log contains `REJECTED`, zero `ibmcloud` calls.
  - `test_missing_file_and_bad_header_rejected` → return 1, `REJECTED`.
  - `test_unwritable_log_dir_exits_before_cloud`: `REPORT_DIR` chmod 555 → return 1, zero `ibmcloud` calls.
  - `test_log_name_and_summary`: fixed `now=2026-11-23T14:05:09Z` → file `cleanup_run_2026-11-23T140509Z.log`; last line starts `summary: `; a second run with the same `now` returns 1 rather than overwriting.
  - `test_failed_row_exits_1`: delete rc 1 → return 1, `FAILED` line.
  - `test_script_runs_as_program`: subprocess with `CSV_FILE` → exit 0 and a log file exists.

- [ ] **Step 2: Run to verify they fail**

Run: `uvx pytest tests/test_main.py -q`
Expected: FAIL (`deleteme_cleanup` missing).

- [ ] **Step 3: Implement `deleteme_cleanup.py`**; `chmod +x`.

- [ ] **Step 4: Run tests and lint**

Run: `uvx pytest tests -q && ruff check deleteme deleteme_cleanup.py tests && ruff format --check deleteme deleteme_cleanup.py tests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add deleteme_cleanup.py tests/test_main.py
git commit -m "feat: deleteme cleanup entry script with audit log (#2)"
```

### Task 5: Image, deploy script and docs

**Files:**
- Modify: `Dockerfile` (add `python3` to apt; `COPY deleteme /opt/cleanup/deleteme` and `COPY deleteme_cleanup.py /opt/cleanup/deleteme_cleanup.py`, `chmod +x`)
- Create: `deploy_deleteme.sh`, `tests/test_deploy_deleteme.sh`
- Modify: `.env.deploy.example`, `CLAUDE.md`

**Interfaces:**
- `deploy_deleteme.sh` required env: `CE_PROJECT`, `IMAGE`, `REGISTRY_SECRET`, `DELETEME_API_KEY`, `REVIEW_BUCKET`, `REVIEW_HMAC_SECRET`; optional `PROTECTED_CRNS`, `DELETEME_DRY_RUN` (default `true`; the job gets `DRY_RUN=${DELETEME_DRY_RUN:-true}`, so a re-deploy returns to dry run unless the env file says otherwise).
- Names: job `deleteme-cleanup`, secret `deleteme-api-key` (key `IBMCLOUD_API_KEY`, created from a mode-600 temp env file like `deploy.sh`), PDS `deleteme-review-pds` (`--cos-bucket-name "$REVIEW_BUCKET" --cos-bucket-location ca-tor --cos-access-secret "$REVIEW_HMAC_SECRET"`, created only if `ce pds get` fails), mounts `/mnt/reports=ce-pds-9ef3:cleanup` and `/mnt/review=deleteme-review-pds`, env `CLEANUP_SCRIPT=/opt/cleanup/deleteme_cleanup.py`, `DRY_RUN`, `PROTECTED_CRNS`; COS subscription `deleteme-cleanup-cos` (`--destination-type job --destination deleteme-cleanup --bucket "$REVIEW_BUCKET" --event-type write --prefix review/ --suffix .csv`, created only if `ce sub cos get` fails).
- Job update follows `deploy.sh`: inspect `ce job get --output json` and pass `--mount-data-store` / `--env-from-secret` only for what is missing; `--env` always (overwrites).

- [ ] **Step 1: Write failing tests** in `tests/test_deploy_deleteme.sh` (copy the stub/`check` harness from `tests/test_deploy.sh`):
  - `test_requires_env`: missing `REVIEW_BUCKET` → non-zero.
  - `test_create_sets_mounts_secret_env`: job absent → `ce job create` has both mounts, `--env-from-secret deleteme-api-key`, `--env DRY_RUN=true`, `--env CLEANUP_SCRIPT=/opt/cleanup/deleteme_cleanup.py`.
  - `test_api_key_not_on_command_line`: the key value appears in no logged call.
  - `test_dry_run_override`: `DELETEME_DRY_RUN=false` → `--env DRY_RUN=false`.
  - `test_update_skips_existing_mounts`: job JSON with both mounts and secret → `ce job update` without `--mount-data-store`/`--env-from-secret`.
  - `test_creates_pds_and_cos_sub_when_missing` / `test_skips_pds_and_cos_sub_when_present`.
  - `test_never_touches_weekly_job`: no logged call names `weekly-cleanup`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test_deploy_deleteme.sh`
Expected: FAIL (script missing).

- [ ] **Step 3: Implement** `deploy_deleteme.sh`; update the Dockerfile; add to `.env.deploy.example` (empty values): `DELETEME_API_KEY=`, `REVIEW_BUCKET=`, `REVIEW_HMAC_SECRET=`, `PROTECTED_CRNS=`, `DELETEME_DRY_RUN=true`, and bump `IMAGE` to `v6`. Update `CLAUDE.md`: Layout (new files), test command (`uvx pytest tests -q` added), issue #2 status "implemented on branch", deploy line for `deploy_deleteme.sh`.

- [ ] **Step 4: Run everything, build the image**

Run: `bash -n deploy_deleteme.sh && bash tests/test_deploy_deleteme.sh && bash tests/test_report.sh && bash tests/test_deploy.sh && bash tests/test_entrypoint.sh && uvx pytest tests -q && ruff check deleteme deleteme_cleanup.py tests && docker build --platform linux/amd64 -t ca.icr.io/rst-icr-ca/weekly-cleanup:v6 . && docker run --rm --entrypoint python3 ca.icr.io/rst-icr-ca/weekly-cleanup:v6 -c "import sys; sys.path.insert(0,'/opt/cleanup'); import deleteme.engine; print('ok')"`
Expected: all PASS, image builds, prints `ok`.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile deploy_deleteme.sh tests/test_deploy_deleteme.sh .env.deploy.example CLAUDE.md
git commit -m "feat: image and deploy script for deleteme cleanup job (#2)"
```

### Task 6: Rollout against the test resources (needs the user)

Not code; each step is outward-facing, so the executor stops and asks before each starred step.

- [ ] **Step 1:** User confirms they created the review bucket, HMAC credential and Code Engine secret, the service ID + key, the Notifications Manager authorization, and updated `.env.deploy` (incl. `PROTECTED_CRNS` with the review bucket's COS instance CRN if different from `rst-cos-instance`).
- [ ] **Step 2 (★ push + deploy):** `docker push ca.icr.io/rst-icr-ca/weekly-cleanup:v6`; `(set -a; . ./.env.deploy; set +a; IMAGE=private.ca.icr.io/rst-icr-ca/weekly-cleanup:v6 ./deploy_deleteme.sh)` with output to a scratchpad log. Expected: job, PDS and subscription exist; `ibmcloud ce job get --name deleteme-cleanup` shows `DRY_RUN=true`.
- [ ] **Step 3 (★ probe event env):** upload a CSV containing only the header to `review/probe.csv`. Expected: a jobrun starts; its log shows `mode: DRY RUN`, `rows: 0`. If it shows `REJECTED` because the key was not found, read the jobrun's environment (`ibmcloud ce jobrun get --name <run> --output json`), fix `resolve_input` with a test first, rebuild, redeploy.
- [ ] **Step 4 (★ dry run):** upload a CSV built from today's report plus rows for all `ce-test-*` resources marked `yes`. Expected per `docs/test-resources.md`: `WOULD_DELETE` vpc-a (subnet, gateway, VPC) and the project; `SKIP_TAGS` b and c; `SKIP_CHILD` d; nothing deleted (check `ibmcloud resource search 'name:ce-test*'`).
- [ ] **Step 5 (★ one live run):** `ibmcloud ce jobrun submit --job deleteme-cleanup --env DRY_RUN=false --env CSV_FILE=/mnt/review/review/<file>.csv`. Expected: vpc-a, its subnet and gateway gone; `ce-test-proj` in reclamation; b, c, d untouched; log `DELETED` ×4, exit 0. The job's own `DRY_RUN` stays `true`.
- [ ] **Step 6:** Update `docs/test-resources.md` with what was deleted and how to recreate it; commit.

#!/usr/bin/env python3
"""deleteme cleanup job: delete what a reviewed CSV marks `yes`, if the live resource
is tagged both `deleteme` and `owner:ryantiffany` and is not protected.

Dry run unless DRY_RUN is exactly `false`. Writes an audit log next to the reports.
"""

import json
import os
import sys
from collections import Counter
from collections.abc import Mapping
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parent))

from deleteme.cloud import Cloud  # noqa: E402
from deleteme.csvin import InputError, read_rows  # noqa: E402
from deleteme.engine import FAILED, OUTCOMES, Event, run  # noqa: E402
from deleteme.protect import build_protected  # noqa: E402

KEY_PREFIX = "review/"


def _event_key(env: Mapping[str, str]) -> str:
    key = env.get("CE_SUBJECT", "").strip()
    if not key and env.get("CE_DATA"):
        try:
            data = json.loads(env["CE_DATA"])
        except json.JSONDecodeError as e:
            raise InputError(f"CE_DATA is not JSON: {e}") from e
        key = str(data.get("key", "")) if isinstance(data, dict) else ""
    return unquote(key)


def describe_input(env: Mapping[str, str]) -> str:
    if env.get("CSV_FILE"):
        return env["CSV_FILE"]
    try:
        return _event_key(env) or "(none)"
    except InputError:
        return "(unreadable event)"


def resolve_input(env: Mapping[str, str]) -> Path:
    if env.get("CSV_FILE"):
        path = Path(env["CSV_FILE"])
        if path.suffix.lower() != ".csv":
            raise InputError(f"CSV_FILE does not end in .csv: {path}")
        if not path.is_file():
            raise InputError(f"CSV_FILE not found: {path}")
        return path
    key = _event_key(env)
    if not key:
        raise InputError("no input: set CSV_FILE or trigger from a COS upload")
    if not key.startswith(KEY_PREFIX):
        raise InputError(f"object key is not under {KEY_PREFIX}: {key}")
    if not key.lower().endswith(".csv"):
        raise InputError(f"object key does not end in .csv: {key}")
    review_dir = Path(env.get("REVIEW_DIR", "/mnt/review")).resolve()
    path = (review_dir / key).resolve()
    if not path.is_relative_to(review_dir / KEY_PREFIX):
        raise InputError(f"object key escapes {KEY_PREFIX} on the review mount: {key}")
    if not path.is_file():
        raise InputError(f"file not found on the review mount: {path}")
    return path


def _clean(value: str) -> str:
    return " ".join(str(value).split("\n")).replace("\r", " ").replace("\t", " ")


def main(env: Mapping[str, str] = os.environ, now: datetime | None = None) -> int:
    now = now or datetime.now(timezone.utc)
    report_dir = Path(env.get("REPORT_DIR", "/mnt/reports"))
    log_path = report_dir / f"cleanup_run_{now:%Y-%m-%dT%H%M%SZ}.log"
    try:
        log = open(log_path, "x", encoding="utf-8")
    except OSError as e:
        print(f"ERROR: cannot write audit log: {log_path} ({e})", file=sys.stderr)
        return 1

    with log:

        def write(line: str) -> None:
            log.write(line + "\n")
            log.flush()
            print(line, flush=True)

        dry_run = env.get("DRY_RUN") != "false"
        write(f"mode: {'DRY RUN' if dry_run else 'LIVE'}")
        write(f"input: {describe_input(env)}")
        try:
            rows = read_rows(resolve_input(env))
        except InputError as e:
            write(f"REJECTED: {e}")
            return 1
        write(f"rows: {len(rows)}, marked yes: {sum(r.delete for r in rows)}")

        def emit(ev: Event) -> None:
            ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            fields = [ts, ev.outcome, ev.type, ev.name, ev.crn, ev.reason]
            write("\t".join(_clean(f) for f in fields))

        events = run(
            rows,
            Cloud(),
            dry_run=dry_run,
            protected=build_protected(env),
            emit=emit,
        )
        counts = Counter(e.outcome for e in events)
        write("summary: " + " ".join(f"{o}={counts[o]}" for o in OUTCOMES if counts[o]))
        return 1 if counts[FAILED] else 0


if __name__ == "__main__":
    sys.exit(main())

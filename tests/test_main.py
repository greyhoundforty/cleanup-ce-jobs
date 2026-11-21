import os
import subprocess
import sys
from datetime import datetime, timezone

import pytest

from cloudfix import BOTH, item, project_crn, search
from conftest import ROOT
from deleteme_cleanup import main

PROJ = "d6095178-b1de-4861-898a-cd0035a2b236"
NOW = datetime(2026, 11, 23, 14, 5, 9, tzinfo=timezone.utc)
CSV = (
    "delete,name,service_name,type,region,resource_group_id,creation_date,tags,crn\n"
    f'"yes","proj","codeengine","resource-instance","ca-tor","rg","2026","x","{project_crn(PROJ)}"\n'
)


@pytest.fixture
def dirs(tmp_path, stub):
    reports = tmp_path / "reports"
    review = tmp_path / "review"
    (review / "review").mkdir(parents=True)
    reports.mkdir()
    stub.set(
        [
            search(
                project_crn(PROJ),
                item(
                    "proj", "resource-instance", project_crn(PROJ), BOTH, resource_id=""
                ),
            )
        ]
    )
    return reports, review


def env_for(dirs, **extra):
    reports, review = dirs
    return {"REPORT_DIR": str(reports), "REVIEW_DIR": str(review), **extra}


def put(dirs, key, text=CSV):
    p = dirs[1] / key
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    return p


def log_text(dirs):
    logs = list(dirs[0].glob("cleanup_run_*.log"))
    assert len(logs) == 1
    return logs[0].read_text()


def deletes(stub):
    return [c for c in stub.calls() if "service-instance-delete" in c]


@pytest.mark.parametrize("value", [None, "False", "no", "true"])
def test_default_is_dry_run(dirs, stub, value):
    put(dirs, "review/r.csv")
    extra = {"CE_SUBJECT": "review/r.csv"}
    if value is not None:
        extra["DRY_RUN"] = value
    assert main(env_for(dirs, **extra), now=NOW) == 0
    text = log_text(dirs)
    assert "mode: DRY RUN" in text and "WOULD_DELETE" in text
    assert deletes(stub) == []


def test_live_only_with_exact_false(dirs, stub):
    put(dirs, "review/r.csv")
    assert main(env_for(dirs, CE_SUBJECT="review/r.csv", DRY_RUN="false"), now=NOW) == 0
    assert "mode: LIVE" in log_text(dirs)
    assert len(deletes(stub)) == 1


def test_ce_subject_key(dirs, stub):
    put(dirs, "review/r.csv")
    main(env_for(dirs, CE_SUBJECT="review/r.csv"), now=NOW)
    assert "rows: 1, marked yes: 1" in log_text(dirs)


def test_ce_data_urlencoded_key(dirs, stub):
    put(dirs, "review/my file.csv")
    rc = main(env_for(dirs, CE_DATA='{"key":"review/my%20file.csv"}'), now=NOW)
    assert rc == 0 and "rows: 1" in log_text(dirs)


@pytest.mark.parametrize(
    "key", ["other/r.csv", "review/r.txt", "review/../x.csv", "review/../../x.csv"]
)
def test_rejects_wrong_prefix_suffix_and_traversal(dirs, stub, key):
    put(dirs, "other/r.csv")
    put(dirs, "review/r.txt")
    put(dirs, "x.csv")
    assert main(env_for(dirs, CE_SUBJECT=key), now=NOW) == 1
    assert "REJECTED" in log_text(dirs)
    assert stub.calls() == []


def test_no_input_rejected(dirs, stub):
    assert main(env_for(dirs), now=NOW) == 1
    assert "REJECTED" in log_text(dirs) and stub.calls() == []


def test_missing_file_and_bad_header_rejected(dirs, stub):
    assert main(env_for(dirs, CE_SUBJECT="review/nope.csv"), now=NOW) == 1
    put(dirs, "review/bad.csv", "name,crn\na,b\n")
    later = NOW.replace(second=10)
    assert main(env_for(dirs, CE_SUBJECT="review/bad.csv"), now=later) == 1
    logs = sorted(p.read_text() for p in dirs[0].glob("cleanup_run_*.log"))
    assert len(logs) == 2 and all("REJECTED" in t for t in logs)
    assert stub.calls() == []


def test_unwritable_log_dir_exits_before_cloud(dirs, stub, capsys):
    put(dirs, "review/r.csv")
    os.chmod(dirs[0], 0o555)
    try:
        assert main(env_for(dirs, CE_SUBJECT="review/r.csv"), now=NOW) == 1
    finally:
        os.chmod(dirs[0], 0o755)
    assert stub.calls() == []
    assert "cannot write audit log" in capsys.readouterr().err


def test_log_name_and_summary(dirs, stub):
    put(dirs, "review/r.csv")
    e = env_for(dirs, CE_SUBJECT="review/r.csv")
    assert main(e, now=NOW) == 0
    log = dirs[0] / "cleanup_run_2026-11-23T140509Z.log"
    lines = log.read_text().splitlines()
    assert lines[-1].startswith("summary: ") and "WOULD_DELETE=1" in lines[-1]
    event = next(line for line in lines if "\tWOULD_DELETE\t" in line)
    assert event.split("\t")[1:5] == [
        "WOULD_DELETE",
        "resource-instance",
        "proj",
        project_crn(PROJ),
    ]
    before = log.read_text()
    assert main(e, now=NOW) == 1  # same timestamp: never overwrite
    assert log.read_text() == before


def test_failed_row_exits_1(dirs, stub):
    put(dirs, "review/r.csv")
    stub.add("resource service-instance-delete", {"rc": 1, "stderr": "boom"})
    assert main(env_for(dirs, CE_SUBJECT="review/r.csv", DRY_RUN="false"), now=NOW) == 1
    assert "\tFAILED\t" in log_text(dirs)


def test_csv_file_override(dirs, stub, tmp_path):
    p = tmp_path / "manual.csv"
    p.write_text(CSV)
    assert main(env_for(dirs, CSV_FILE=str(p)), now=NOW) == 0
    assert "rows: 1" in log_text(dirs)


def test_script_runs_as_program(dirs, stub, tmp_path):
    p = put(dirs, "review/r.csv")
    env = {**os.environ, **env_for(dirs, CSV_FILE=str(p))}
    proc = subprocess.run(
        [sys.executable, str(ROOT / "deleteme_cleanup.py")],
        env=env,
        capture_output=True,
        text=True,
        cwd=tmp_path,
    )
    assert proc.returncode == 0, proc.stderr
    assert "mode: DRY RUN" in proc.stdout
    assert list(dirs[0].glob("cleanup_run_*.log"))

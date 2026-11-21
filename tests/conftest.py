import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import json  # noqa: E402

import pytest  # noqa: E402

STUB_DIR = Path(__file__).resolve().parent / "stub"


class Seq(list):
    """Successive responses for one stub entry (the last one repeats)."""


class Stub:
    def __init__(self, tmp_path):
        self.fixture = tmp_path / "stub_fixture.json"
        self.calls_file = tmp_path / "stub_calls.jsonl"
        self.calls_file.touch()
        self.entries = []

    def set(self, entries):
        """entries: list of (match, response) or (match, Seq([responses])); a response is a
        dict with stdout/rc/stderr, or any other value meaning that stdout with rc 0."""
        self.entries = []
        for match, resp in entries:
            resps = resp if isinstance(resp, Seq) else [resp]
            self.entries.append(
                {
                    "match": match,
                    "responses": [r if _is_resp(r) else {"stdout": r} for r in resps],
                }
            )
        self.fixture.write_text(json.dumps(self.entries))
        Path(str(self.fixture) + ".state").unlink(missing_ok=True)

    def add(self, match, resp):
        self.set(
            [(e["match"], Seq(e["responses"])) for e in self.entries] + [(match, resp)]
        )

    def calls(self):
        return [json.loads(line) for line in self.calls_file.read_text().splitlines()]


def _is_resp(r):
    return isinstance(r, dict) and set(r) <= {"stdout", "rc", "stderr"} and bool(r)


@pytest.fixture
def stub(tmp_path, monkeypatch):
    s = Stub(tmp_path)
    s.set([])
    monkeypatch.setenv("PATH", f"{STUB_DIR}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("STUB_FIXTURE", str(s.fixture))
    monkeypatch.setenv("STUB_CALLS", str(s.calls_file))
    return s

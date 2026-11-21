"""Read a reviewed cleanup CSV (as written by the report job, possibly re-saved by Excel)."""

import csv
from dataclasses import dataclass
from pathlib import Path


class InputError(Exception):
    """The input file cannot be used; nothing should be deleted."""


@dataclass(frozen=True)
class Row:
    line: int
    delete: bool
    explicit_no: bool
    name: str
    type: str
    crn: str


def read_rows(path: str | Path) -> list[Row]:
    try:
        with open(path, encoding="utf-8-sig", newline="") as f:
            reader = csv.reader(f)
            header = [h.strip().lower() for h in next(reader, [])]
            missing = [c for c in ("delete", "crn") if c not in header]
            if missing:
                raise InputError(
                    f"CSV header is missing column(s): {', '.join(missing)}"
                )
            rows = []
            for values in reader:
                values = [v.strip() for v in values]
                if not any(values):
                    continue
                rec = dict(zip(header, values))
                flag = rec.get("delete", "").lower()
                rows.append(
                    Row(
                        line=len(rows) + 1,
                        delete=flag == "yes",
                        explicit_no=flag == "no",
                        name=rec.get("name", ""),
                        type=rec.get("type", ""),
                        crn=rec.get("crn", ""),
                    )
                )
            return rows
    except UnicodeDecodeError as e:
        raise InputError(f"CSV is not valid UTF-8: {e}") from e
    except (OSError, csv.Error) as e:
        raise InputError(f"cannot read CSV: {e}") from e

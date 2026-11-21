import pytest

from deleteme.csvin import InputError, read_rows

HEADER = "delete,name,service_name,type,region,resource_group_id,creation_date,tags,crn"


def write(tmp_path, data):
    p = tmp_path / "r.csv"
    p.write_bytes(data if isinstance(data, bytes) else data.encode())
    return p


def test_reads_report_csv(tmp_path):
    p = write(
        tmp_path,
        HEADER
        + '\n"no","vm1","is","vpc","ca-tor","rg1","2026","a;b","crn:1"'
        + '\n"yes","vm2","is","vpc","ca-tor","rg1","2026","a;b","crn:2"\n',
    )
    rows = read_rows(p)
    assert [(r.line, r.delete, r.explicit_no, r.crn) for r in rows] == [
        (1, False, True, "crn:1"),
        (2, True, False, "crn:2"),
    ]
    assert rows[1].name == "vm2" and rows[1].type == "vpc"


def test_bom_and_crlf(tmp_path):
    p = write(tmp_path, b'\xef\xbb\xbfdelete,name,crn\r\n"Yes","a","crn:1"\r\n')
    rows = read_rows(p)
    assert len(rows) == 1 and rows[0].delete is True and rows[0].crn == "crn:1"


def test_cr_only_and_trailing_blank(tmp_path):
    p = write(tmp_path, b'delete,crn\r"yes","crn:1"\r\r')
    rows = read_rows(p)
    assert len(rows) == 1 and rows[0].delete is True


def test_reordered_and_unquoted(tmp_path):
    p = write(tmp_path, "crn,name,delete\ncrn:1,a,YES\n")
    rows = read_rows(p)
    assert rows[0].delete is True and rows[0].crn == "crn:1" and rows[0].name == "a"


def test_name_with_comma_quote_newline(tmp_path):
    p = write(tmp_path, 'delete,name,crn\n"yes","a, ""b""\nc","crn:1"\n')
    rows = read_rows(p)
    assert len(rows) == 1 and rows[0].name == 'a, "b"\nc'


@pytest.mark.parametrize("value", ["y", "true", ""])
def test_other_values_not_yes(tmp_path, value):
    p = write(tmp_path, f'delete,name,crn\n"{value}","a","crn:1"\n')
    rows = read_rows(p)
    assert rows[0].delete is False and rows[0].explicit_no is False


def test_missing_crn_header_raises(tmp_path):
    with pytest.raises(InputError):
        read_rows(write(tmp_path, "delete,name\nyes,a\n"))


def test_missing_delete_header_raises(tmp_path):
    with pytest.raises(InputError):
        read_rows(write(tmp_path, "name,crn\na,crn:1\n"))


def test_not_utf8_raises(tmp_path):
    with pytest.raises(InputError):
        read_rows(write(tmp_path, b"delete,crn\n\xff\xfe\n"))

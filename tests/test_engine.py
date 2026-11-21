from cloudfix import (
    BOTH,
    item,
    pgw_crn,
    project_crn,
    search,
    subnet_crn,
    vpc_crn,
    vpc_entries,
)
from conftest import Seq
from deleteme.cloud import Cloud
from deleteme.csvin import Row
from deleteme.engine import run
from deleteme.protect import build_protected

VPC = "r038-aaaa"
SN = "02q7-ssss"
GW = "r038-gggg"
PROJ = "d6095178-b1de-4861-898a-cd0035a2b236"
PROJ2 = "11111111-2222-3333-4444-555555555555"
RST_COS = (
    "crn:v1:bluemix:public:cloud-object-storage:global:a/db1a8b544a184fd7ac339c243684a9b7:"
    "4c2b8b6a-2217-422b-ad57-e48380ae1ba4::"
)


def rows(*specs):
    """specs: (delete_flag, crn) or (delete_flag, crn, type)."""
    out = []
    for i, spec in enumerate(specs, 1):
        flag, crn = spec[0], spec[1]
        out.append(
            Row(
                line=i,
                delete=flag == "yes",
                explicit_no=flag == "no",
                name=f"row{i}",
                type=spec[2] if len(spec) > 2 else "",
                crn=crn,
            )
        )
    return out


def vpc_scenario(
    stub,
    *,
    sn_tags=BOTH,
    gw_tags=BOTH,
    region="ca-tor",
    after=None,
    sn_gone_later=False,
    **kw,
):
    """VPC with one subnet attached to one gateway.

    after: list results for later polls; sn_gone_later: the subnet's second lookup finds nothing.
    """
    sn_match, sn_found = search(
        subnet_crn(SN), item("a-sn", "subnet", subnet_crn(SN), sn_tags)
    )
    entries = [
        search(
            vpc_crn(VPC, region),
            item("vpc-a", "vpc", vpc_crn(VPC, region), BOTH, region),
        ),
        (sn_match, Seq([sn_found, {"items": []}]) if sn_gone_later else sn_found),
        search(pgw_crn(GW), item("a-pgw", "public-gateway", pgw_crn(GW), gw_tags)),
    ]
    children = vpc_entries(
        VPC, subnets=[(SN, "a-sn", GW)], gateways=[(GW, "a-pgw")], **kw
    )
    if after is not None:
        children = [
            (
                m,
                Seq([r, *after])
                if m.startswith(("is subnets", "is public-gateways"))
                else r,
            )
            for m, r in children
        ]
    stub.set(entries + children)


def project_scenario(stub, guid=PROJ, tags=BOTH):
    stub.add(
        *search(
            project_crn(guid),
            item("proj", "resource-instance", project_crn(guid), tags, resource_id=""),
        )
    )


def go(rs, *, dry_run, env=None, **kw):
    events = []
    result = run(
        rs,
        Cloud(),
        dry_run=dry_run,
        protected=build_protected(env or {}),
        emit=events.append,
        sleep=kw.pop("sleep", lambda s: None),
        **kw,
    )
    assert result == events
    return events


def outcomes(events):
    return [(e.outcome, e.name) for e in events]


def deletes(stub):
    return [c for c in stub.calls() if any("-delete" in a or "-detach" in a for a in c)]


def test_dry_run_issues_no_deletes(stub):
    vpc_scenario(stub)
    project_scenario(stub)
    ev = go(rows(("yes", vpc_crn(VPC)), ("yes", project_crn(PROJ))), dry_run=True)
    assert outcomes(ev) == [
        ("WOULD_DELETE", "a-sn"),
        ("WOULD_DELETE", "a-pgw"),
        ("WOULD_DELETE", "vpc-a"),
        ("WOULD_DELETE", "proj"),
    ]
    assert "detach from a-sn" in ev[1].reason
    assert deletes(stub) == []


def test_live_vpc_cascade_order(stub):
    vpc_scenario(stub, after=[[]])
    ev = go(rows(("yes", vpc_crn(VPC))), dry_run=False)
    assert [c[:2] for c in deletes(stub)] == [
        ["is", "subnet-public-gateway-detach"],
        ["is", "subnet-delete"],
        ["is", "public-gateway-delete"],
        ["is", "vpc-delete"],
    ]
    assert outcomes(ev) == [
        ("DELETED", "a-sn"),
        ("DELETED", "a-pgw"),
        ("DELETED", "vpc-a"),
    ]


def test_waits_for_children_before_vpc(stub):
    sub = [{"id": SN, "name": "a-sn", "crn": subnet_crn(SN), "public_gateway": None}]
    vpc_scenario(stub, after=[sub, []])
    slept = []
    go(rows(("yes", vpc_crn(VPC))), dry_run=False, sleep=slept.append, poll=10)
    calls = [c[:2] for c in stub.calls()]
    assert calls.index(["is", "vpc-delete"]) > max(
        i for i, c in enumerate(calls) if c == ["is", "subnets"]
    )
    assert slept == [10]


def test_wait_timeout_fails_vpc(stub):
    vpc_scenario(stub)  # children never go away
    ev = go(rows(("yes", vpc_crn(VPC))), dry_run=False, wait_timeout=20, poll=10)
    assert ev[-1].outcome == "FAILED" and ev[-1].name == "vpc-a"
    assert "still deleting" in ev[-1].reason
    assert ["is", "vpc-delete", VPC, "-f"] not in stub.calls()


def test_child_gone_before_delete(stub):
    vpc_scenario(stub, after=[[]], sn_gone_later=True)
    stub.add("is subnet-delete", {"rc": 1, "stderr": "not found"})
    ev = go(rows(("yes", vpc_crn(VPC))), dry_run=False)
    assert ("ALREADY_GONE", "a-sn") in outcomes(ev)
    assert ["is", "vpc-delete", VPC, "-f"] in stub.calls()


def test_child_delete_failure_stops_vpc(stub):
    vpc_scenario(stub, after=[[]])
    stub.add("is subnet-delete", {"rc": 1, "stderr": "conflict"})
    ev = go(rows(("yes", vpc_crn(VPC))), dry_run=False)
    assert ("FAILED", "a-sn") in outcomes(ev)
    assert "conflict" in [e for e in ev if e.outcome == "FAILED"][0].reason
    assert ["is", "vpc-delete", VPC, "-f"] not in stub.calls()


def test_tags_from_live_lookup_not_csv(stub):
    crn = vpc_crn(VPC)
    stub.set([search(crn, item("vpc-a", "vpc", crn, ["owner:ryantiffany"]))])
    ev = go(rows(("yes", crn)), dry_run=False)
    assert ev[0].outcome == "SKIP_TAGS" and "deleteme" in ev[0].reason
    assert deletes(stub) == []


def test_protected_never_deleted(stub):
    ev = go(rows(("yes", RST_COS)), dry_run=False)
    assert ev[0].outcome == "SKIP_PROTECTED"
    assert stub.calls() == []


def test_protected_child_blocks_vpc(stub):
    vpc_scenario(stub)
    ev = go(
        rows(("yes", vpc_crn(VPC))),
        dry_run=False,
        env={"PROTECTED_CRNS": subnet_crn(SN)},
    )
    assert ev[0].outcome == "SKIP_CHILD" and "a-sn" in ev[0].reason
    assert deletes(stub) == []


def test_untagged_child_blocks_vpc(stub):
    vpc_scenario(stub, sn_tags=["owner:ryantiffany"])
    ev = go(rows(("yes", vpc_crn(VPC))), dry_run=False)
    assert outcomes(ev) == [("SKIP_CHILD", "vpc-a")] and "a-sn" in ev[0].reason
    assert deletes(stub) == []


def test_child_explicit_no_after_vpc_row(stub):
    vpc_scenario(stub)
    ev = go(rows(("yes", vpc_crn(VPC)), ("no", subnet_crn(SN))), dry_run=False)
    assert ev[0].outcome == "SKIP_CHILD" and "a-sn" in ev[0].reason
    assert deletes(stub) == []


def test_blocker_blocks_vpc(stub):
    nic = {
        "name": "nic",
        "owner": "user",
        "target": {"resource_type": "network_interface"},
    }
    vpc_scenario(stub, reserved={SN: [nic]})
    ev = go(rows(("yes", vpc_crn(VPC))), dry_run=False)
    assert ev[0].outcome == "SKIP_CHILD" and "attached" in ev[0].reason
    assert deletes(stub) == []


def test_standalone_subnet_unsupported(stub):
    vpc_scenario(stub)
    ev = go(rows(("yes", subnet_crn(SN))), dry_run=False)
    assert ev[0].outcome == "SKIP_UNSUPPORTED" and "subnet" in ev[0].reason


def test_unknown_type_unsupported(stub):
    crn = "crn:v1:bluemix:public:kms:ca-tor:a/x:inst:key:k1"
    stub.set([search(crn, item("k", "key", crn, BOTH))])
    ev = go(rows(("yes", crn)), dry_run=False)
    assert ev[0].outcome == "SKIP_UNSUPPORTED"
    assert deletes(stub) == []


def test_missing_crn_logged(stub):
    ev = go(rows(("yes", "")), dry_run=False)
    assert outcomes(ev) == [("SKIP_NO_CRN", "row1")]


def test_already_gone(stub):
    stub.set([search(project_crn(PROJ))])
    ev = go(rows(("yes", project_crn(PROJ))), dry_run=False)
    assert ev[0].outcome == "ALREADY_GONE"


def test_rows_not_marked_yes_are_ignored(stub):
    project_scenario(stub)
    assert (
        go(rows(("no", project_crn(PROJ)), ("", project_crn(PROJ))), dry_run=False)
        == []
    )
    assert stub.calls() == []


def test_duplicate_crn_acted_once(stub):
    project_scenario(stub)
    go(rows(("yes", project_crn(PROJ)), ("yes", project_crn(PROJ))), dry_run=False)
    assert len(deletes(stub)) == 1


def test_service_instance_deleted_to_reclamation(stub):
    project_scenario(stub)
    ev = go(rows(("yes", project_crn(PROJ))), dry_run=False)
    assert outcomes(ev) == [("DELETED", "proj")] and "reclamation" in ev[0].reason
    assert deletes(stub) == [
        ["resource", "service-instance-delete", project_crn(PROJ), "--recursive", "-f"]
    ]


def test_failure_continues(stub):
    project_scenario(stub)
    project_scenario(stub, PROJ2)
    stub.add(
        f"resource service-instance-delete {project_crn(PROJ)}",
        {"rc": 1, "stderr": "boom"},
    )
    ev = go(
        rows(("yes", project_crn(PROJ)), ("yes", project_crn(PROJ2))), dry_run=False
    )
    assert [e.outcome for e in ev] == ["FAILED", "DELETED"]


def test_targets_vpc_region(stub):
    vpc_scenario(stub, region="us-south")
    go(rows(("yes", vpc_crn(VPC, "us-south"))), dry_run=True)
    calls = stub.calls()
    first_is = next(i for i, c in enumerate(calls) if c[0] == "is")
    assert ["target", "-r", "us-south", "-q"] in calls[:first_is]

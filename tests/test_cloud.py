import pytest

from cloudfix import BOTH, item, project_crn, search, vpc_crn, vpc_entries
from deleteme.cloud import Cloud, CloudError

VPC_A = "r038-3e0724d4-76de-4e40-a53a-d0db307dd6bc"
SN_A = "02q7-e0b18af9-2a7e-4543-bc1d-e3b4900cb238"
GW_A = "r038-f52e0a66-722e-4716-973b-e69687a90a9d"
PROJ = "d6095178-b1de-4861-898a-cd0035a2b236"


def test_lookup_returns_tags_and_type(stub):
    crn = vpc_crn(VPC_A)
    stub.set([search(crn, item("ce-test-vpc-a", "vpc", crn, BOTH))])
    r = Cloud().lookup(crn)
    assert r.type == "vpc" and r.name == "ce-test-vpc-a"
    assert r.tags == frozenset(BOTH) and r.resource_id == VPC_A and r.region == "ca-tor"


def test_lookup_missing_returns_none(stub):
    stub.set(
        [
            search(
                "crn:x",
            )
        ]
    )
    assert Cloud().lookup("crn:x") is None


def test_lookup_resource_id_fallback(stub):
    crn = project_crn(PROJ)
    stub.set(
        [
            search(
                crn,
                item("ce-test-proj", "resource-instance", crn, BOTH, resource_id=""),
            )
        ]
    )
    assert Cloud().lookup(crn).resource_id == PROJ


def test_vpc_children_lists_subnets_and_gateways(stub):
    stub.set(
        vpc_entries(
            VPC_A,
            subnets=[(SN_A, "ce-test-a-sn", GW_A)],
            gateways=[(GW_A, "ce-test-a-pgw")],
        )
    )
    c = Cloud().vpc_children(VPC_A)
    assert [(s.id, s.name, s.kind, s.gateway_id) for s in c.subnets] == [
        (SN_A, "ce-test-a-sn", "subnet", GW_A)
    ]
    assert [(g.id, g.kind) for g in c.gateways] == [(GW_A, "public-gateway")]
    assert c.subnets[0].crn.endswith(f"subnet:{SN_A}")


def test_default_sg_acl_rt_and_provider_ips_are_not_blockers(stub):
    stub.set(vpc_entries(VPC_A, subnets=[(SN_A, "s", "")]))
    assert Cloud().vpc_children(VPC_A).blockers == []


def test_attached_and_custom_items_are_blockers(stub):
    nic = {
        "name": "vm-nic",
        "owner": "user",
        "target": {"resource_type": "network_interface"},
    }
    stub.set(
        vpc_entries(
            VPC_A,
            subnets=[(SN_A, "s", "")],
            extra_sg=["mysg"],
            extra_acl=["myacl"],
            extra_rt=["myrt"],
            reserved={SN_A: [nic]},
        )
    )
    b = Cloud().vpc_children(VPC_A).blockers
    assert len(b) == 4
    joined = " | ".join(b)
    for word in ("network_interface", "mysg", "myacl", "myrt"):
        assert word in joined


def test_cli_failure_raises(stub):
    stub.set([("is subnet-delete", {"rc": 1, "stderr": "Error: not authorized"})])
    with pytest.raises(CloudError, match="not authorized"):
        Cloud().delete_subnet(SN_A)


def test_service_delete_command(stub):
    crn = project_crn(PROJ)
    Cloud().delete_service_instance(crn)
    assert stub.calls() == [
        ["resource", "service-instance-delete", crn, "--recursive", "-f"]
    ]


def test_vpc_delete_commands(stub):
    c = Cloud()
    c.detach_gateway(SN_A)
    c.delete_gateway(GW_A)
    c.delete_vpc(VPC_A)
    assert stub.calls() == [
        ["is", "subnet-public-gateway-detach", SN_A, "-f"],
        ["is", "public-gateway-delete", GW_A, "-f"],
        ["is", "vpc-delete", VPC_A, "-f"],
    ]


def test_target_region_once(stub):
    c = Cloud()
    c.target_region("us-south")
    c.target_region("us-south")
    assert stub.calls() == [["target", "-r", "us-south", "-q"]]


def test_remaining(stub):
    stub.set(vpc_entries(VPC_A, subnets=[(SN_A, "s", GW_A)], gateways=[(GW_A, "g")]))
    assert Cloud().remaining(VPC_A, {SN_A, "gone-sn"}, {GW_A}) == {SN_A, GW_A}


def test_non_json_raises(stub):
    stub.set([("resource search", "not json")])
    with pytest.raises(CloudError):
        Cloud().lookup("crn:x")


def test_lookup_crn_mismatch_raises(stub):
    asked = vpc_crn(VPC_A)
    other = vpc_crn("r038-other")
    stub.set([search(asked, item("other", "vpc", other, BOTH))])
    with pytest.raises(CloudError, match="different resource"):
        Cloud().lookup(asked)


def test_lists_span_all_resource_groups(stub):
    stub.set(vpc_entries(VPC_A, subnets=[(SN_A, "s", "")]))
    Cloud().vpc_children(VPC_A)
    for c in stub.calls():
        if c[1] in ("subnets", "security-groups", "public-gateways", "network-acls"):
            assert "--all-resource-groups" in c, c


def test_provider_owned_attached_ip_is_blocker(stub):
    lb = {
        "name": "lb-ip",
        "owner": "provider",
        "target": {"resource_type": "load_balancer"},
    }
    stub.set(vpc_entries(VPC_A, subnets=[(SN_A, "s", "")], reserved={SN_A: [lb]}))
    b = Cloud().vpc_children(VPC_A).blockers
    assert len(b) == 1 and "load_balancer" in b[0]

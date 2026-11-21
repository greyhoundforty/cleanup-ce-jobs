"""Fixture builders shaped like real ibmcloud JSON (probed from the ce-test-* resources)."""

ACCT = "a/db1a8b544a184fd7ac339c243684a9b7"
BOTH = ["deleteme", "owner:ryantiffany"]


def vpc_crn(vid, region="ca-tor"):
    return f"crn:v1:bluemix:public:is:{region}:{ACCT}::vpc:{vid}"


def subnet_crn(sid):
    return f"crn:v1:bluemix:public:is:ca-tor-1:{ACCT}::subnet:{sid}"


def pgw_crn(gid):
    return f"crn:v1:bluemix:public:is:ca-tor-1:{ACCT}::public-gateway:{gid}"


def project_crn(guid):
    return f"crn:v1:bluemix:public:codeengine:ca-tor:{ACCT}:{guid}::"


def item(name, type_, crn, tags, region="ca-tor", resource_id=None):
    if resource_id is None:
        resource_id = crn.split(":")[9]
    return {
        "name": name,
        "type": type_,
        "crn": crn,
        "tags": tags,
        "region": region,
        "resource_id": resource_id,
        "service_name": "is",
    }


def search(crn, *items):
    """(match, response) for a resource search by CRN."""
    return (f'resource search crn:"{crn}"', {"items": list(items)})


def vpc_entries(
    vid,
    *,
    subnets=(),
    gateways=(),
    region="ca-tor",
    extra_sg=(),
    extra_acl=(),
    extra_rt=(),
    reserved=None,
):
    """Stub entries describing a VPC's children.

    subnets: (sid, name, gateway_id or "") ; gateways: (gid, name)
    reserved: {sid: [reserved ip dicts]}; defaults to provider-only IPs.
    """
    reserved = reserved or {}
    sub_json = [
        {
            "id": sid,
            "name": name,
            "crn": subnet_crn(sid),
            "public_gateway": {"id": gw} if gw else None,
        }
        for sid, name, gw in subnets
    ]
    gw_json = [
        {"id": gid, "name": name, "crn": pgw_crn(gid), "vpc": {"id": vid}}
        for gid, name in gateways
    ] + [
        {
            "id": "other-gw",
            "name": "x",
            "crn": pgw_crn("other-gw"),
            "vpc": {"id": "other"},
        }
    ]
    entries = [
        (f"is subnets --vpc {vid}", sub_json),
        ("is public-gateways", gw_json),
        (
            f"is vpc {vid}",
            {
                "id": vid,
                "default_security_group": {"id": "sg-default"},
                "default_network_acl": {"id": "acl-default"},
            },
        ),
        (
            f"is security-groups --vpc {vid}",
            [{"id": "sg-default", "name": "def-sg"}]
            + [{"id": f"sg-{n}", "name": n} for n in extra_sg],
        ),
        (
            "is network-acls",
            [
                {"id": "acl-default", "name": "def-acl", "vpc": {"id": vid}},
                {"id": "acl-other", "name": "o", "vpc": {"id": "other"}},
            ]
            + [{"id": f"acl-{n}", "name": n, "vpc": {"id": vid}} for n in extra_acl],
        ),
        (
            f"is vpc-routing-tables {vid}",
            [{"id": "rt-default", "name": "def-rt", "is_default": True}]
            + [{"id": f"rt-{n}", "name": n, "is_default": False} for n in extra_rt],
        ),
    ]
    provider = [{"name": "ibm-network-address", "owner": "provider", "target": None}]
    for sid, _name, _gw in subnets:
        entries.append(
            (f"is subnet-reserved-ips {sid}", provider + reserved.get(sid, []))
        )
    return entries

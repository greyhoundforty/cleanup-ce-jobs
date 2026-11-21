"""Thin wrapper around the ibmcloud CLI for the deleteme cleanup job."""

import json
import subprocess
from dataclasses import dataclass


class CloudError(Exception):
    """An ibmcloud command failed or returned unusable output."""


@dataclass(frozen=True)
class Resource:
    crn: str
    name: str
    type: str
    region: str
    resource_id: str
    tags: frozenset[str]


@dataclass(frozen=True)
class Child:
    id: str
    crn: str
    name: str
    kind: str
    gateway_id: str = ""


@dataclass(frozen=True)
class VpcChildren:
    subnets: list[Child]
    gateways: list[Child]
    blockers: list[str]


class Cloud:
    def __init__(self, binary: str = "ibmcloud"):
        self.binary = binary
        self._region = None

    def _run(self, *args: str) -> str:
        proc = subprocess.run([self.binary, *args], capture_output=True, text=True)
        if proc.returncode != 0:
            msg = (
                proc.stderr.strip() or proc.stdout.strip()
            ) or f"exit {proc.returncode}"
            raise CloudError(f"ibmcloud {' '.join(args[:2])}: {msg}")
        return proc.stdout

    def _json(self, *args: str):
        out = self._run(*args)
        try:
            return json.loads(out)
        except json.JSONDecodeError as e:
            raise CloudError(
                f"ibmcloud {' '.join(args[:2])}: output is not JSON"
            ) from e

    def lookup(self, crn: str) -> Resource | None:
        data = self._json("resource", "search", f'crn:"{crn}"', "--output", "json")
        items = data.get("items") if isinstance(data, dict) else None
        if not isinstance(items, list):
            raise CloudError("ibmcloud resource search: unexpected output")
        if not items:
            return None
        it = items[0]
        parts = (it.get("crn") or crn).split(":") + [""] * 10
        resource_id = it.get("resource_id") or parts[9] or parts[7]
        return Resource(
            crn=it.get("crn") or crn,
            name=it.get("name") or "",
            type=it.get("type") or "",
            region=it.get("region") or "",
            resource_id=resource_id,
            tags=frozenset(t for t in (it.get("tags") or []) if isinstance(t, str)),
        )

    def target_region(self, region: str) -> None:
        if region and region != self._region:
            self._run("target", "-r", region, "-q")
            self._region = region

    def _subnets(self, vpc_id: str) -> list[dict]:
        return self._json("is", "subnets", "--vpc", vpc_id, "--output", "JSON")

    def _gateways(self, vpc_id: str) -> list[dict]:
        gws = self._json(
            "is", "public-gateways", "--all-resource-groups", "--output", "JSON"
        )
        return [g for g in gws if (g.get("vpc") or {}).get("id") == vpc_id]

    def vpc_children(self, vpc_id: str) -> VpcChildren:
        subnets = [
            Child(
                id=s["id"],
                crn=s.get("crn", ""),
                name=s.get("name", ""),
                kind="subnet",
                gateway_id=(s.get("public_gateway") or {}).get("id", ""),
            )
            for s in self._subnets(vpc_id)
        ]
        gateways = [
            Child(
                id=g["id"],
                crn=g.get("crn", ""),
                name=g.get("name", ""),
                kind="public-gateway",
            )
            for g in self._gateways(vpc_id)
        ]
        vpc = self._json("is", "vpc", vpc_id, "--output", "JSON")
        default_sg = (vpc.get("default_security_group") or {}).get("id")
        default_acl = (vpc.get("default_network_acl") or {}).get("id")

        blockers = []
        for s in subnets:
            for ip in self._json("is", "subnet-reserved-ips", s.id, "--output", "JSON"):
                if ip.get("owner") == "user":
                    what = (ip.get("target") or {}).get("resource_type") or ip.get(
                        "name", "?"
                    )
                    blockers.append(f"subnet {s.name}: attached {what}")
        for sg in self._json(
            "is", "security-groups", "--vpc", vpc_id, "--output", "JSON"
        ):
            if sg.get("id") != default_sg:
                blockers.append(f"security group {sg.get('name')}")
        acls = self._json(
            "is", "network-acls", "--all-resource-groups", "--output", "JSON"
        )
        for acl in acls:
            if (acl.get("vpc") or {}).get("id") == vpc_id and acl.get(
                "id"
            ) != default_acl:
                blockers.append(f"network ACL {acl.get('name')}")
        for rt in self._json("is", "vpc-routing-tables", vpc_id, "--output", "JSON"):
            if not rt.get("is_default"):
                blockers.append(f"routing table {rt.get('name')}")
        return VpcChildren(subnets=subnets, gateways=gateways, blockers=blockers)

    def remaining(
        self, vpc_id: str, subnet_ids: set[str], gateway_ids: set[str]
    ) -> set[str]:
        left = {s["id"] for s in self._subnets(vpc_id)} & subnet_ids
        if gateway_ids:
            left |= {g["id"] for g in self._gateways(vpc_id)} & gateway_ids
        return left

    def detach_gateway(self, subnet_id: str) -> None:
        self._run("is", "subnet-public-gateway-detach", subnet_id, "-f")

    def delete_subnet(self, subnet_id: str) -> None:
        self._run("is", "subnet-delete", subnet_id, "-f")

    def delete_gateway(self, gateway_id: str) -> None:
        self._run("is", "public-gateway-delete", gateway_id, "-f")

    def delete_vpc(self, vpc_id: str) -> None:
        self._run("is", "vpc-delete", vpc_id, "-f")

    def delete_service_instance(self, crn: str) -> None:
        self._run("resource", "service-instance-delete", crn, "--recursive", "-f")

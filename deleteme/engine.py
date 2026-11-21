"""Decide and carry out what a reviewed CSV asks for, one row at a time."""

import time
from collections.abc import Callable
from dataclasses import dataclass

from deleteme.cloud import Cloud, CloudError, Child, Resource
from deleteme.csvin import Row
from deleteme.protect import crn_key, is_protected

DELETED = "DELETED"
WOULD_DELETE = "WOULD_DELETE"
ALREADY_GONE = "ALREADY_GONE"
SKIP_TAGS = "SKIP_TAGS"
SKIP_PROTECTED = "SKIP_PROTECTED"
SKIP_CHILD = "SKIP_CHILD"
SKIP_UNSUPPORTED = "SKIP_UNSUPPORTED"
SKIP_NO_CRN = "SKIP_NO_CRN"
SKIP_CONFLICT = "SKIP_CONFLICT"
FAILED = "FAILED"
OUTCOMES = (
    DELETED,
    WOULD_DELETE,
    ALREADY_GONE,
    SKIP_TAGS,
    SKIP_PROTECTED,
    SKIP_CHILD,
    SKIP_UNSUPPORTED,
    SKIP_NO_CRN,
    SKIP_CONFLICT,
    FAILED,
)

REQUIRED_TAGS = ("deleteme", "owner:ryantiffany")


@dataclass(frozen=True)
class Event:
    outcome: str
    type: str
    name: str
    crn: str
    reason: str = ""


def _missing_tags(tags: frozenset[str]) -> list[str]:
    return [t for t in REQUIRED_TAGS if t not in tags]


class _Run:
    def __init__(self, cloud, dry_run, protected, emit, sleep, wait_timeout, poll):
        self.cloud = cloud
        self.dry_run = dry_run
        self.protected = protected
        self.sleep = sleep
        self.wait_timeout = wait_timeout
        self.poll = poll
        self.events: list[Event] = []
        self._emit = emit
        self.child_rows: list[Resource] = []  # subnet/gateway rows marked yes
        self.handled: set = set()  # keys this run deleted, would delete, or found gone

    def emit(self, outcome, type_, name, crn, reason=""):
        ev = Event(outcome, type_, name, crn, reason)
        if outcome in (DELETED, WOULD_DELETE, ALREADY_GONE) and crn:
            self.handled.add(crn_key(crn))
        self.events.append(ev)
        self._emit(ev)

    def row(self, row: Row, explicit_no: set) -> None:
        if is_protected(row.crn, self.protected):
            self.emit(
                SKIP_PROTECTED, row.type, row.name, row.crn, "on the protected list"
            )
            return
        try:
            res = self.cloud.lookup(row.crn)
        except CloudError as e:
            self.emit(FAILED, row.type, row.name, row.crn, f"lookup failed: {e}")
            return
        if res is None:
            self.emit(ALREADY_GONE, row.type, row.name, row.crn, "not found")
            return
        if is_protected(res.crn, self.protected):
            self.emit(
                SKIP_PROTECTED, res.type, res.name, res.crn, "on the protected list"
            )
            return
        missing = _missing_tags(res.tags)
        if missing:
            self.emit(
                SKIP_TAGS,
                res.type,
                res.name,
                res.crn,
                "missing tag(s): " + ", ".join(missing),
            )
            return
        if res.type == "vpc":
            self.vpc(res, explicit_no)
        elif res.type == "resource-instance":
            self.service(res)
        elif res.type in ("subnet", "public-gateway"):
            # Deleted only through their VPC's cascade; reported at the end if it did not.
            self.child_rows.append(res)
        else:
            self.emit(
                SKIP_UNSUPPORTED,
                res.type,
                res.name,
                res.crn,
                f"type {res.type} not supported",
            )

    def service(self, res: Resource) -> None:
        if self.dry_run:
            self.emit(WOULD_DELETE, res.type, res.name, res.crn, "to reclamation")
            return
        try:
            self.cloud.delete_service_instance(res.crn)
        except CloudError as e:
            self.emit(FAILED, res.type, res.name, res.crn, str(e))
            return
        self.emit(DELETED, res.type, res.name, res.crn, "to reclamation")

    def _child_reasons(self, child: Child, explicit_no: set) -> list[str]:
        label = f"{child.kind} {child.name}"
        if is_protected(child.crn, self.protected):
            return [f"{label} is protected"]
        if not child.crn:
            return [f"{label} has no CRN, so its tags cannot be checked"]
        if crn_key(child.crn) in explicit_no:
            return [f"{label} is marked no"]
        found = self.cloud.lookup(child.crn)
        if found is None:
            # It was just listed, so it exists; search cannot vouch for its tags yet.
            return [f"{label} not found by search, so its tags cannot be checked"]
        missing = _missing_tags(found.tags)
        return [f"{label} missing tag(s): {', '.join(missing)}"] if missing else []

    def vpc(self, res: Resource, explicit_no: set) -> None:
        try:
            self.cloud.target_region(res.region)
            kids = self.cloud.vpc_children(res.resource_id)
            reasons = list(kids.blockers)
            for child in kids.subnets + kids.gateways:
                reasons += self._child_reasons(child, explicit_no)
        except CloudError as e:
            self.emit(
                FAILED, res.type, res.name, res.crn, f"listing children failed: {e}"
            )
            return
        if reasons:
            self.emit(SKIP_CHILD, res.type, res.name, res.crn, "; ".join(reasons))
            return

        attached = {}
        for s in kids.subnets:
            if s.gateway_id:
                attached.setdefault(s.gateway_id, []).append(s.name)

        def gw_reason(g):
            names = attached.get(g.id)
            return f"detach from {', '.join(names)}, then delete" if names else ""

        if self.dry_run:
            for s in kids.subnets:
                self.emit(WOULD_DELETE, s.kind, s.name, s.crn)
            for g in kids.gateways:
                self.emit(WOULD_DELETE, g.kind, g.name, g.crn, gw_reason(g))
            self.emit(WOULD_DELETE, res.type, res.name, res.crn)
            return

        steps = [
            (s, self.cloud.detach_gateway, None) for s in kids.subnets if s.gateway_id
        ]
        steps += [(s, self.cloud.delete_subnet, "") for s in kids.subnets]
        steps += [(g, self.cloud.delete_gateway, gw_reason(g)) for g in kids.gateways]
        gone = set()
        for child, action, reason in steps:
            if child.id in gone:
                continue
            try:
                action(child.id)
            except CloudError as e:
                try:
                    still_there = self.cloud.lookup(child.crn) is not None
                except CloudError:
                    still_there = True
                if still_there:
                    self.emit(FAILED, child.kind, child.name, child.crn, str(e))
                    return
                gone.add(child.id)
                self.emit(ALREADY_GONE, child.kind, child.name, child.crn, "not found")
                continue
            if reason is not None:
                self.emit(DELETED, child.kind, child.name, child.crn, reason)

        subnet_ids = {s.id for s in kids.subnets}
        gateway_ids = {g.id for g in kids.gateways}
        waited = 0.0
        try:
            while self.cloud.remaining(res.resource_id, subnet_ids, gateway_ids):
                if waited >= self.wait_timeout:
                    self.emit(
                        FAILED,
                        res.type,
                        res.name,
                        res.crn,
                        f"children still deleting after {int(waited)}s",
                    )
                    return
                self.sleep(self.poll)
                waited += self.poll
            self.cloud.delete_vpc(res.resource_id)
        except CloudError as e:
            self.emit(FAILED, res.type, res.name, res.crn, str(e))
            return
        self.emit(DELETED, res.type, res.name, res.crn)


def run(
    rows: list[Row],
    cloud: Cloud,
    *,
    dry_run: bool,
    protected: frozenset,
    emit: Callable[[Event], None],
    sleep: Callable[[float], None] = time.sleep,
    wait_timeout: float = 600,
    poll: float = 10,
) -> list[Event]:
    r = _Run(cloud, dry_run, protected, emit, sleep, wait_timeout, poll)
    explicit_no = {crn_key(row.crn) for row in rows if row.explicit_no and row.crn}
    seen = set()
    for row in rows:
        if not row.delete:
            continue
        if not row.crn:
            r.emit(SKIP_NO_CRN, row.type, row.name, "", "row has no crn")
            continue
        key = crn_key(row.crn)
        if key in seen:
            continue
        seen.add(key)
        if key in explicit_no:
            reason = "marked both yes and no in the CSV"
            r.emit(SKIP_CONFLICT, row.type, row.name, row.crn, reason)
            continue
        r.row(row, explicit_no)
    for res in r.child_rows:
        if crn_key(res.crn) not in r.handled:
            reason = "subnets and public gateways are only deleted with their VPC, "
            reason += "which this run did not delete"
            r.emit(SKIP_UNSUPPORTED, res.type, res.name, res.crn, reason)
    return r.events

"""Resources the cleanup job must never delete, whatever the CSV and tags say."""

from collections.abc import Mapping

BUILTIN_PROTECTED: tuple[str, ...] = (
    # rst-ce-demo: the Code Engine project the cleanup job runs in
    "crn:v1:bluemix:public:codeengine:ca-tor:a/db1a8b544a184fd7ac339c243684a9b7:"
    "661a5a9d-20c7-435c-af3b-a68806e905ea::",
    # rst-cos-instance: holds the reports bucket (and the audit log)
    "crn:v1:bluemix:public:cloud-object-storage:global:a/db1a8b544a184fd7ac339c243684a9b7:"
    "4c2b8b6a-2217-422b-ad57-e48380ae1ba4::",
)


def crn_key(crn: str) -> tuple[str, str, str, str]:
    """(service_name, service_instance, resource_type, resource) from a CRN."""
    parts = crn.strip().lower().split(":")
    parts += [""] * (10 - len(parts))
    return (parts[4], parts[7], parts[8], parts[9])


def _protect_key(crn: str) -> tuple[str, str, str, str]:
    """Service instances match on the instance alone (a bucket CRN protects its COS
    instance); instance-less CRNs (VPC resources) match on the full resource."""
    service, instance, rtype, resource = crn_key(crn)
    return (
        (service, instance, "", "")
        if instance
        else (service, instance, rtype, resource)
    )


def build_protected(env: Mapping[str, str]) -> frozenset[tuple[str, str, str, str]]:
    keys = {_protect_key(c) for c in BUILTIN_PROTECTED}
    keys |= {
        _protect_key(c) for c in env.get("PROTECTED_CRNS", "").split(",") if c.strip()
    }
    project = env.get("CE_PROJECT_ID", "").strip().lower()
    if project:
        keys.add(("codeengine", project, "", ""))
    return frozenset(keys)


def is_protected(crn: str, protected: frozenset) -> bool:
    return _protect_key(crn) in protected

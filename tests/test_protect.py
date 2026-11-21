from deleteme.protect import build_protected, is_protected

CE_DEMO = (
    "crn:v1:bluemix:public:codeengine:ca-tor:a/db1a8b544a184fd7ac339c243684a9b7:"
    "661a5a9d-20c7-435c-af3b-a68806e905ea::"
)
RST_COS = (
    "crn:v1:bluemix:public:cloud-object-storage:global:a/db1a8b544a184fd7ac339c243684a9b7:"
    "4c2b8b6a-2217-422b-ad57-e48380ae1ba4::"
)


def test_builtin_project_and_cos_protected():
    p = build_protected({})
    assert is_protected(CE_DEMO, p) and is_protected(RST_COS, p)


def test_trailing_segments_match():
    assert is_protected(RST_COS.rstrip(":"), build_protected({}))


def test_env_extra_crns():
    vpc = "crn:v1:bluemix:public:is:ca-tor:a/x::vpc:r038-1"
    p = build_protected({"PROTECTED_CRNS": f" {vpc} , "})
    assert is_protected(vpc, p)
    assert not is_protected("crn:v1:bluemix:public:is:ca-tor:a/x::vpc:r038-2", p)


def test_ce_project_id_protected():
    p = build_protected({"CE_PROJECT_ID": "ABC-123"})
    assert is_protected("crn:v1:bluemix:public:codeengine:ca-tor:a/x:abc-123::", p)


def test_unrelated_not_protected():
    proj = (
        "crn:v1:bluemix:public:codeengine:ca-tor:a/db1a8b544a184fd7ac339c243684a9b7:"
        "d6095178-b1de-4861-898a-cd0035a2b236::"
    )
    assert not is_protected(proj, build_protected({}))

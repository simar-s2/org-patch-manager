"""scripts/deploy.sh against the fake AWS CLI."""

from conftest import value


def cmds(calls):
    return [c["args"][1] for c in calls]


def params(call):
    """--parameters ParameterKey=K,ParameterValue=V ... as a dict."""
    out = {}
    for p in call["args"][call["args"].index("--parameters") + 1:]:
        key, val = p.split(",", 1)
        out[key.split("=", 1)[1]] = val.split("=", 1)[1]
    return out


def test_stack_set_without_targets_deploys_nothing(run_script):
    proc, calls = run_script("deploy.sh", "--regions", "us-east-1")
    assert proc.returncode == 0, proc.stderr
    assert cmds(calls) == ["describe-stack-set", "create-stack-set"]
    create = calls[1]
    assert value(create, "--stack-set-name") == "sec-patch-manager"
    assert value(create, "--permission-model") == "SERVICE_MANAGED"
    assert "Enabled=true" in value(create, "--auto-deployment")
    assert params(create)["ComplianceBucketName"] == ""


def test_full_rollout_with_compliance_bucket(run_script):
    proc, calls = run_script("deploy.sh", "--regions", "us-east-1,us-west-2", "--targets", "r-ab12",
                             "--prefix", "acme", "--profile", "management",
                             "--log-archive-profile", "log-archive", "--include-management",
                             "--param", "ApproveAfterDays=3")
    assert proc.returncode == 0, proc.stderr
    assert cmds(calls) == [
        "describe-organization",
        "deploy", "describe-stacks",                      # bucket in log-archive
        "describe-stack-set", "create-stack-set",
        "create-stack-instances", "describe-stack-set-operation",
        "deploy", "deploy",                               # management account stacks
    ]
    bucket_stack = calls[1]
    assert bucket_stack["opts"]["profile"] == "log-archive"
    assert "OrgId=o-exampleorgid" in bucket_stack["args"]
    stack_set = params(calls[4])
    assert stack_set["NamePrefix"] == "acme"
    assert stack_set["ComplianceBucketName"] == "sec-patch-compliance-444455556666"
    assert stack_set["ComplianceBucketRegion"] == "us-east-1"
    assert stack_set["ApproveAfterDays"] == "3"
    instances = calls[5]
    assert value(instances, "--deployment-targets") == "OrganizationalUnitIds=r-ab12"
    assert {c["opts"]["region"] for c in calls[7:]} == {"us-east-1", "us-west-2"}
    assert all(c["opts"]["profile"] == "management" for c in calls[7:])


def test_update_as_delegated_admin(run_script):
    proc, calls = run_script("deploy.sh", "--regions", "us-east-1", "--delegated-admin",
                             stack_set_exists=True)
    assert proc.returncode == 0, proc.stderr
    assert cmds(calls) == ["describe-stack-set", "update-stack-set", "describe-stack-set-operation"]
    assert all(value(c, "--call-as") == "DELEGATED_ADMIN" for c in calls)

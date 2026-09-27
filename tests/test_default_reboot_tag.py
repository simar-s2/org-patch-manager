"""scripts/default-reboot-tag.sh against the fake AWS CLI."""

from conftest import value


def creates(calls):
    return [c for c in calls if c["args"][1] == "create-tags"]


def test_tags_unclassified_instances(run_script):
    proc, calls = run_script("default-reboot-tag.sh", "--regions", "us-east-1,us-west-2")
    assert proc.returncode == 0, proc.stderr
    (tag,) = creates(calls)
    assert tag["opts"]["region"] == "us-east-1"
    assert value(tag, "--tags") == "Key=patch-reboot,Value=if-needed"
    resources = tag["args"][tag["args"].index("--resources") + 1:tag["args"].index("--tags")]
    assert resources == ["i-0a1b2c3d4e5f60001", "i-0a1b2c3d4e5f60002", "i-0a1b2c3d4e5f60003"]
    assert "us-west-2    all instances already classified or exempt" in proc.stdout


def test_query_skips_classified_exempt_and_eks_instances(run_script):
    _, calls = run_script("default-reboot-tag.sh", "--tag-key", "reboot-policy")
    (describe,) = [c for c in calls if c["args"][1] == "describe-instances"]
    query = describe["opts"]["query"]
    assert "Tags[?Key=='reboot-policy']" in query
    assert "Key=='ssm-exempt' && Value=='true'" in query
    assert "Key=='eks:cluster-name'" in query
    assert "Values=running,stopped" in value(describe, "--filters")


def test_dry_run_tags_nothing(run_script):
    proc, calls = run_script("default-reboot-tag.sh", "--dry-run", "--value", "never")
    assert proc.returncode == 0, proc.stderr
    assert creates(calls) == []
    assert "would tag 3 instance(s) patch-reboot=never" in proc.stdout


def test_batches_large_fleets(run_script):
    many = [f"i-{n:017x}" for n in range(450)]
    _, calls = run_script("default-reboot-tag.sh",
                          regions={"us-east-1": {"unclassified_instances": many}})
    batches = [c["args"].index("--tags") - c["args"].index("--resources") - 1 for c in creates(calls)]
    assert batches == [200, 200, 50]


def test_rejects_unknown_value(run_script):
    proc, calls = run_script("default-reboot-tag.sh", "--value", "always")
    assert proc.returncode == 2 and calls == []

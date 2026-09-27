"""Unit tests for the custom resource inlined in cloudformation/patch-baseline.yaml.

The function source is read straight out of the template, so the code under test
is exactly what CloudFormation deploys. boto3 and the HTTP response are faked.
"""

import json
import sys
import types
from pathlib import Path

import pytest
import yaml

TEMPLATE = Path(__file__).resolve().parent.parent / "cloudformation" / "patch-baseline.yaml"
AWS_AL2023 = "arn:aws:ssm:us-east-1:111111111111:patchbaseline/pb-0aws0al20230000"


class CfnLoader(yaml.SafeLoader):
    """Loads a CloudFormation template, ignoring short-form intrinsics like !Ref."""


CfnLoader.add_multi_constructor("!", lambda loader, suffix, node: None)


class FakeSSM:
    def __init__(self, default="pb-0aws", fail_register=False):
        self.default = default
        self.fail_register = fail_register
        self.registered = []

    def register_default_patch_baseline(self, BaselineId):
        if self.fail_register:
            raise RuntimeError("AccessDenied")
        self.registered.append(BaselineId)
        self.default = BaselineId

    def get_default_patch_baseline(self, OperatingSystem):
        return {"BaselineId": self.default}

    def describe_patch_baselines(self, Filters):
        return {"BaselineIdentities": [
            {"BaselineId": "arn:aws:ssm:us-east-1:111111111111:patchbaseline/pb-0other", "BaselineName": "AWS-Other"},
            {"BaselineId": AWS_AL2023, "BaselineName": "AWS-AmazonLinux2023DefaultPatchBaseline"},
        ]}


@pytest.fixture
def function(monkeypatch):
    """Returns (module, ssm, responses) with a fresh fake SSM client."""
    ssm = FakeSSM()
    fake_boto3 = types.ModuleType("boto3")
    fake_boto3.client = lambda name: ssm
    monkeypatch.setitem(sys.modules, "boto3", fake_boto3)

    template = yaml.load(TEMPLATE.read_text(), Loader=CfnLoader)
    source = template["Resources"]["DefaultBaselineFunction"]["Properties"]["Code"]["ZipFile"]
    module = types.ModuleType("index")
    exec(compile(source, "index.py", "exec"), module.__dict__)

    responses = []
    monkeypatch.setattr(module.urllib.request, "urlopen",
                        lambda req, timeout: responses.append(json.loads(req.data)))
    return module, ssm, responses


def event(request_type, baseline_id="pb-0ours", physical_id=None):
    e = {
        "RequestType": request_type,
        "ResponseURL": "https://cloudformation-custom-resource-response.example/",
        "StackId": "arn:aws:cloudformation:us-east-1:111122223333:stack/patch/abc",
        "RequestId": "req-1",
        "LogicalResourceId": "LinuxDefaultBaseline",
        "ResourceProperties": {"BaselineId": baseline_id, "OperatingSystem": "AMAZON_LINUX_2023"},
    }
    if physical_id:
        e["PhysicalResourceId"] = physical_id
    return e


CONTEXT = types.SimpleNamespace(log_stream_name="2026/01/01/[$LATEST]abc")


def test_create_registers_the_baseline_as_default(function):
    module, ssm, responses = function
    module.handler(event("Create"), CONTEXT)
    assert ssm.registered == ["pb-0ours"]
    assert responses[-1]["Status"] == "SUCCESS"
    assert responses[-1]["PhysicalResourceId"] == "pb-0ours"


def test_update_to_a_new_baseline_changes_the_physical_id(function):
    module, ssm, responses = function
    module.handler(event("Update", baseline_id="pb-0new", physical_id="pb-0ours"), CONTEXT)
    assert ssm.default == "pb-0new"
    assert responses[-1]["PhysicalResourceId"] == "pb-0new"


def test_delete_restores_the_aws_default_when_ours_is_active(function):
    module, ssm, responses = function
    ssm.default = "pb-0ours"
    module.handler(event("Delete", physical_id="pb-0ours"), CONTEXT)
    assert ssm.default == AWS_AL2023
    assert responses[-1]["Status"] == "SUCCESS"


def test_delete_after_replacement_keeps_the_new_default(function):
    # An update registered pb-0new; CloudFormation then deletes the old physical ID.
    module, ssm, responses = function
    ssm.default = "pb-0new"
    module.handler(event("Delete", baseline_id="pb-0ours", physical_id="pb-0ours"), CONTEXT)
    assert ssm.default == "pb-0new"
    assert ssm.registered == []
    assert responses[-1]["Status"] == "SUCCESS"


def test_delete_never_blocks_stack_deletion(function):
    module, ssm, responses = function
    ssm.default = "pb-0ours"
    ssm.fail_register = True
    module.handler(event("Delete", physical_id="pb-0ours"), CONTEXT)
    assert responses[-1]["Status"] == "SUCCESS"


def test_create_failure_is_reported_to_cloudformation(function):
    module, ssm, responses = function
    ssm.fail_register = True
    module.handler(event("Create"), CONTEXT)
    assert responses[-1]["Status"] == "FAILED"
    assert "AccessDenied" in responses[-1]["Reason"]

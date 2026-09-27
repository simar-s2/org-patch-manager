import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FAKE_AWS = ROOT / "tests" / "fake-aws"


@pytest.fixture
def run_script(tmp_path):
    """Run a script from scripts/ against the fake AWS CLI; return (process, calls)."""

    def run(script, *args, **scenario_overrides):
        scenario = json.loads((FAKE_AWS / "scenario.json").read_text())
        scenario.update(scenario_overrides)
        (tmp_path / "scenario.json").write_text(json.dumps(scenario))
        log = tmp_path / "calls.jsonl"
        log.unlink(missing_ok=True)
        env = {
            "PATH": f"{FAKE_AWS}:{os.environ['PATH']}",
            "FAKE_AWS_LOG": str(log),
            "FAKE_AWS_SCENARIO": str(tmp_path / "scenario.json"),
            "HOME": str(tmp_path),
        }
        proc = subprocess.run([str(ROOT / "scripts" / script), *args],
                              env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return proc, calls

    return run


def value(call, flag):
    args = call["args"]
    return args[args.index(flag) + 1]

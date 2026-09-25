"""Compare player-side candidates with the native public-rule oracle."""

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "players" / "ordinary"))
from policy import candidates, prompts  # noqa: E402


rows = subprocess.check_output([sys.argv[1]], text=True).splitlines()
for row in rows:
    sample = json.loads(row)
    found = candidates(sample["view"])
    assert found[0]["action"] == sample["sentinel"]
    assert found[1]["action"] == sample["laggard"]
    assert prompts(sample["view"], "operator says hi") == (
        sample["system"], sample["user"])
assert len(rows) == 4 * 20 * 6
print(f"player baseline parity: {len(rows)} actions per policy")

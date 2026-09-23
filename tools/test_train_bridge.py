"""Play both certified Contagion games through the numeric decision bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, manifest: Path, variant: str, teacher: bool) -> None:
    process = subprocess.Popen(
        [str(binary), str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"contagion-{variant}-{teacher}", "players": 6})
        widths = set()
        decisions = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            widths.add(len(encoding["values"]))
            assert encoding["decision_id"] == observation["decision_id"]
            heads = encoding["action_heads"]
            assert [len(head["choices"]) for head in heads] == [5, 4, 4, 4, 4]
            assert len(observation["semantic_view"]["table"]) == 6
            assert all("infected" not in region for region in observation["semantic_view"]["table"])
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
                assert all(action[head["name"]] in head["choices"] for head in heads)
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 240
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {str(seat) for seat in range(6)}
        assert len(widths) == 1
        assert decisions == (120 if variant == "standard" else 72)
        print(variant, "teacher" if teacher else "random", decisions, "decisions", widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    for variant in ("standard", "sprint"):
        for teacher in (True, False):
            play(binary, manifest, variant, teacher)

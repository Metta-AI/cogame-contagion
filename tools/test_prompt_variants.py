"""Complete published games through native text/numeric bridges and ordinary prompts."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "players" / "ordinary"))
from policy import prompt_metadata, prompts  # noqa: E402

TEXT, NUMERIC = [Path(value).resolve() for value in sys.argv[1:3]]
MANIFEST = ROOT / "coworld_manifest_template.json"
WORDINGS = [
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
]


def play(binary, variant, seed, wording="canonical", prompt_seed=0):
    with subprocess.Popen(
        [str(binary), str(MANIFEST), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ) as process:

        def request(payload):
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            line = process.stdout.readline()
            assert line, process.stderr.read()
            return json.loads(line)

        config = {"promptVariant": wording, "promptSeed": prompt_seed}
        obs = request(
            {
                "kind": "reset",
                "seed": seed,
                "players": 6,
                **config,
                "split": "test" if wording.startswith("heldout-") else "train",
            }
        )
        trace, introductions = [], set()
        while obs["kind"] == "decision":
            response = json.loads(request({"kind": "teacher"})["response"])
            if binary == TEXT:
                slot = obs["seat"]
                view = obs["semantic_view"].copy()
                metadata = view.pop("prompt_template")
                system, user = [message["content"] for message in obs["messages"]]
                expected_system, expected_user = prompts(
                    view,
                    "Protect your region's health and economy using the published case reports.",
                    config,
                )
                assert system == expected_system and user == expected_user
                # JSON writers may escape Unicode differently; compare the actual observed object.
                assert (
                    json.loads(
                        user.split("Private governor observation:\n", 1)[1].split(
                            "\nOperator guidance:", 1
                        )[0]
                    )
                    == view
                )
                expected_metadata = prompt_metadata(config, system, user)
                assert {
                    key: value.lower() if key.endswith("sha256") else value
                    for key, value in metadata.items()
                } == expected_metadata
                assert (
                    metadata["user_sha256"].lower()
                    == hashlib.sha256(user.encode()).hexdigest()
                )
                for other in range(6):
                    if other != slot:
                        assert f"PRIVATE-SEAT-{other}" not in user
                encoded = json.dumps(view)
                for forbidden in (
                    "infected",
                    "susceptible",
                    "recovered",
                    "outbreakPos",
                    "variantWeek",
                ):
                    assert json.dumps(forbidden) + ":" not in encoded
                introductions.add(system)
                response["notes"] = f"PRIVATE-SEAT-{slot}:" + "雪" * 720
                response["say"] = "hello " + "雪" * 180
            result = request(
                {
                    "kind": "step",
                    "decision_id": obs["decision_id"],
                    "response": json.dumps(response),
                }
            )
            assert result["kind"] == "accepted"
            if binary == TEXT:
                assert (
                    len(result["action"]["notes"]) == 700
                    and len(result["action"]["say"]) == 160
                )
                trace.append((view, user, result["action"]))
            obs = result["observation"]
        process.stdin.close()
        assert process.wait(timeout=30) == 0, process.stderr.read()
        return obs, trace, introductions


for variant, weeks in (("standard", 20), ("sprint", 12)):
    command = [str(TEXT), str(MANIFEST), variant]
    for invalid in ("heldout-briefing", "heldout-reference"):
        failed = subprocess.run(
            command,
            input=json.dumps(
                {
                    "kind": "reset",
                    "seed": "17",
                    "players": 6,
                    "promptVariant": invalid,
                    "split": "train",
                }
            )
            + "\n",
            text=True,
            capture_output=True,
            timeout=30,
        )
        assert failed.returncode != 0 and "evaluation-only" in failed.stderr
    for seed in ("17",):
        numeric, _, _ = play(NUMERIC, variant, seed)
        canonical = None
        introductions = set()
        for wording, prompt_seed in [(wording, 0) for wording in WORDINGS] + [
            ("mixed", 4)
        ]:
            outcome, trace, found = play(TEXT, variant, seed, wording, prompt_seed)
            assert len(trace) == weeks * 6
            assert outcome == numeric
            introductions.update(found)
            if canonical is None:
                canonical = outcome, trace
            else:
                assert (outcome, trace) == canonical
        assert len(introductions) == 42
        print(
            variant,
            seed,
            "8 complete text games, original numeric outcome and Python prompt parity PASS",
            flush=True,
        )

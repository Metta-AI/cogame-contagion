"""Convert private ordinary-player artifacts into candidate trajectory evidence."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import zipfile
from pathlib import Path

from coworld.decision_trajectory import DecisionAttempt, DecisionEvent, EpisodeEvent


def export(runs: list[Path], output: Path, revision: str, source: str) -> dict:
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    descriptor = os.open(output / "trajectories.jsonl", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    episodes = []
    identities: set[str] = set()
    with os.fdopen(descriptor, "w") as stream:
        for run in runs:
            config = json.loads((run / "config.json").read_text())
            results = json.loads((run / "results.json").read_text())
            if results["reason"] != "complete" or results["weeks"] != config["weeks"]:
                raise ValueError(f"incomplete game {run}")
            for artifact in sorted(run.glob("policy_artifact_*.zip")):
                slot = int(artifact.stem.removeprefix("policy_artifact_"))
                with zipfile.ZipFile(artifact) as archive:
                    trajectory = json.loads(archive.read("trajectory.json"))
                if (trajectory["schema_version"] != 1 or trajectory["game"] != "contagion"
                        or trajectory["slot"] != slot or trajectory["source_revision"] != revision
                        or trajectory["complete"] is not True or trajectory["scores"] != results["scores"]):
                    raise ValueError(f"invalid artifact {artifact}")
                rows = trajectory["decisions"]
                if ([row["week"] for row in rows] != list(range(config["weeks"]))
                        or any(row["source"] != source for row in rows)):
                    raise ValueError(f"candidate episode needs every decision from {source}: {artifact}")
                identity = hashlib.sha256((run / "config.json").read_bytes()).hexdigest()
                episode = f"contagion-{config['seed']}-{identity}-seat-{slot}"
                if episode in identities:
                    raise ValueError(f"duplicate episode {episode}")
                identities.add(episode)
                shared = {"episode_id": episode, "game": "contagion",
                          "game_version": f"source-{revision}", "source_revision": revision}
                for index, row in enumerate(rows):
                    # Historical version-one archives remain readable, but cannot prove
                    # engine execution and therefore cannot qualify for training.
                    if "execution_evidence" not in row:
                        raise ValueError(f"historical artifact lacks engine action evidence: {artifact}")
                    evidence = row["execution_evidence"]
                    host = json.loads((run / "host" / f"seat-{slot}-week-{row['week']}.json").read_text())
                    if evidence != host:
                        raise ValueError(f"player artifact differs from private host evidence: {artifact}")
                    metadata = row["prompt_template"]
                    if any(metadata[key] != host["prompt_selection"][key]
                           for key in ("bank", "variant", "selection", "seed")):
                        raise ValueError(f"prompt selection differs from host: {artifact}")
                    if metadata["variant"].startswith("heldout-"):
                        raise ValueError("held-out wording is evaluation-only")
                    for role, message in zip(("system", "user"), row["prompt"], strict=True):
                        if message["role"] != role or hashlib.sha256(message["content"].encode()).hexdigest() != metadata[f"{role}_sha256"].lower():
                            raise ValueError(f"prompt hash mismatch: {artifact}")
                    action = json.loads(row["completion"][0]["content"])
                    if evidence["slot"] != slot or evidence["week"] != row["week"] or action != evidence["submitted_action"]:
                        raise ValueError(f"host evidence does not identify this proposal: {artifact}")
                    accepted = evidence["accepted"] and action == evidence["executed_action"]
                    if evidence["proposal_unchanged"] != accepted:
                        raise ValueError(f"host acceptance mismatch: {artifact}")
                    if source == "canned":
                        response = row["completion"][0]["content"]
                    else:
                        # Never reconstruct a model response from parsed JSON.
                        response = row["model_response"]
                        if json.loads(response) != action:
                            raise ValueError(f"model response differs from proposal: {artifact}")
                    attempt = DecisionAttempt(
                        attempt_id=str(index), policy=source,
                        origin="teacher" if source == "canned" else "model",
                        inference_mode="text_action", prompt=row["prompt"], response=response,
                        parsed_action=action, accepted=accepted,
                        rejection_reason=None if accepted else "host-fallback-or-normalization")
                    event = DecisionEvent(
                        **shared, decision_id=str(index), decision_index=index, seat=str(slot),
                        observation={"prompt_template": metadata, "week": row["week"]},
                        prompt=row["prompt"] if accepted else None, attempts=[attempt],
                        selected_attempt_id=attempt.attempt_id if accepted else None,
                        executed_action=evidence["executed_action"],
                        action_status="accepted" if accepted else "fallback",
                        fallback_origin=None if accepted else evidence["source"],
                        terminal=index == len(rows) - 1)
                    stream.write(event.model_dump_json() + "\n")
                terminal = EpisodeEvent(
                    **shared, seed_family=f"contagion-{config['seed']}", status="completed",
                    outcome=results, participant_outcomes={str(slot): {"score": results["scores"][slot]}})
                stream.write(terminal.model_dump_json() + "\n")
                episodes.append({"episode_id": episode, "decisions": len(rows)})
    if not episodes:
        raise ValueError("no complete candidate episodes")
    manifest = {"schema_version": 1, "game": "contagion", "source_revision": revision,
                "policy": source, "episodes": episodes,
                "split_authority": "shared Coworld SDK and application importer by seed_family"}
    with os.fdopen(os.open(output / "manifest.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
        stream.write(json.dumps(manifest, indent=2) + "\n")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--source", default="canned", choices=("canned", "trained"))
    args = parser.parse_args()
    directories = [episode for run in args.runs for episode in
                   (sorted(run.glob("episode-*")) if not (run / "results.json").exists() else [run])]
    print(export(directories, args.output, args.source_revision, args.source))

"""Full published episodes through real host and native/ordinary player processes."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
import zipfile
from pathlib import Path


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    wordings = ["canonical", "plain", "numbered", "questions", "reordered",
                "heldout-briefing", "heldout-reference", "mixed"]
    if args.smoke:
        wordings = ["canonical"]
    for variant in manifest["variants"]:
        for wording in wordings:
            work = args.output / f'{variant["id"]}-{wording}'
            work.mkdir(mode=0o700)
            config = dict(variant["game_config"])
            config.update(seed=7, promptVariant=wording, promptSeed=4,
                          players=[{"name": f"P{seat}"} for seat in range(6)],
                          tokens=[f"t{seat}" for seat in range(6)])
            weeks = config["weeks"]
            (work / "config.json").write_text(json.dumps(config))
            port, closed_port = free_port(), free_port()
            env = os.environ.copy()
            for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_URI", "COWORLD_LLM_ENDPOINT",
                        "AWS_BEARER_TOKEN_BEDROCK", "PLAYER_SCRIPTED", "POC_ADAPTER_DIR"):
                env.pop(key, None)
            env.update(COGAME_HOST="127.0.0.1", COGAME_PORT=str(port),
                       COGAME_CONFIG_URI=(work / "config.json").as_uri(),
                       COGAME_RESULTS_URI=(work / "results.json").as_uri(),
                       COGAME_SAVE_REPLAY_URI=(work / "replay.json").as_uri(),
                       CONTAGION_HOST_TRACE_DIR=str(work / "host"))
            processes, logs = [], []
            try:
                log = (work / "game.log").open("w")
                logs.append(log)
                game = subprocess.Popen([str(args.game)], cwd=root, env=env,
                                        stdout=log, stderr=subprocess.STDOUT)
                processes.append(game)
                for _ in range(200):
                    assert game.poll() is None, work
                    with socket.socket() as probe:
                        ready = probe.connect_ex(("127.0.0.1", port)) == 0
                    if ready:
                        break
                    time.sleep(0.05)
                else:
                    raise RuntimeError(f"host did not start: {work}")
                for seat in range(6):
                    player_env = env.copy()
                    player_env["COWORLD_PLAYER_WS_URL"] = (
                        f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}")
                    if seat % 2 == 0:
                        argv = [sys.executable, str(root / "players/ordinary/player.py")]
                        player_env.update(POC_CAPTURE_TRAINING="1",
                                          POC_SOURCE_REVISION="uncommitted-contagion-validation",
                                          COWORLD_PLAYER_ARTIFACT_UPLOAD_URL=(
                                              work / f"policy_artifact_{seat}.zip").as_uri())
                    else:
                        argv = [str(args.player)]
                        if seat == 5:
                            player_env.update(COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed_port}",
                                              CONTAGION_PLAYER_TRACE_DIR=str(work / "attempts"))
                        else:
                            player_env["PLAYER_SCRIPTED"] = "sentinel" if seat == 1 else "laggard"
                    log = (work / f"player-{seat}.log").open("w")
                    logs.append(log)
                    processes.append(subprocess.Popen(argv, cwd=root, env=player_env,
                                                       stdout=log, stderr=subprocess.STDOUT))
                assert game.wait(timeout=manifest["episode_timeout_minutes"] * 60 + 30) == 0
                for seat, player in enumerate(processes[1:]):
                    code = player.wait(timeout=15)
                    assert (code != 0 if seat == 5 else code == 0), (work, seat, code)
                results = json.loads((work / "results.json").read_text())
                assert results["reason"] == "complete" and results["weeks"] == weeks
                host = [json.loads(path.read_text()) for path in (work / "host").glob("*.json")]
                assert len(host) == weeks * 6
                assert sum(row["source"] == "host-sentinel" for row in host) == weeks
                assert all(row["submitted_action"] is None for row in host if row["slot"] == 5)
                attempts = list((work / "attempts").glob("*-finish.json"))
                assert len(attempts) == 1
                attempt = json.loads(attempts[0].read_text())
                assert attempt["failure"] and attempt["transport_error"]
                assert attempt["parsed_action"] is None and attempt["platform_call_id"] is None
                for role, message in zip(("system", "user"), attempt["prompt"], strict=True):
                    assert hashlib.sha256(message["content"].encode()).hexdigest() == (
                        attempt["prompt_template"][f"{role}_sha256"])
                for seat in (0, 2, 4):
                    with zipfile.ZipFile(work / f"policy_artifact_{seat}.zip") as archive:
                        trajectory = json.loads(archive.read("trajectory.json"))
                    assert trajectory["complete"] and trajectory["scores"] == results["scores"]
                    assert len(trajectory["decisions"]) == weeks
                    for row in trajectory["decisions"]:
                        evidence = row["execution_evidence"]
                        assert evidence in host and evidence["slot"] == seat
                        assert json.loads(row["completion"][0]["content"]) == evidence["submitted_action"]
                        for role, message in zip(("system", "user"), row["prompt"], strict=True):
                            assert hashlib.sha256(message["content"].encode()).hexdigest() == (
                                row["prompt_template"][f"{role}_sha256"])
                print(f'{work.name}: {weeks} weeks, {weeks * 6} host decisions, '
                      'one actual failed call, three ordinary artifacts PASS', flush=True)
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
                for log in logs:
                    log.close()


if __name__ == "__main__":
    main()

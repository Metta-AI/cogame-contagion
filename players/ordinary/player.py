"""Contagion decisions through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import os
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture
from policy import candidates, prompts


def choose(turn: dict, generator) -> tuple[dict, str]:
    candidates = turn["candidates"]
    if generator:
        completion = generator([
            {"role": "system", "content": turn["system"]},
            {"role": "user", "content": turn["user"]},
        ])
        action = json.loads(completion)
        if not isinstance(action, dict):
            raise ValueError("trained Contagion decision must be a JSON object")
        return action, "trained"
    return candidates[0]["action"], "canned"


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("POC_ADAPTER_DIR")
    generator = None
    if adapter:
        from pathlib import Path

        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    backend = "trained" if adapter else "canned"
    artifact = Capture(slot, backend) if os.environ.get("POC_CAPTURE_TRAINING") == "1" else None
    socket = websocket.create_connection(url, timeout=60)
    socket.settimeout(None)
    pending: dict[int, tuple[dict, dict, str]] = {}
    while True:
        opcode, data = socket.recv_data(control_frame=True)
        if opcode == websocket.ABNF.OPCODE_CLOSE:
            raise RuntimeError("Contagion closed before the final frame")
        if opcode != websocket.ABNF.OPCODE_TEXT:
            continue
        frame = json.loads(data)
        kind = frame["type"]
        if kind == "turn":
            system, user = prompts(frame["view"], os.environ.get("PLAYER_PROMPT", ""))
            turn = {"system": system, "user": user,
                    "candidates": candidates(frame["view"]), "slot": slot}
            action, source = choose(turn, generator)
            pending[frame["week"]] = (turn, action, source)
            socket.send(json.dumps({"type": "decision", "week": frame["week"],
                                    "action": action, "source": source}))
        elif kind == "decision_result":
            turn, action, source = pending.pop(frame["week"])
            if artifact and frame["accepted"]:
                artifact.record(turn["system"], turn["user"], action, source,
                                frame["week"])
        elif kind == "final":
            if pending:
                raise RuntimeError("Contagion ended with unacknowledged decisions")
            if artifact:
                artifact.upload(frame["scores"])
            break
    socket.close()
    print(f"Contagion ordinary player finished: slot={slot} backend={backend}",
          flush=True)


if __name__ == "__main__":
    main()

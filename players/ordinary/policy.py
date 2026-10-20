"""Contagion prompts and complete candidate actions from a private view."""

import hashlib
import json
from pathlib import Path

PROMPT_BANK = json.loads(Path(__file__).with_name("prompt_bank.json").read_text())

LOCKDOWN_CUTS = (1000, 4000, 12500, 30000)
TESTING_CUTS = (1000, 12500)
ROAD_CUTS = (160, 800)
DETECTION = (150000, 350000, 650000, 900000)
POP = 1000000


def _rate(region: dict) -> int:
    living = POP - region["deaths"]
    return 0 if living <= 0 else (
        region["confirmed"] * POP // DETECTION[region["testing"]] * POP // living
    )


def _action(lockdown: int, testing: int, borders: dict) -> dict:
    return {"lockdown": lockdown, "testing": testing, "borders": borders,
            "aid": [], "say": "", "notes": ""}


def sentinel(view: dict) -> dict:
    scale = 800000 if view["variant"] else POP
    own_rate = _rate(view["own"])
    lockdown = sum(own_rate >= cut * scale // POP for cut in LOCKDOWN_CUTS)
    testing = 1 + sum(own_rate >= cut * scale // POP for cut in TESTING_CUTS)
    others = {region["region"]: region for region in view["others"]}
    borders = {}
    for gate in view["own"]["gates"]:
        name = gate["to"]
        rate = _rate(others[name])
        borders[name] = sum(rate >= cut * scale // POP for cut in ROAD_CUTS)
    return _action(lockdown, testing, borders)


def laggard(view: dict) -> dict:
    trigger = next((row["week"] for row in view["history"]
                    if _rate(row) >= 40000), -1)
    lockdown = 3 if trigger <= view["week"] < trigger + 3 and trigger >= 0 else 0
    return _action(lockdown, 0, {gate["to"]: 0 for gate in view["own"]["gates"]})


def candidates(view: dict) -> list[dict]:
    return [{"id": "sentinel", "action": sentinel(view)},
            {"id": "laggard", "action": laggard(view)}]


def selected_variant(selection: dict) -> str:
    variant = selection["promptVariant"]
    seed = selection["promptSeed"]
    if type(seed) is not int or seed < 0:
        raise ValueError("promptSeed must be a nonnegative integer")
    if variant == "mixed":
        variant = PROMPT_BANK["training"][seed % len(PROMPT_BANK["training"])]
    if variant not in PROMPT_BANK["introductions"]:
        raise ValueError("unknown prompt variant")
    return variant


def prompt_metadata(selection: dict, system: str, user: str) -> dict:
    return {"bank": PROMPT_BANK["bank"], "variant": selected_variant(selection),
            "selection": selection["promptVariant"], "seed": selection["promptSeed"],
            "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
            "user_sha256": hashlib.sha256(user.encode()).hexdigest()}


def prompts(view: dict, guidance: str, selection: dict) -> tuple[str, str]:
    variant = selected_variant(selection)
    system = (PROMPT_BANK["introductions"][variant] + PROMPT_BANK["rules"][variant]).format(region=view["region"])
    user = (
        "Private governor observation:\n"
        + json.dumps(view, ensure_ascii=False, separators=(",", ":"))
        + "\nOperator guidance:\n"
        + guidance
        + '\nReply with only {"lockdown": 0, "testing": 2, '
        '"borders": {"neighbour": 0}, "aid": [], "say": "", "notes": ""}. '
        "Only name your three roads."
    )
    return system, user

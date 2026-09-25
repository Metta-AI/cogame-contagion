"""Contagion prompts and complete candidate actions from a private view."""

import json

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


def prompts(view: dict, guidance: str) -> tuple[str, str]:
    system = (
        f"You are the governor of {view['region']} in Contagion. Six governors "
        "set lockdown 0..4, testing 0..3, and three road gates 0..2 "
        "simultaneously each week. You may send up to 200 credits of aid "
        "and a short public message. True infection counts are hidden; "
        "reported cases reflect each region's published testing. Maximize "
        "your own ledger minus twice your deaths. Reply with one JSON "
        "action and no other text."
    )
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

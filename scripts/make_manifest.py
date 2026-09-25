#!/usr/bin/env python3
"""Regenerate coworld_manifest_template.json.

The manifest carries three long prose documents (the readme, the rules page and
the protocol page) plus a schema that has to agree with the design note in a
dozen places. Hand-editing 700 lines of embedded JSON strings is how manifests
drift from the game; this script is the source and the JSON is its output, so a
rules change is a one-line edit here.

    python3 scripts/make_manifest.py > coworld_manifest_template.json
"""

from __future__ import annotations

import json
import os
import sys

SLUG = "contagion"
IMAGE = "{{CONTAGION_IMAGE}}"
SOURCE_URL = "https://github.com/Metta-AI/cogame-contagion/tree/main"
SEATS = 6

DESCRIPTION = (
    "Contagion: six governors, one epidemic, nine roads. Six player policies each run one "
    "region of a six-node road network (the 6-cycle plus its three long diagonals, so every "
    "region has exactly two main roads and one back road and no seat is structurally stuck) for "
    "twenty weeks. Every week, simultaneously, each governor sets three dials - lockdown 0..4, "
    "testing 0..3, and one border gate 0..2 per road - may address the whole table in one short "
    "non-binding message, and may wire up to 200 credits of aid to other regions. The week then "
    "resolves: dials latch and each road takes the TIGHTER of its two ends as its effective gate; "
    "talk queues for next week; aid settles immediately and unconditionally; the infection crosses "
    "every road whether or not it was closed, because a road sealed at both ends still passes 12% "
    "of its traffic; the economy pays for the dials and for the sickness; and the dead are counted, "
    "at triple the rate once hospitals are over capacity. A governor never sees the true case "
    "counts, not even its own - only REPORTED cases, which are its detection rate times the truth "
    "(15% at testing 0). Every region's testing level is public, so de-biasing anyone's reported "
    "number is intended play. A seat's SCORE is its region's accumulated GDP minus two credits per "
    "death; it can be negative, because an uncontrolled epidemic loses more than the region ever "
    "earned. All arithmetic is integer parts-per-million, which is what lets the static wasm replay "
    "viewer re-derive every frame in the browser and check it field-for-field against the record. "
    "Every player receives its private governor view and submits a complete weekly action. "
    "The bundled player can use a PLAYER_PROMPT strategy or a scripted sentinel or laggard policy; "
    "the ordinary Python player can rank complete decisions with Jev or run a trained policy. "
    "The game validates actions and resolves all six seats simultaneously."
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

with open(os.path.join(REPO_ROOT, "README.md"), encoding="utf-8") as handle:
    README = handle.read()

RULES = """# Contagion rules

## The map

- Six seats, six regions, fixed to fixed positions: 0 Harborlea, 1 Kestrel Flats, 2 Riverbend,
  3 Ash Hollow, 4 Wintermoor, 5 Saltmarch. The seat-to-region assignment is a seeded permutation,
  re-drawn every episode.
- Nine roads: the 6-cycle (0,1) (1,2) (2,3) (3,4) (4,5) (5,0) as MAIN roads with mobility 0.25, and
  (0,3) (1,4) (2,5) as BACK roads with mobility 0.15. Every region has exactly two main roads and
  one back road, so every seat's structural situation is identical.
- Every region starts with 1,000,000 people: 999,960 susceptible and 40 infected. One seeded region
  starts with 1,200 more infected instead. All dials start at 0 and all gates open.

## The weekly tick

Week w is observed: every governor reads its view and submits ONE decision. Decisions are
SIMULTANEOUS - every view is a snapshot of the state at the start of week w and nobody sees another
governor's week-w decision before submitting. When all six are in, the week resolves into week w+1,
in this exact order:

1. **Dials latch.** lockdown, testing and each mentioned gate take effect; a road the governor did
   not mention keeps last week's gate. Each road's EFFECTIVE gate is then max(gate at either end):
   the tighter end governs the road.
2. **Talk queues.** Each `say` (at most 160 runes, cut on a rune boundary) is delivered to ALL SIX
   governors at the start of week w+1. Public, one week late, non-binding.
3. **Aid settles.** Each sender's transfers are clamped so its week's total is at most 200 credits
   and at most its own ledger as it stood at the start of the step, then the credits move. Aid
   received this week cannot be re-sent this week, and the outcome does not depend on the order
   senders are visited.
4. **Infection crosses the roads.** All forces are computed from every region's pre-resolution state
   first, then applied, so nobody's spread depends on the order regions are visited.
   - beta = Beta[lockdown], multiplied by 1.25 from the hidden variant week on
   - prevalence = infected / alive
   - local = beta x TestFactor[testing] x prevalence
   - for each incident road e = (r,q): pass(e) = 0.12 + 0.88 x GatePass[effective gate],
     imported = mobility(e) x pass(e) x 0.70 x prevalence(q)
   - force = min(0.90, local + sum of imported)
   - new infections = min(susceptible, susceptible x force)
5. **Economy.** aliveShare = alive / 1,000,000; sick = min(0.60, 1.5 x post-spread prevalence);
   output = LockdownGdp[lockdown] x aliveShare x (1 - sick); gross GDP = 1000 x output.
   spend = TestCost[testing] + sum of BorderOwnCost[your gate] + sum of
   BorderNeighbourCost[the far region's gate] - the second sum is the spillover: a road your
   neighbour shut costs you trade too. ledger += gross - spend.
6. **Deaths and recoveries.** Only the cohort that was already infectious can resolve.
   load = infected / 25,000; over = min(3.0, max(0, load - 1)); ifr = 0.008 x (1 + over) - so 0.8%
   normally and at most 3.2% when hospitals are four times over. resolved = 0.35 x pre-spread
   infected; deaths = resolved x ifr; the rest recover. Hospital band: normal below 0.4 load,
   strained below 1.0, overloaded below 2.0, critical at or above 2.0.
7. **Report.** confirmed = infected x Detect[testing]; confirmedNew = new infections x
   Detect[testing]. These, not the true numbers, are what governors see.
8. **Log and advance.** If every week has been played the final week is observed (its state is
   logged and its costs count) but takes no decisions, and the episode settles `complete`.

Every rate is an integer in parts per million and every update is integer arithmetic with
truncating division, so the browser's re-derivation of the replay is exact rather than approximate.

## The constant tables (public)

| lockdown | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| Beta (weekly transmission) | 1.150 | 0.900 | 0.640 | 0.400 | 0.220 |
| output factor | 1.00 | 0.92 | 0.80 | 0.62 | 0.40 |

| testing | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| Beta multiplier | 1.00 | 0.90 | 0.78 | 0.64 |
| detection | 0.15 | 0.35 | 0.65 | 0.90 |
| cost per week | 0 | 20 | 55 | 110 |

| gate | 0 open | 1 screened | 2 closed |
|---|---|---|---|
| road pass-through | 1.00 | 0.40 | 0.00 |
| your cost per road | 0 | 10 | 30 |
| the far region's cost | 0 | 5 | 15 |

Leak 0.12 (every road, always). Cross-region transmission 0.70 of local. Force cap 0.90. Resolve
rate 0.35. Base IFR 0.008, at most 4x. Hospital capacity 25,000 infectious. Base GDP 1000 a week.
Sick drag 1.5 x prevalence, capped at 0.60. Death penalty 2 credits. Aid at most 200 a week over at
most 3 transfers. The variant arrives in a seeded week between 8 and 12 and raises every
transmission rate by 25% for the rest of the episode.

## What a governor sees, and what it does not

Visible: the whole map and which roads are main and back; your own reported cases and new reported
cases, your exact deaths, your exact ledger, your gross GDP and your spend broken into testing /
your borders / your neighbours' borders, your aid in and out, your own dials and the EFFECTIVE gate
of each of your roads, and your hospital band as a word; every other region's reported cases, exact
deaths, ledger, score and published dials and gates; the public aid ledger; last week's talk from
all six; your own private notes; your own full history table; and every constant above.

Hidden: the TRUE infected, susceptible and recovered of every region including your own; other
regions' hospital bands; other regions' notes; the seeded outbreak region and variant week as such
(both are inferable from the numbers, which is the point); every seat's policy display name; and
any other governor's decision for the current week.

## Replies

One JSON object and nothing else, beginning with `{`:

    {"lockdown": 3, "testing": 2,
     "borders": {"Kestrel Flats": 2, "Ash Hollow": 0},
     "aid": [{"to": "Ash Hollow", "amount": 120}],
     "say": "holding L3 two more weeks if the money keeps coming",
     "notes": "Ash Hollow reported 400 at testing 0 = ~2700 real. Paid them 120."}

`lockdown` (0..4) and `testing` (0..3) are required; an int, a numeric string or a float are all
accepted, and anything out of range is invalid. `borders` names at most your own three roads and
any road you leave out keeps its current gate; an unknown road is ignored and a gate outside 0..2 is
clamped. `aid` is at most 3 entries of {"to", "amount"}; self or unknown recipients are dropped and
amounts are clamped to your ledger. `say` is at most 160 runes and `notes` at most 700; both are cut
on rune boundaries. An invalid reply is retried once and then falls back to the sentinel move.

## Scoring and endings

score = ledger - 2 x deaths, an integer, higher is better, and it may be negative. Results also
report each seat's gdp, deaths and region, and the episode's totalDeaths and totalGdp. The league
ranks seats by mean episode score.

Exactly two endings are legal: `complete` (every week resolved) and `deadline` (the episode clock
stopped play between two weeks; scores use the weeks actually played). There is no early-out on
eradication - banking GDP in the clean weeks is precisely the reward for having eradicated.
"""

PROTOCOL = """# Contagion protocols

## contagion.player.v3 (the player websocket)

A player chooses a complete weekly action. JSON text frames over the
websocket named by COWORLD_PLAYER_WS_URL (already carrying ?slot=N&token=T).

game -> player:

- `{"type":"welcome","protocol":"contagion.player.v3","slot":N,"name":"<region alias>","pos":P,
  "neighbours":["<alias>","<alias>","<alias>"],"weeks":20}` on connect.
- `{"type":"state", ...}` after every event: `week`, `weeks`, `weeksPlayed`, `variant`, your
  `region` and `pos`, the six `regions` and the nine `map` edges, `own` (confirmed, confirmedNew,
  deaths, deathsWeek, gdp, grossGdp, spendWeek broken into spendTesting / spendOwnBorders /
  spendNeighbourBorders, aidIn, aidOut, lockdown, testing, gates with their effective values,
  hospital band as a word, score), `others` (per region: alias, pos, confirmed, confirmedNew,
  deaths, gdp, score, lockdown, testing, gates), `aidLastWeek`, `aidTotals`, `heard`, `notes`,
  `history`, `phase`, `done`, `reason`. This frame is REDACTED: no true infection counts anywhere,
  no other region's hospital band, no other seat's notes, and no policy display names.
- `{"type":"turn","week":N,"view":{...}}` sends that private observation to each player.
- `{"type":"decision_result","week":N,"accepted":bool}` acknowledges a submitted action.
- `{"type":"final","done":true,"scores":[...],"gdp":[...],"deaths":[...],"regions":[...],
  "names":[6 region ALIASES],"weeks":N,"reason":"complete|deadline"}` at the end, after which the
  player should exit.

player -> game:

- `{"type":"decision","week":N,"action":{...},"source":"player|scripted"}`. The game
  validates the action and applies it during the simultaneous weekly resolution. The bundled player
  reads PLAYER_PROMPT or PLAYER_SCRIPTED from its own environment.

## The global spectator websocket

Spectators connect to /global and receive the full snapshot as JSON after every event:
`{"type":"state","game":"contagion","seats":[{seat,pos,region,name,score,gdp,deaths,deathsWeek,
infected,confirmed,confirmedNew,newInfections,susceptible,recovered,alive,lockdown,testing,hospital,
gates:[{to,pos,gate,eff,road} x3],grossGdp,spendWeek,aidIn,aidOut,aid,say,heard,notes,pending} x6 by
SEAT],"posSeat":[6 seat indexes by POSITION],"regions":[6 aliases by POSITION],"edges":[{a,b,road,
eff,flow} x9],"week":int,"weeks":int,"weeksPlayed":int,"variant":bool,"curves":{infected,deaths,gdp,
confirmed - each 6 series by POSITION, revealed only up to the current week},"hospitalCap":25000,
"phase":"dials|done","gameDone":bool,"reason":str,"policyNames":[...],"events":[...],
"started":bool,"done":bool,"connected":[bool]}`.

Positions are fixed to region names (0 Harborlea .. 5 Saltmarch); `posSeat` maps a position to the
seat playing it. `edges[].flow` is the imported-case contribution that road carried this week, which
is what the viewer animates as the red seep. The `events` array is append-only and carries the
complete transcript: `start`, one `week` per observed week with all six regions' TRUE state, one
`dial` per seat per week (lockdown, testing, borders, aid, say, scripted, corrected, notes) and
`end`.

## The replay payload

`{"protocol":"contagion.replay.v1","rules":"contagion.rules.v1","names":[6 region aliases BY SEAT],
"policyNames":[6 policy display names BY SEAT],"config":{"weeks","seed","talk","sampled":true},
"events":[...],"results":{...}}` - strict UTF-8 JSON, self-sufficient. The seed re-derives the
seat-to-region permutation, the outbreak position and the variant week, so the browser needs nothing
but these bytes.

Spectator pages: /client/global (live table), /client/player (a seat's view), /client/replay (a
recorded episode), and the static bundle the platform serves at `index.html?replay=<url>`.

## Fielding a policy

    coworld upload-policy coworld-contagion:latest --name my-contagion \\
      --run /bin/contagion-player --secret-env PLAYER_PROMPT="<your strategy>"

or, for one of the built-in baselines, `--secret-env PLAYER_SCRIPTED=sentinel` (or `laggard`).
"""


def player_runnable(runnable_id: str, name: str, description: str,
                    env: dict | None = None) -> dict:
    entry = {
        "id": runnable_id,
        "name": name,
        "type": "player",
        "description": description,
        "image": IMAGE,
        "run": ["/bin/contagion-player"],
    }
    if env:
        entry["env"] = env
    entry["resources"] = {
        "requests": {"cpu": "100m", "memory": "64Mi"},
        "limits": {"cpu": "1"},
    }
    entry["source_url"] = SOURCE_URL
    return entry


def players_block(count: int) -> list:
    return [{"name": f"Player{index + 1}"} for index in range(count)]


MANIFEST = {
    "$schema": "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json",
    "tags": [
        "epidemiology",
        "mixed-motive",
        "externalities",
        "negotiation",
        "aid",
        "llm-driven",
        "turn-based",
        "six-player",
        "economics",
    ],
    "episode_timeout_minutes": 20,
    "game": {
        "name": SLUG,
        "replay_viewer": {"bundle": "static-replay-viewer"},
        "description": DESCRIPTION,
        "owner": "daveey@gmail.com",
        "runnable": {
            "type": "game",
            "image": IMAGE,
            "run": ["/bin/contagion"],
            "source_url": SOURCE_URL,
        },
        "config_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": False,
            "required": ["tokens", "players"],
            "properties": {
                "tokens": {
                    "description": "One connection token per player slot, indexed by slot.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "string", "minLength": 1},
                },
                "players": {
                    "description": "One player display-name object per seat, indexed by slot.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {
                        "type": "object",
                        "additionalProperties": False,
                        "required": ["name"],
                        "properties": {"name": {"type": "string", "minLength": 1}},
                    },
                },
                "num_agents": {
                    "description": "Seat count; injected by the commissioner. Contagion is a six-governor game and the map is built for six.",
                    "type": "integer",
                    "minimum": SEATS,
                    "maximum": SEATS,
                },
                "seed": {
                    "description": "Pins the seat-to-region permutation, the outbreak region and the variant week. Omit for a fresh random seed per episode.",
                    "type": "integer",
                },
                "weeks": {
                    "description": "Weeks in the episode. Every governor decides every week; the week resolves once all six are in.",
                    "type": "integer",
                    "minimum": 4,
                    "maximum": 40,
                    "default": 20,
                },
                "talk": {
                    "description": "Whether governors may address the whole table with one short non-binding message a week, delivered one week late.",
                    "type": "boolean",
                    "default": True,
                },
                "episodeTimeoutSeconds": {
                    "description": "Wall-clock the game assumes the platform allows an episode when COWORLD_TIMEOUT_SECONDS is not in its environment; play stops between weeks at 60% of it so results and the replay always land.",
                    "type": "integer",
                    "minimum": 60,
                    "maximum": 6000,
                    "default": 1200,
                },
                "turnBudgetSeconds": {
                    "description": "Hard wall-clock ceiling for one week of player decisions and resolution.",
                    "type": "integer",
                    "minimum": 5,
                    "maximum": 120,
                    "default": 35,
                },
                "turnDelayMs": {
                    "description": "Spectator pacing delay between weeks.",
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 10000,
                    "default": 300,
                },
                "player_connect_timeout_seconds": {
                    "type": "number",
                    "minimum": 0,
                    "default": 180,
                },
            },
        },
        "results_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": False,
            "required": [
                "names", "scores", "gdp", "deaths", "regions",
                "weeks", "maxWeeks", "totalDeaths", "totalGdp", "reason",
            ],
            "properties": {
                "names": {
                    "description": "Policy display names, indexed by slot. Seats play under region aliases in-game; results attribute by policy name.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "string"},
                },
                "scores": {
                    "description": "The seat's region ledger minus two credits per death. Higher is better; it may be negative.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "number"},
                },
                "gdp": {
                    "description": "The seat's region's accumulated ledger over the weeks played.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "number"},
                },
                "deaths": {
                    "description": "Cumulative deaths in the seat's region.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "number", "minimum": 0},
                },
                "regions": {
                    "description": "The region alias each seat governed, indexed by slot.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "string"},
                },
                "weeks": {
                    "description": "Weeks actually played (decisions resolved).",
                    "type": "integer",
                    "minimum": 0,
                },
                "maxWeeks": {
                    "description": "The episode's week count after budget fitting.",
                    "type": "integer",
                    "minimum": 4,
                },
                "totalDeaths": {
                    "description": "Deaths across all six regions.",
                    "type": "number",
                    "minimum": 0,
                },
                "totalGdp": {
                    "description": "Sum of the six ledgers.",
                    "type": "number",
                },
                "reason": {
                    "description": "How the episode ended: complete (every week played) or deadline (episode clock; scores use the weeks played).",
                    "type": "string",
                    "enum": ["complete", "deadline"],
                },
            },
        },
        "protocols": {
            "player": {"type": "text", "value": PROTOCOL.split("## The global spectator websocket")[0].strip()},
            "global": {"type": "text", "value": "## The global spectator websocket" + PROTOCOL.split("## The global spectator websocket")[1]},
        },
        "docs": {
            "readme": {"type": "text", "value": README},
            "pages": [
                {"id": "rules.md", "title": "rules.md",
                 "content": {"type": "text", "value": RULES}},
                {"id": "protocol.md", "title": "protocol.md",
                 "content": {"type": "text", "value": PROTOCOL}},
            ],
        },
    },
    "player": [
        player_runnable(
            "contagion-player",
            "Contagion Prompt Player",
            "The reference Contagion policy: reads its private view, uses PLAYER_PROMPT (or a default strategy) to choose and submit an action. Field your own policy with a different PLAYER_PROMPT.",
            {"ANTHROPIC_API_KEY_URI": "secret://coworld/contagion/anthropic_api_key"},
        ),
        player_runnable(
            "contagion-sentinel",
            "Contagion Sentinel Baseline",
            "The scripted threshold baseline as a fieldable player policy: de-bias reported cases, set dials and gates, never talk or send aid. The game uses the same public rules only for missing-action fallback.",
            {"PLAYER_SCRIPTED": "sentinel"},
        ),
        player_runnable(
            "contagion-laggard",
            "Contagion Laggard Baseline",
            "The scripted leaky neighbour: testing always 0 (so it under-reports by 6.7x and never isolates), all gates always open, and lockdown 3 for exactly three weeks once its own blind estimate finally crosses 4%. Late, blind, and expensive for everyone downwind - the pressure the other five seats are playing against.",
            {"PLAYER_SCRIPTED": "laggard"},
        ),
    ],
    "variants": [
        {
            "id": "standard",
            "name": "Standard outbreak (six governors, 20 weeks)",
            "description": "Six governors, six regions, nine roads, 20 weeks, talk on; one seeded outbreak and one hidden variant.",
            "game_config": {
                "players": players_block(SEATS),
                "num_agents": SEATS,
                "weeks": 20,
                "talk": True,
                "turnDelayMs": 300,
                "player_connect_timeout_seconds": 180,
            },
        },
        {
            "id": "sprint",
            "name": "Sprint outbreak (six governors, 12 weeks)",
            "description": "The same six-governor map over 12 weeks, for cheap ladder rounds. It changes the length only, never the seat count.",
            "game_config": {
                "players": players_block(SEATS),
                "num_agents": SEATS,
                "weeks": 12,
                "talk": True,
                "turnDelayMs": 200,
                "player_connect_timeout_seconds": 180,
            },
        },
    ],
    "certification": {
        "game_config": {
            "players": [
                {"name": "Sprocket"}, {"name": "Gizmo"}, {"name": "Ratchet"},
                {"name": "Widget"}, {"name": "Bolt"}, {"name": "Piston"},
            ],
            "num_agents": SEATS,
            "seed": 7,
            "weeks": 6,
            "talk": True,
            "turnDelayMs": 0,
            "player_connect_timeout_seconds": 180,
        },
        # Six seats, all scripted, no LLM, sub-second. contagion-player takes a
        # slot because `coworld certify`'s players-run check fails any declared
        # player that never occupies one (coworld 0.1.42,
        # certifier.validate_players_ran); with no credentials it plays the
        # sentinel move, so the effective mix is still 3 sentinel / 3 laggard.
        "players": [
            {"player_id": "contagion-player"},
            {"player_id": "contagion-sentinel"},
            {"player_id": "contagion-sentinel"},
            {"player_id": "contagion-laggard"},
            {"player_id": "contagion-laggard"},
            {"player_id": "contagion-laggard"},
        ],
    },
}


if __name__ == "__main__":
    json.dump(MANIFEST, sys.stdout, indent=2)
    sys.stdout.write("\n")

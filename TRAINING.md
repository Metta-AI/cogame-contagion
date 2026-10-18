# Contagion training

Contagion has a local simulator and hosted text players. Export complete games
for Metta post-training with the same per-seat prompts and reply parser as the
hosted player:

```bash
nimby sync nimby.lock
nim r --path:src tools/export_posttrain.nim /tmp/contagion-standard 10 1 standard
nim r --path:src tools/export_posttrain.nim /tmp/contagion-sprint 10 1 sprint
```

The exporter requires a clean committed checkout, reads each published
`game_config`, and completes every configured week. It writes private
`trajectories.jsonl` candidate evidence and `manifest.json`, retaining one episode
in memory at a time. Output paths must not already exist.

Sentinel and laggard teachers alternate by seat. Prompts and private observations
are frozen before the weekly batch. Each record retains the original proposal
and the engine's executed action. A normalized proposal is retained but cannot
be selected as an accepted training response. Model call identifiers and token
probabilities remain unknown for these scripted teachers.

Optional `PROMPT_VARIANT PROMPT_SEED` arguments follow `VARIANT`. Held-out
wordings are evaluation-only and rejected by this exporter. Seed families exclude
game variant and wording, keeping matched scenarios together during splitting.

Convert candidate evidence through the shared Coworld trajectory importer and
complete its independent review gate before training. Scripted imitation loss
does not measure learned policy quality or prompt robustness.

The [ordinary player](players/ordinary/README.md) can collect proposals and host execution evidence from real local
episodes through the standard Coworld policy artifact URL. Its candidate exporter keeps matched game seeds
together for shared split assignment. The same player can load the resulting adapter and submit its
decisions through `contagion.player.v3`. Jev selects complete weekly actions through that socket.

## Numeric reinforcement learning

Compile the persistent bridge and pass its binary, manifest, and variant to
Metta's `recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```bash
nim c -d:release --path:src -o:/tmp/contagion-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/contagion-train-bridge
```

Both certified variants expose 99 numeric observations and five action heads:
lockdown (5), testing (4), and three per-road gates (4 each, including keep).
The observation contains the same published case reports and dials shown to a
governor, plus that governor's history. It excludes the simulator's hidden
true infection counts. The sentinel and laggard scripts supply teacher dials.
The numeric policy omits aid and free-form talk or notes; the text exporter
retains the full hosted reply interface.

## Prompt wording and text decisions

Hosted configurations accept `promptVariant` and `promptSeed`. Training wordings
are `canonical`, `plain`, `numbered`, `questions`, and `reordered`. `mixed`
requires an explicit nonnegative seed and selects training wording by `seed % 5`.
`heldout-briefing` and `heldout-reference` are reserved for evaluation. Selection
is separate from simulation randomness and stays fixed throughout the episode.

The host sends the selection alongside each private turn. Both bundled Nim and
ordinary Python players read introductions from
`players/ordinary/prompt_bank.json`; common rules and operator guidance stay
fixed. Ordinary player images include that bank. The default remains canonical.

`tools/text_bridge.nim` exposes full production actions, including aid, talk, and
private notes. Run its compiled binary with the manifest and `standard` or
`sprint`. Reset accepts the same selector fields and rejects held-out wording in
training. Six parsed actions are queued against the frozen week, then the real
simulator settles them together. Accepted actions describe normalized orders,
not a guarantee of economic or health outcomes. Private semantic views include
bank identity, wording, seed, and exact system/user hashes.

The numeric bridge retains its 99 values and five action heads. Compare full text
games and numeric outcomes with `python tools/test_prompt_variants.py TEXT_BRIDGE
ORIGINAL_NUMERIC_BRIDGE`. Keep every variant and wording of one scenario seed in
the same data split. Matched model experiments must hold scenario seeds, seat
assignments, other policies, and inference budgets fixed. Report corrected
orders, failures, fallbacks, incomplete episodes, ledger totals, deaths, and
scores separately. Scripted outcomes do not measure learned policy robustness.

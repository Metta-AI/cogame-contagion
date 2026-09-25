# Contagion training

Contagion has a local simulator and hosted text players. Export complete games
for Metta post-training with the same per-seat prompts and reply parser as the
hosted player:

```bash
nimby sync nimby.lock
nim r --path:src tools/export_posttrain.nim /tmp/contagion-standard 10 1 standard
nim r --path:src tools/export_posttrain.nim /tmp/contagion-sprint 10 1 sprint
```

The exporter reads each certified `game_config` from
`coworld_manifest_template.json`, runs ten seeded games per variant, and writes
`train.jsonl`, `validation.jsonl`, and `manifest.json`. Seeds divisible by five
go to validation, keeping each game entirely in one split. The published
sentinel and laggard scripts alternate by seat. Every reply passes through the
hosted parser before its action advances the native simulator. The exporter
refuses an existing output directory.

From a Metta checkout, train the text policy with its post-training CLI:

```bash
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/contagion-standard \
  --output /tmp/contagion-model --model Qwen/Qwen2.5-0.5B-Instruct \
  --max-steps 100 --max-length 4096
```

The dataset is imitation of scripted play; its loss does not measure policy
quality.

The [ordinary player](players/ordinary/README.md) can collect accepted actions from real local
episodes through the standard Coworld policy artifact URL. Its exporter keeps complete game seeds
in one train or validation split. The same player can load the resulting adapter and submit its
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

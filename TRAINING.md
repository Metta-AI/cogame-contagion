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

Train the text policy with Metta's post-training CLI:

```bash
uv run python -m metta_posttrain.train --dataset /tmp/contagion-standard \
  --output /tmp/contagion-model --model Qwen/Qwen2.5-0.5B-Instruct \
  --max-steps 100 --max-length 4096
```

The dataset is imitation of scripted play; its loss does not measure policy
quality. Contagion's dials, per-road controls, aid, and free-form text exceed
the current fixed discrete action bridge for Metta RL and PufferLib.

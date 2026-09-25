# Ordinary Contagion player

This player receives a governor's private week prompt through `contagion.player.v2` and sends a complete weekly decision. The game validates actions, resolves all six seats simultaneously, and writes results and replay. The default backend uses the `sentinel` candidate. `POC_JEV=1` asks Jev System One to choose between complete `sentinel` and `laggard` decisions. `POC_ADAPTER_DIR` loads a Metta post-training adapter that generates action JSON. The published prompt and scripted players remain fieldable.

Build the local game and player images, then run a mixed roster from a manifest based on the downloaded certified package:

```bash
docker build --platform linux/amd64 -t contagion-game:local .
docker build --platform linux/amd64 -f Dockerfile.ordinary-player -t contagion-player:local .
uv run coworld run-episode /path/to/coworld_manifest.json --timeout-seconds 120 -o /tmp/contagion-ordinary
```

For local Jev verification, set `POC_JEV=1` and `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` on the ordinary player. That endpoint uses pinned `typesafe/jev-1.13`. A local mock can return a System One choice response; no production model call is required for protocol testing.

Set `POC_CAPTURE_TRAINING=1` and `POC_SOURCE_REVISION=<policy commit>` to upload accepted decisions through the standard Coworld artifact URL. Capture complete games with different seeds, then export them:

```bash
python players/ordinary/export.py /tmp/contagion-dataset /tmp/contagion-runs --source-revision <policy-commit>
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/contagion-dataset --output /tmp/contagion-adapter --model /path/to/base-model \
  --device cpu --max-steps 100 --max-length 4096 --max-eval-examples 128
```

The existing `tools/export_posttrain.nim` also exports scripted complete games without containers. The artifact exporter admits only completed games, accepted actions, a matching source revision, and separate whole-game seed splits. Review Jev actions before using `--source jev` as training data.

Package the base and adapter into a separate player image:

```bash
docker build --platform linux/amd64 -f Dockerfile.ordinary-model \
  --build-context base=/path/to/base-model --build-context adapter=/tmp/contagion-adapter \
  -t contagion-model:local .
```

The loader checks the base model hash against Metta's training manifest. Evaluate saved policies on held-out games before fielding them.

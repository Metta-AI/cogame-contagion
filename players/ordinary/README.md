# Ordinary Contagion player

This player receives a governor's private week observation through `contagion.player.v3` and sends a complete weekly decision. The game validates actions, resolves all six seats simultaneously, and writes results and replay. The default backend uses the `sentinel` candidate. `POC_ADAPTER_DIR` loads a Metta post-training adapter that generates action JSON. The published prompt and scripted players remain fieldable.

Build the local game and player images, then run a mixed roster from a manifest based on the downloaded certified package:

```bash
docker build --platform linux/amd64 -t contagion-game:local .
docker build --platform linux/amd64 -f Dockerfile.ordinary-player -t contagion-player:local .
uv run coworld run-episode /path/to/coworld_manifest.json --timeout-seconds 120 -o /tmp/contagion-ordinary
```

Set `POC_CAPTURE_TRAINING=1` and `POC_SOURCE_REVISION=<policy commit>` to upload accepted decisions through the standard Coworld artifact URL. Capture complete games with different seeds, then export them:

```bash
python players/ordinary/export.py /tmp/contagion-dataset /tmp/contagion-runs --source-revision <policy-commit>
```

Use the [post-training research package](https://github.com/Metta-AI/posttraining-research/tree/main/packages/metta-posttraining)
for current training and adapter-packaging workflows.

The existing `tools/export_posttrain.nim` also exports scripted complete games without containers. The artifact exporter admits only completed games, accepted actions, a matching source revision, and separate whole-game seed splits.

Package the base and adapter into a separate player image:

```bash
docker build --platform linux/amd64 -f Dockerfile.ordinary-model \
  --build-context base=/path/to/base-model --build-context adapter=/tmp/contagion-adapter \
  -t contagion-model:local .
```

The loader checks the base model hash against Metta's training manifest. Evaluate saved policies on held-out games before fielding them.

## Prompt wording

The host supplies `prompt_selection` on each turn. Both native and ordinary
players render the same versioned `prompt_bank.json`. Rebuild the host and both
player images together.

Existing policy artifacts retain their format. New captures add exact prompt
hashes and the host's executed action. Export verifies available hashes and
excludes new proposals changed or rejected by the host. Historical artifacts
remain readable; they contain only the earlier accepted-decision information.
Held-out game configurations are rejected for training export.

Ordinary export IDs include the complete capture hash. Matched wording runs may
share a scenario seed and remain in the same split; duplicate captures are rejected.
Exported rows retain available selection metadata and verified message hashes.

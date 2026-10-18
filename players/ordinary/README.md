# Ordinary Contagion player

This player receives a governor's private week observation through `contagion.player.v3` and sends a complete weekly decision. The game validates actions, resolves all six seats simultaneously, and writes results and replay. The default backend uses the `sentinel` candidate. `POC_ADAPTER_DIR` loads a Metta post-training adapter that generates action JSON. The published prompt and scripted players remain fieldable.

Build the local game and player images, then run a mixed roster from a manifest based on the downloaded certified package:

```bash
docker build --platform linux/amd64 -t contagion-game:local .
docker build --platform linux/amd64 -f Dockerfile.ordinary-player -t contagion-player:local .
uv run coworld run-episode /path/to/coworld_manifest.json --timeout-seconds 120 -o /tmp/contagion-ordinary
```

Set `POC_CAPTURE_TRAINING=1` and `POC_SOURCE_REVISION=<policy commit>` to upload
private proposals, prompt hashes, and host execution evidence through the standard
Coworld artifact URL. Set `CONTAGION_HOST_TRACE_DIR` to the episode output
folder’s `host` subdirectory. The exporter compares each player record with this
independent host evidence. Capture complete games with different seeds. From an
environment with the shared Coworld Python SDK installed, convert the artifacts:

```bash
python players/ordinary/export.py /tmp/contagion-candidates /tmp/contagion-runs --source-revision <policy-commit>
```

The output is private `trajectories.jsonl` candidate evidence. Shared Coworld
conversion and independent application review must precede training. Seed families
keep all wordings, variants, and seats of one scenario in the same split. Held-out
wordings cannot be exported for training. Host normalization and fallback records
are retained, but their proposals cannot become accepted labels.

Historical version-one artifacts remain readable as JSON archives. They lack
engine execution evidence and cannot qualify as training candidates. Recapture
complete episodes with the updated host and player; do not manufacture missing
evidence from their submitted actions.

The native player optionally writes actual request and response evidence under
`CONTAGION_PLAYER_TRACE_DIR`. The host writes executed actions under
`CONTAGION_HOST_TRACE_DIR`. Use fresh private directories for each episode.
Failed requests retain evidence and preserve the player's existing crash behavior.
No retries or inference calls are invented for subsequent host fallback turns.
These private files contain prompts and notes; they are separate from replay.

The existing `tools/export_posttrain.nim` also exports scripted complete games
without containers. Both exporters require independent review before admission.

Package the base and adapter into a separate player image:

```bash
docker build --platform linux/amd64 -f Dockerfile.ordinary-model \
  --build-context base=/path/to/base-model --build-context adapter=/tmp/contagion-adapter \
  -t contagion-model:local .
```

The loader checks the base model hash against Metta's training manifest. Evaluate saved policies on held-out games before fielding them.

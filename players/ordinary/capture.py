"""Retain private proposals and host execution evidence in the Coworld artifact."""

from __future__ import annotations

import io
import json
import os
import urllib.request
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlsplit


class Capture:
    def __init__(self, slot: int, backend: str) -> None:
        self.slot = slot
        self.backend = backend
        self.revision = os.environ["POC_SOURCE_REVISION"]
        self.upload_url = os.environ["COWORLD_PLAYER_ARTIFACT_UPLOAD_URL"]
        self.rows: list[dict] = []

    def record(self, system: str, user: str, action: dict, source: str, week: int,
               prompt_template: dict, execution_evidence: dict, model_response: str | None) -> None:
        self.rows.append({
            "decision_id": len(self.rows), "week": week, "source": source,
            "prompt_template": prompt_template, "execution_evidence": execution_evidence,
            "model_response": model_response,
            "prompt": [{"role": "system", "content": system},
                       {"role": "user", "content": user}],
            "completion": [{"role": "assistant", "content": json.dumps(action, sort_keys=True)}],
        })

    def upload(self, scores: list[int]) -> None:
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr("trajectory.json", json.dumps({
                "schema_version": 1, "game": "contagion", "slot": self.slot,
                "backend": self.backend, "source_revision": self.revision,
                "complete": True, "scores": scores, "decisions": self.rows,
            }))
        data = archive.getvalue()
        url = urlsplit(self.upload_url)
        if url.scheme == "file":
            target = Path(unquote(url.path))
            pending = target.with_name(target.name + ".tmp")
            with os.fdopen(os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as output:
                output.write(data)
            os.replace(pending, target)
        else:
            request = urllib.request.Request(self.upload_url, data=data, method="PUT",
                                             headers={"Content-Type": "application/zip"})
            with urllib.request.urlopen(request, timeout=10) as response:
                response.read()

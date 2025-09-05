from __future__ import annotations

import os
from pathlib import Path

from fastapi import APIRouter, Depends, UploadFile, File, HTTPException, Query
from sqlalchemy.orm import Session

from ..db import get_db
from .. import models


router = APIRouter()


BASE_DIR = Path(__file__).resolve().parent.parent
MEDIA_DIR = BASE_DIR.parent / "data" / "media"
MEDIA_DIR.mkdir(parents=True, exist_ok=True)


@router.post("/sessions/{session_id}/chunks")
async def upload_chunk(
    session_id: str,
    index: int = Query(..., ge=0),
    f: UploadFile = File(...),
    db: Session = Depends(get_db),
):
    sess = db.get(models.SessionRecord, session_id)
    if not sess:
        raise HTTPException(status_code=404, detail="session not found")

    ext = Path(f.filename or "").suffix or ".webm"
    dest_dir = MEDIA_DIR / session_id / "original"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"chunk_{index:06d}{ext}"

    # Save file
    with dest.open("wb") as out:
        while True:
            chunk = await f.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)

    # Record in DB
    rec = models.ChunkRecord(session_id=session_id, chunk_index=index, original_path=str(dest))
    db.add(rec)
    db.commit()

    # Enqueue transcription task (deferred implementation)
    # For now, simply return accepted
    return {"status": "accepted", "path": str(dest)}


from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..db import get_db
from .. import models, schemas


router = APIRouter()


@router.get("/sessions/{session_id}/transcript", response_model=schemas.TranscriptOut)
def get_transcript(session_id: str, db: Session = Depends(get_db)):
    sess = db.get(models.SessionRecord, session_id)
    if not sess:
        raise HTTPException(status_code=404, detail="session not found")
    segs = (
        db.query(models.SegmentRecord)
        .filter(models.SegmentRecord.session_id == session_id)
        .order_by(models.SegmentRecord.chunk_index.asc(), models.SegmentRecord.start_seconds.asc())
        .all()
    )
    text = "\n".join(s.text for s in segs)
    segments = [
        schemas.SegmentOut(
            chunk_index=s.chunk_index,
            start_seconds=s.start_seconds,
            end_seconds=s.end_seconds,
            text=s.text,
        )
        for s in segs
    ]
    return schemas.TranscriptOut(session_id=session_id, text=text, segments=segments)


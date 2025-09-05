from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..db import get_db
from .. import models, schemas


router = APIRouter()


@router.post("/sessions", response_model=schemas.SessionOut)
def create_session(payload: schemas.SessionCreate, db: Session = Depends(get_db)):
    rec = models.SessionRecord(title=payload.title, language=payload.language)
    db.add(rec)
    db.commit()
    db.refresh(rec)
    return rec


@router.get("/sessions/{session_id}", response_model=schemas.SessionOut)
def get_session(session_id: str, db: Session = Depends(get_db)):
    rec = db.get(models.SessionRecord, session_id)
    if not rec:
        raise HTTPException(status_code=404, detail="session not found")
    return rec


@router.post("/sessions/{session_id}/close", response_model=schemas.SessionOut)
def close_session(session_id: str, db: Session = Depends(get_db)):
    rec = db.get(models.SessionRecord, session_id)
    if not rec:
        raise HTTPException(status_code=404, detail="session not found")
    rec.is_closed = True
    db.add(rec)
    db.commit()
    db.refresh(rec)
    return rec


@router.get("/sessions/{session_id}/status", response_model=schemas.SessionStatus)
def status(session_id: str, db: Session = Depends(get_db)):
    sess = db.get(models.SessionRecord, session_id)
    if not sess:
        raise HTTPException(status_code=404, detail="session not found")
    chunks = db.query(models.ChunkRecord).filter(models.ChunkRecord.session_id == session_id).count()
    segments = db.query(models.SegmentRecord).filter(models.SegmentRecord.session_id == session_id).count()
    return schemas.SessionStatus(session=sess, chunks_received=chunks, segments_generated=segments, is_closed=sess.is_closed)


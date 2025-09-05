from __future__ import annotations

import datetime as dt
from typing import Optional, List

from pydantic import BaseModel, Field


class SessionCreate(BaseModel):
    title: Optional[str] = None
    language: Optional[str] = Field(default=None, description="ISO 639-1 code or 'auto'")


class SessionOut(BaseModel):
    id: str
    title: Optional[str]
    language: Optional[str]
    is_closed: bool
    created_at: dt.datetime

    class Config:
        from_attributes = True


class SessionStatus(BaseModel):
    session: SessionOut
    chunks_received: int
    segments_generated: int
    is_closed: bool


class SegmentOut(BaseModel):
    chunk_index: int
    start_seconds: float
    end_seconds: float
    text: str


class TranscriptOut(BaseModel):
    session_id: str
    text: str
    segments: List[SegmentOut]


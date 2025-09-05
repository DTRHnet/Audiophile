from __future__ import annotations

import datetime as dt
import uuid
from sqlalchemy import Column, String, DateTime, Boolean, Integer, Float, ForeignKey, Text, Index
from sqlalchemy.orm import relationship

from .db import Base


def generate_uuid() -> str:
    return uuid.uuid4().hex


class SessionRecord(Base):
    __tablename__ = "sessions"

    id = Column(String(32), primary_key=True, default=generate_uuid)
    title = Column(String(200), nullable=True)
    language = Column(String(20), nullable=True)
    is_closed = Column(Boolean, default=False, nullable=False)
    created_at = Column(DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc), nullable=False)

    # relationships (not strictly required for MVP)
    # chunks = relationship("ChunkRecord", back_populates="session")
    # segments = relationship("SegmentRecord", back_populates="session")


class ChunkRecord(Base):
    __tablename__ = "chunks"

    id = Column(Integer, primary_key=True, autoincrement=True)
    session_id = Column(String(32), ForeignKey("sessions.id", ondelete="CASCADE"), index=True, nullable=False)
    chunk_index = Column(Integer, nullable=False)
    original_path = Column(String(500), nullable=False)
    normalized_path = Column(String(500), nullable=True)
    duration_seconds = Column(Float, nullable=True)
    created_at = Column(DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc), nullable=False)

    __table_args__ = (
        Index("ix_chunk_session_index", "session_id", "chunk_index", unique=True),
    )


class SegmentRecord(Base):
    __tablename__ = "segments"

    id = Column(Integer, primary_key=True, autoincrement=True)
    session_id = Column(String(32), ForeignKey("sessions.id", ondelete="CASCADE"), index=True, nullable=False)
    chunk_index = Column(Integer, nullable=False)
    start_seconds = Column(Float, nullable=False)
    end_seconds = Column(Float, nullable=False)
    text = Column(Text, nullable=False)
    created_at = Column(DateTime(timezone=True), default=lambda: dt.datetime.now(dt.timezone.utc), nullable=False)

    __table_args__ = (
        Index("ix_segment_session_chunk_start", "session_id", "chunk_index", "start_seconds"),
    )


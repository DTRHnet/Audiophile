from __future__ import annotations

import os
from pathlib import Path
from typing import Generator

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session, declarative_base


BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)

SQLITE_PATH = DATA_DIR / "app.db"
DATABASE_URL = os.getenv("DATABASE_URL", f"sqlite:///{SQLITE_PATH}")

# SQLite needs check_same_thread=False for usage across threads in a single process
connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}

engine = create_engine(DATABASE_URL, echo=False, future=True, connect_args=connect_args)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)

Base = declarative_base()


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


from __future__ import annotations

import asyncio
import subprocess
from pathlib import Path
import sys
from typing import Optional

from sqlalchemy.orm import Session

from app.db import SessionLocal
from app import models


BASE_DIR = Path(__file__).resolve().parents[1]
# Ensure 'server' directory is on sys.path so `import app` works when executing this script directly
if str(BASE_DIR) not in sys.path:
    sys.path.append(str(BASE_DIR))
DATA_DIR = BASE_DIR / "data"
MEDIA_DIR = DATA_DIR / "media"
NORM_DIR = MEDIA_DIR / "normalized"
NORM_DIR.mkdir(parents=True, exist_ok=True)


def ffmpeg_normalize(input_path: Path, output_path: Path) -> bool:
    cmd = [
        "ffmpeg",
        "-y",
        "-loglevel",
        "error",
        "-i",
        str(input_path),
        "-ar",
        "16000",
        "-ac",
        "1",
        str(output_path),
    ]
    try:
        subprocess.run(cmd, check=True)
        return True
    except subprocess.CalledProcessError:
        return False


def faster_whisper_transcribe(wav_path: Path, language: Optional[str] = None) -> list[tuple[float, float, str]]:
    """Minimal synchronous wrapper that shells out to faster-whisper via a python -c call.
    We avoid importing heavy libs in the worker scaffold for now.
    Returns list of (start, end, text) tuples.
    """
    code = f"""
import sys, json
from faster_whisper import WhisperModel
model = WhisperModel('base', device='cpu')
segments, info = model.transcribe('{wav_path.as_posix()}', language={repr(language)} if {repr(language)} not in (None, 'auto') else None)
out = []
for s in segments:
    out.append([s.start or 0.0, s.end or 0.0, s.text or ''])
print(json.dumps(out))
"""
    try:
        res = subprocess.run(["python", "-c", code], capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(e.stderr or str(e))
    import json
    return [(float(a), float(b), str(t)) for a, b, t in json.loads(res.stdout.strip() or "[]")]


def process_pending_once() -> int:
    """Normalize all un-normalized chunks and transcribe them into segments.
    Returns number of chunks processed.
    """
    db: Session = SessionLocal()
    try:
        pending = (
            db.query(models.ChunkRecord)
            .filter(models.ChunkRecord.normalized_path.is_(None))
            .order_by(models.ChunkRecord.created_at.asc())
            .all()
        )
        count = 0
        for ch in pending:
            src = Path(ch.original_path)
            out_dir = NORM_DIR / ch.session_id
            out_dir.mkdir(parents=True, exist_ok=True)
            wav_path = out_dir / f"chunk_{ch.chunk_index:06d}.wav"
            if not ffmpeg_normalize(src, wav_path):
                # Mark as normalized to avoid infinite retry loop; production would track error state
                ch.normalized_path = "ERROR"
                db.add(ch)
                db.commit()
                continue

            ch.normalized_path = str(wav_path)
            db.add(ch)
            db.commit()

            sess = db.get(models.SessionRecord, ch.session_id)
            segments = faster_whisper_transcribe(wav_path, language=sess.language)
            for (start, end, text) in segments:
                seg = models.SegmentRecord(
                    session_id=ch.session_id,
                    chunk_index=ch.chunk_index,
                    start_seconds=start,
                    end_seconds=end,
                    text=text.strip(),
                )
                db.add(seg)
            db.commit()
            count += 1
        return count
    finally:
        db.close()


async def main_loop(poll_seconds: float = 1.5) -> None:
    while True:
        processed = process_pending_once()
        await asyncio.sleep(poll_seconds if processed == 0 else 0.1)


if __name__ == "__main__":
    try:
        asyncio.run(main_loop())
    except KeyboardInterrupt:
        pass


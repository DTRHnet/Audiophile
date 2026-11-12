#!/usr/bin/env python3
# ::
# :: audiophile-vad.py  --  part of DTRH-Audiophile
# ::
# :: Reads raw PCM (s16le, mono) on stdin, tracks the room's noise floor and
# :: writes ONE WAV per spoken utterance. Used by DTRH-Audiophile.sh so that
# :: whisper only ever sees speech instead of fixed 30s slices of silence.
# ::
# :: stdout protocol (one event per line, key=value, flushed immediately):
# ::   ev=ready  sr=16000 block_ms=100 thr=.. floor=..
# ::   ev=level  t=<stream seconds> db=.. floor=.. thr=.. state=idle|speech buf=..
# ::   ev=begin  t=<stream seconds>
# ::   ev=segment file=.. t0=.. t1=.. dur=.. voiced=.. db=.. peak=.. reason=..
# ::   ev=idle   seconds=..
# ::   ev=end    segments=..
# ::   ev=error  msg=..
# ::
# :: Configuration comes from the environment (all optional):
# ::   VAD_OUTDIR (required) VAD_TAG VAD_SR VAD_BLOCK_MS VAD_SPEECH_DB
# ::   VAD_MARGIN_DB VAD_PREROLL_MS VAD_ENDSIL_MS VAD_MINSPEECH_MS
# ::   VAD_MAXSEG_MS VAD_TAIL_MS VAD_LEVEL_EVERY_S VAD_IDLE_EVERY_S
# :: ------------------------------------------------------------------------
"""Silence-gated speech segmenter for the Audiophile transcription pipeline."""

import math
import os
import struct
import sys
import time
import wave
from collections import deque


def _f(key, default):
    try:
        return float(os.environ.get(key, default))
    except ValueError:
        return float(default)


def _i(key, default):
    try:
        return int(float(os.environ.get(key, default)))
    except ValueError:
        return int(default)


SR = _i("VAD_SR", 16000)
BLOCK_MS = _i("VAD_BLOCK_MS", 100)
SPEECH_DB = _f("VAD_SPEECH_DB", -55.0)     # absolute speaking threshold
MARGIN_DB = _f("VAD_MARGIN_DB", 10.0)      # ... or this far above the floor
PREROLL_MS = _i("VAD_PREROLL_MS", 2000)    # audio kept from before the onset
ENDSIL_MS = _i("VAD_ENDSIL_MS", 1500)      # silence that closes an utterance
MINSPEECH_MS = _i("VAD_MINSPEECH_MS", 400)  # discard clicks/blips
MAXSEG_MS = _i("VAD_MAXSEG_MS", 120000)    # hard cap, then continue a new file
TAIL_MS = _i("VAD_TAIL_MS", 250)           # keep a little after the last word
OUTDIR = os.environ.get("VAD_OUTDIR", ".")
TAG = os.environ.get("VAD_TAG", "seg")
LEVEL_EVERY_S = _f("VAD_LEVEL_EVERY_S", 1.0)
IDLE_EVERY_S = _f("VAD_IDLE_EVERY_S", 15.0)
ONSET_BLOCKS = _i("VAD_ONSET_BLOCKS", 2)   # 2 x 100ms of energy = speech onset

BLOCK = SR * BLOCK_MS // 1000              # samples per block
BLOCK_BYTES = BLOCK * 2
FLOOR_START = -70.0
FLOOR_MIN = -90.0
FLOOR_MAX = -40.0
DB_FLOOR = -91.0


def emit(**kw):
    """Print one key=value event and flush; bash reads this line by line."""
    sys.stdout.write(" ".join("%s=%s" % (k, v) for k, v in kw.items()) + "\n")
    sys.stdout.flush()


def block_db(chunk):
    """RMS of one block in dBFS plus its peak sample, from raw s16le bytes."""
    n = len(chunk) // 2
    if n == 0:
        return DB_FLOOR, 0, 0
    samples = struct.unpack("<%dh" % n, chunk[: n * 2])
    peak = 0
    total = 0
    for s in samples:
        if s < 0:
            s = -s
        if s > peak:
            peak = s
        total += s * s
    if total == 0:
        return DB_FLOOR, 0, 0
    rms = math.sqrt(total / n)
    return 20.0 * math.log10(rms / 32768.0), peak, total


def write_wav(path, data):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)


def read_block(stream, nbytes):
    """Read exactly nbytes (a short read means the pipeline closed)."""
    buf = b""
    while len(buf) < nbytes:
        chunk = stream.read(nbytes - len(buf))
        if not chunk:
            return buf
        buf += chunk
    return buf


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    stream = sys.stdin.buffer
    stamp = time.strftime("%Y%m%d_%H%M%S")

    floor = FLOOR_START
    buf = deque()          # (index, bytes) history for preroll + segment
    buf_first = 0          # absolute block index of buf[0]
    index = 0              # next absolute block index
    state = "idle"
    onset = 0
    silence = 0
    seg_start = 0
    voiced = 0
    seg_total = 0
    seg_peak = 0
    seg_sum = 0.0
    seg_n = 0
    seg_no = 0
    idle_blocks = 0
    segments = 0
    last_level = 0.0
    last_idle = 0.0
    preroll_blocks = max(1, PREROLL_MS // BLOCK_MS)
    tail_blocks = max(0, TAIL_MS // BLOCK_MS)
    endsil_blocks = max(1, ENDSIL_MS // BLOCK_MS)
    maxseg_blocks = max(1, MAXSEG_MS // BLOCK_MS)
    minsp_blocks = max(1, MINSPEECH_MS // BLOCK_MS)

    emit(ev="ready", sr=SR, block_ms=BLOCK_MS, thr="%.1f" % SPEECH_DB,
         floor="%.1f" % floor, outdir=OUTDIR)

    def trim():
        """Keep only what a future segment could still need."""
        nonlocal buf_first
        keep = preroll_blocks + 2
        while len(buf) > keep:
            buf.popleft()
            buf_first += 1

    def close_segment(end_index, reason):
        nonlocal state, segments, seg_no, voiced
        start = max(seg_start, buf_first)
        data = b"".join(blk for idx, blk in buf if start <= idx < end_index)
        dur = len(data) / 2.0 / SR
        if not data or voiced * BLOCK_MS < MINSPEECH_MS:
            emit(ev="drop", dur="%.2f" % dur, voiced_ms=voiced * BLOCK_MS,
                 reason="too_short")
            return False
        seg_no += 1
        name = "%s_%s_%03d.wav" % (TAG, stamp, seg_no)
        path = os.path.join(OUTDIR, name)
        write_wav(path, data)
        mean_db = 20.0 * math.log10(math.sqrt(seg_sum / seg_n) / 32768.0) if seg_n and seg_sum else DB_FLOOR
        peak_db = 20.0 * math.log10(seg_peak / 32768.0) if seg_peak else DB_FLOOR
        segments += 1
        emit(ev="segment", file=path, t0="%.2f" % (start * BLOCK_MS / 1000.0),
             t1="%.2f" % (end_index * BLOCK_MS / 1000.0), dur="%.2f" % dur,
             voiced="%.2f" % (voiced * BLOCK_MS / 1000.0),
             db="%.1f" % mean_db, peak="%.1f" % peak_db, reason=reason)
        return True

    def reset_seg_stats():
        nonlocal voiced, seg_sum, seg_n, seg_peak
        voiced = 0
        seg_sum = 0.0
        seg_n = 0
        seg_peak = 0

    try:
        while True:
            chunk = read_block(stream, BLOCK_BYTES)
            if not chunk:
                break
            if len(chunk) % 2:
                chunk = chunk[:-1]
            db, peak, sumsq = block_db(chunk)
            now = index * BLOCK_MS / 1000.0

            # Noise floor: fall fast, climb slowly, never leave its band.
            if db < floor:
                floor = max(db, FLOOR_MIN)
            elif state == "idle":
                floor = min(FLOOR_MAX, floor + 0.05)
            thr = max(SPEECH_DB, floor + MARGIN_DB)
            loud = db > thr and peak > 0

            buf.append((index, chunk))
            index += 1

            if state == "idle":
                if loud:
                    onset += 1
                    if onset >= ONSET_BLOCKS:
                        state = "speech"
                        seg_start = max(buf_first, index - onset - preroll_blocks)
                        reset_seg_stats()
                        voiced = onset
                        seg_sum = sumsq
                        seg_n = len(chunk) // 2
                        seg_peak = peak
                        silence = 0
                        emit(ev="begin", t="%.2f" % now)
                        emit(ev="level", t="%.2f" % now, db="%.1f" % db,
                             floor="%.1f" % floor, thr="%.1f" % thr,
                             state=state, buf="%.1f" % (len(buf) * BLOCK_MS / 1000.0))
                else:
                    onset = 0
                    trim()
                idle_blocks += 1
            else:  # speech
                if loud:
                    silence = 0
                    voiced += 1
                    seg_sum += sumsq
                    seg_n += len(chunk) // 2
                    if peak > seg_peak:
                        seg_peak = peak
                else:
                    silence += 1
                overflow = (index - seg_start) >= maxseg_blocks
                done = silence >= endsil_blocks
                if done or overflow:
                    end_index = index - silence + tail_blocks if done else index
                    closed = close_segment(end_index, "silence" if done else "maxlen")
                    if closed:
                        idle_blocks = 0
                    if done:
                        state = "idle"
                        onset = 0
                        reset_seg_stats()
                        trim()
                    else:  # keep listening on a fresh segment
                        seg_start = index
                        reset_seg_stats()
                        silence = 0

            if state == "idle":
                idle_seconds = idle_blocks * BLOCK_MS / 1000.0
                if idle_seconds - last_idle >= IDLE_EVERY_S:
                    last_idle = idle_seconds
                    emit(ev="idle", seconds="%d" % idle_seconds)
            else:
                idle_blocks = 0
                last_idle = 0.0

            if now - last_level >= LEVEL_EVERY_S:
                last_level = now
                emit(ev="level", t="%.2f" % now, db="%.1f" % db,
                     floor="%.1f" % floor, thr="%.1f" % thr, state=state,
                     buf="%.1f" % (len(buf) * BLOCK_MS / 1000.0))

    except BrokenPipeError:
        pass
    except KeyboardInterrupt:
        pass
    except Exception as exc:  # never die silently: bash restarts the pipeline
        emit(ev="error", msg=str(exc).replace(" ", "_")[:200])
        return 1

    if state == "speech":
        close_segment(index, "eof")
    emit(ev="end", segments=segments)
    return 0


if __name__ == "__main__":
    sys.exit(main())

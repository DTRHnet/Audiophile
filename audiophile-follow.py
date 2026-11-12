#!/usr/bin/env python3
# ::
# :: audiophile-follow.py  --  part of DTRH-Audiophile
# ::
# :: Streams the bytes of a growing file to stdout, exactly once each, forever.
# ::
# :: This is the piece that lets one long-lived ffmpeg decode an Ogg/Opus file
# :: while termux-microphone-record is still writing it. Two alternatives were
# :: measured and rejected:
# ::   * `tail -f file | ffmpeg -f ogg -i -`  -> ffmpeg dies with
# ::     "Error opening input: End of file", 0 bytes decoded
# ::   * a bash loop of stat/dd/sleep        -> works, but ~10% of one core
# ::     just in fork overhead at 4 kB/s of input
# ::
# :: usage: audiophile-follow.py <file> [poll_seconds]
# :: ------------------------------------------------------------------------
"""Follow a growing file and write every new byte to stdout, once."""

import sys
import time


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: audiophile-follow.py <file> [poll_seconds]\n")
        return 2
    path = sys.argv[1]
    poll = float(sys.argv[2]) if len(sys.argv) > 2 else 0.15
    out = sys.stdout.buffer
    f = None
    idle = 0
    try:
        while True:
            if f is None:
                try:
                    f = open(path, "rb")
                except OSError:
                    time.sleep(poll)
                    continue
            chunk = f.read(262144)
            if chunk:
                out.write(chunk)
                out.flush()
                idle = 0
            else:
                # the writer may not have flushed the next Ogg page yet
                time.sleep(poll)
                idle += 1
    except (BrokenPipeError, KeyboardInterrupt):
        return 0
    except Exception:
        return 1
    finally:
        try:
            out.flush()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())

#!/data/data/com.termux/files/usr/bin/env bash

# ::
# :: DTRH-Session.sh
# :: Launches a split-screen tmux session: transcription + debug viewer
# ::

SESSION="dtrh-audio"

# Kill if already running
tmux kill-session -t "$SESSION" 2>/dev/null

# Create new session running transcription
tmux new-session -d -s "$SESSION" './DTRH-Audiophile.sh'

# Split horizontally and show log tail
tmux split-window -v -t "$SESSION" './DTRH-Audiophile.sh --tail'

# Optional: set pane titles
tmux select-pane -T "Transcriber"
tmux select-pane -D
tmux select-pane -T "Logs"

# Attach to session
tmux attach -t "$SESSION"

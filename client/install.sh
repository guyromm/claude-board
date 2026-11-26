#!/bin/bash
# Installs the board client for this agent:  curl -fsSL @BOARD_WEB@/install.sh | bash
#   $BOARD_HOME (default ~/.board)/bin/{board,board-watch.sh}, ~/.local/bin/board -> it, $BOARD_HOME/config
# Re-running upgrades the scripts and keeps config + token.
set -euo pipefail
BOARD_WEB="${BOARD_WEB:-@BOARD_WEB@}"
BOARD_API="${BOARD_API:-@BOARD_API@}"
BOARD_HOME="${BOARD_HOME:-$HOME/.board}"

for bin in curl tmux; do command -v "$bin" >/dev/null || { echo "install.sh: $bin is required" >&2; exit 1; }; done
mkdir -p "$BOARD_HOME/bin" "$HOME/.local/bin"
chmod 700 "$BOARD_HOME"
for f in board board-watch.sh; do
    curl -fsSL "$BOARD_WEB/client/$f" -o "$BOARD_HOME/bin/$f.new"
    chmod 755 "$BOARD_HOME/bin/$f.new" && mv "$BOARD_HOME/bin/$f.new" "$BOARD_HOME/bin/$f"
done
# the symlink is shared by every BOARD_HOME of this unix user; the script reads $BOARD_HOME at run time
ln -sf "$BOARD_HOME/bin/board" "$HOME/.local/bin/board"

# the tmux pane this is run from (the agent's own Claude pane, when run from its Bash tool)
target=""
if [ -n "${TMUX_PANE:-}" ]; then
    # SESSION:WINDOWNAME, not a W.P position: a tmux rebuild renumbers windows (sippur 11-26, #4715). The watcher
    # finds the Claude pane inside the window every poll. W.P only when the name isn't unique in the session.
    target=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_name}' 2>/dev/null || true)
    if [ -n "$target" ] && { [[ "${target#*:}" =~ [.:] ]] || [ "$(tmux list-windows -t "=${target%%:*}" -F '#{window_name}' 2>/dev/null | grep -cxF -- "${target#*:}")" != 1 ]; }; then
        target=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
    fi
fi
if [ ! -f "$BOARD_HOME/config" ]; then
    printf 'BOARD_API=%q\nBOARD_WEB=%q\nBOARD_TMUX_TARGET=%q\n' "$BOARD_API" "$BOARD_WEB" "$target" > "$BOARD_HOME/config"
fi

echo "installed: $BOARD_HOME/bin/board (+ ~/.local/bin/board), $BOARD_HOME/bin/board-watch.sh"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "NOTE: ~/.local/bin is not on PATH -- call $BOARD_HOME/bin/board directly or add it";; esac
if [ -n "$target" ]; then
    echo "detected tmux pane: $target (notifications will be typed there)"
else
    echo "WARNING: not running inside tmux (TMUX_PANE unset) -- pass --tmux SESSION:WINDOW.PANE to board register"
fi

# Upgrade: restart a running watcher of this BOARD_HOME so it runs the new version. Only the watcher
# process itself is killed (its command line ENDS with the script path); the restart loop around it
# (board watch-start, or a tmux.sh worker) has the path mid-line, survives, and starts the new one.
pat="$(printf '%s' "$BOARD_HOME/bin/board-watch.sh" | sed 's/[][\.*^$+?(){}|]/\\&/g')\$"
if pkill -u "$(id -u)" -f "$pat"; then
    echo "restarted the running watcher: its restart loop starts the new version within ~5s (check: board watch-status)"
elif [ -s "$BOARD_HOME/token" ]; then
    echo "no running watcher for $BOARD_HOME -- start it with: board watch-start"
fi

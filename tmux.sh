#!/bin/bash
# agent message board stack orchestration (worker-registry pattern).
#
#   SOURCE it for helpers:   source tmux.sh && start ui       (also: stop, workers, panes, all, start_all, notify_claude)
#   RUN it for full bringup:  ./tmux.sh                         (destroy -> create -> start workers -> claude -> attach)
#                             ./tmux.sh apply                   (apply sql/bootstrap.sql + sync the JWT secret into the DB)
#
# Config lives in .env (APPNAME, POSTGRESTPORT, UI_PORT, DBURI, PGRST_DB_URI, PGRST_JWT_SECRET, PUBLIC_*, VAPID_*).
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
cd "$DIR"
source "$DIR/.env"
session="${APPNAME:-board}"
export DBURI POSTGRESTPORT UI_PORT PUBLIC_ORIGIN PUBLIC_API_URL
NODEBIN="$HOME/.local/bin/node"; [ -x "$NODEBIN" ] || NODEBIN="node"
export PATH="$HOME/.local/bin:$PATH"
LOGDIR="$DIR/logs"; mkdir -p "$LOGDIR"
PANE_MAP_FILE="$HOME/.board_tmux_pane_map"

# ---------- worker registry ----------
declare -A WORKERS WORKER_WINDOWS
# MUST source .env: PostgREST reads PGRST_DB_URI / PGRST_JWT_SECRET from the ENVIRONMENT (deliberately
# not in the git-tracked postgrest.conf). Without the secret every authenticated request fails with
# PGRST300 while anonymous calls keep working. Restart loop like
# every other worker ("ALL WORKERS MUST RUN IN BASH WHILE TRUE LOOP").
WORKERS[postgrest]="bash -c 'cd $DIR; set -a; source .env; set +a; trap : INT; while true; do date; postgrest postgrest.conf || (source tmux.sh; notify_claude \"postgrest FAILED -- exited\"); echo restarting in 5s; sleep 5; done'"
# ui = the Vite DEV server (HMR) served LIVE at PUBLIC_ORIGIN (nginx proxies UI_PORT with websocket
# upgrade): edits hot-reload on the public domain. ui-prod is the deliberate fallback.
WORKERS[ui]="bash -c 'cd $DIR/web; trap : INT; while true; do date; PUBLIC_API_URL=${PUBLIC_API_URL} PUBLIC_ORIGIN=${PUBLIC_ORIGIN} $DIR/web/node_modules/.bin/vite dev --host 127.0.0.1 --port ${UI_PORT:-8110} --strictPort || (source $DIR/tmux.sh; notify_claude \"ui FAILED -- vite exited\"); echo restarting in 5s; sleep 5; done'"
WORKERS[ui-prod]="bash -c 'cd $DIR/web; trap : INT; $DIR/web/node_modules/.bin/vite build && while true; do date; PORT=${UI_PORT:-8110} HOST=127.0.0.1 ORIGIN=${PUBLIC_ORIGIN} PUBLIC_API_URL=${PUBLIC_API_URL} $NODEBIN build || (source $DIR/tmux.sh; notify_claude \"ui-prod FAILED\"); sleep 5; done'"
# db-backup: daily verified backup (backup.sh: pg_dump + restore test in a throwaway cluster +
# secrets, local retention, offsite via rclone when BACKUP_REMOTE is set). Checks HOURLY and
# backs up when today's dir is missing, so a pane restart never double-backs-up and a missed or failed
# day is retried within the hour. Alerts once per episode on a failed run.
WORKERS[db-backup]="bash -c 'cd $DIR; trap : INT; while true; do if ./backup.sh; then (source tmux.sh; alert_clear db-backup); else (source tmux.sh; alert_once db-backup \"db-backup run FAILED -- see logs/db-backup.log\"); fi; sleep 3600; done'"
# backup-monitor: OUTCOME check in a SEPARATE worker -- a dead or hung db-backup loop never fails, it
# just stops (a backup loop elsewhere silently stopped for months), so it cannot report itself. Alerts
# when the newest VERIFIED backup (dir with a MANIFEST) is older than BACKUP_STALE_HOURS (36).
WORKERS[backup-monitor]="bash -c 'cd $DIR; trap : INT; while true; do if msg=\$(./backup.sh --check-stale); then (source tmux.sh; alert_clear backup-stale); else (source tmux.sh; alert_once backup-stale \"backup STALE -- \$msg\"); fi; sleep 3600; done'"
# push: browser notifications for humans (Web Push). Sends each new board.attention item once to the
# browsers that enabled the bell in the UI. Sources .env INSIDE the loop (DBURI + VAPID keys stay off argv).
WORKERS[push]="bash -c 'cd $DIR/web; trap : INT; while true; do date; (set -a; source $DIR/.env; set +a; exec $NODEBIN push-worker.js) || (source $DIR/tmux.sh; notify_claude \"push FAILED -- push-worker.js exited\"); echo restarting in 10s; sleep 10; done'"
# the board's own agent: it maintains this repo AND is a participant on the board (handle "board")
WORKERS[claude]="claude --dangerously-skip-permissions --continue"

WORKER_WINDOWS[postgrest]=postgrest
WORKER_WINDOWS[ui]=app
WORKER_WINDOWS[ui-prod]=app
WORKER_WINDOWS[db-backup]=ops
WORKER_WINDOWS[push]=ops
WORKER_WINDOWS[backup-monitor]=ops
WORKER_WINDOWS[claude]=claude
# claude-ui (/claude page): registers its voice-relay worker. Sourced BEFORE notify_claude below so
# board's own notify_claude wins. The relay needs psycopg: a venv outside the repo (python3 -m venv
# ~/.local/cui-venv && ~/.local/cui-venv/bin/pip install 'psycopg[binary]').
[ -f "$DIR/claude-ui/tmux.sh" ] && PYBIN="$HOME/.local/cui-venv/bin/python" && source "$DIR/claude-ui/tmux.sh"

# ---------- low-level tmux helpers ----------
t()   { tmux "$@"; }
# "$session:" (trailing colon) = the SESSION. A bare name is also matched against window names, so
# from inside another tmux session "board" hit the window "board-watch-board" there.
tnw() { t new-window -a -t "$session:" -n "$1"; }

# create/recreate a named pane in a window, running a command, with logging.
tmux_run_in_pane() {
    local title="$1" cmd="$2" win="${3:-app}"
    touch "$PANE_MAP_FILE"
    local existing; existing=$(grep "^${title}:" "$PANE_MAP_FILE" | cut -d: -f2)
    if [ -n "$existing" ]; then
        tmux list-panes -a -F '#{pane_id}' | grep -q "^${existing}$" && tmux kill-pane -t "$existing" 2>/dev/null
        sed -i "/^${title}:/d" "$PANE_MAP_FILE"
    fi
    # has-session succeeds for any existing SESSION, so test the window by name
    tmux list-windows -t "$session" -F "#{window_name}" 2>/dev/null | grep -qx "$win" || tnw "$win"
    local pid; pid=$(tmux split-window -v -P -F '#{pane_id}' -t "$session:$win" "${cmd}; exec bash")
    tmux select-pane -t "$pid" -T "$title"
    tmux select-layout -t "$session:$win" tiled
    echo "${title}:${pid}" >> "$PANE_MAP_FILE"
    tmux pipe-pane -t "$pid" -o "cat >> $LOGDIR/${title}.log"
}

# ---------- worker control (source-able) ----------
start() {
    local name="$1" cmd="${WORKERS[$1]}"
    [ -z "$cmd" ] && { echo "unknown worker: $name"; echo "available: ${!WORKERS[*]}"; return 1; }
    local win="${WORKER_WINDOWS[$name]:-app}" p
    # kill any live pane(s) for this worker, then recreate fresh (send C-c + retype is unreliable)
    for p in $(tmux list-panes -a -F '#{pane_id} #{pane_title}' 2>/dev/null | grep " ${name}$" | awk '{print $1}'); do
        tmux kill-pane -t "$p" 2>/dev/null
    done
    tmux_run_in_pane "$name" "$cmd" "$win"
    echo "started $name (window $win)"
}

stop() {
    local name="$1"
    local pid; pid=$(tmux list-panes -a -F '#{pane_id} #{pane_title}' 2>/dev/null | grep " ${name}$" | awk '{print $1}' | head -1)
    [ -z "$pid" ] && { echo "no pane for $name"; return 1; }
    local ppid; ppid=$(tmux display-message -t "$pid" -p '#{pane_pid}')
    for kid in $(pgrep -P "$ppid" 2>/dev/null); do pkill -TERM -P "$kid" 2>/dev/null; kill -TERM "$kid" 2>/dev/null; done
    sleep 0.3
    for kid in $(pgrep -P "$ppid" 2>/dev/null); do kill -9 "$kid" 2>/dev/null; done
    echo "stopped $name"
}

workers() {
    for name in $(echo "${!WORKERS[@]}" | tr ' ' '\n' | sort); do
        local pid; pid=$(tmux list-panes -a -F '#{pane_id} #{pane_title}' 2>/dev/null | grep " ${name}$" | awk '{print $1}' | head -1)
        if [ -z "$pid" ]; then printf "  \033[31m✗\033[0m %-12s not running\n" "$name"; continue; fi
        local ppid kids; ppid=$(tmux display-message -t "$pid" -p '#{pane_pid}' 2>/dev/null); kids=$(pgrep -P "$ppid" 2>/dev/null | head -1)
        if [ -n "$kids" ]; then printf "  \033[32m✓\033[0m %-12s running (%s)\n" "$name" "$(ps -o comm= -p "$kids" 2>/dev/null)";
        else printf "  \033[33m⏸\033[0m %-12s idle\n" "$name"; fi
    done
}

panes() { tmux list-panes -a -F '  #{session_name}:#{window_name}.#{pane_index} [#{pane_title}]' 2>/dev/null | grep "^  $session:" | sort; }
all()   { echo "== workers =="; workers; echo "== panes =="; panes; }

# START_ALL derives from the REGISTRY minus an explicit opt-out list (adding a worker starts it by default)
WORKER_OPTOUT=(
  claude                    # the agent pane itself, started by the bringup flow
  ui-prod                   # deliberate fallback only; ui (vite dev) is the live server
)
start_all() {
    local name skip x
    for name in "${!WORKERS[@]}"; do
        skip=""
        for x in "${WORKER_OPTOUT[@]}"; do [ "$name" = "$x" ] && skip=1 && break; done
        [ -n "$skip" ] && continue
        start "$name"
    done
}

# inject a message into the claude pane (workers call this on failure)
notify_claude() {
    local msg="[board-ops] $*" target=""
    # the board's agent: the stack's own claude window if it runs, else the pane this agent registered
    # on the board with (BOARD_TMUX_TARGET in ~/.board/config), else only the log
    if tmux list-windows -t "$session:" -F '#{window_name}' 2>/dev/null | grep -qx claude; then
        target="$session:claude"
    else
        target=$(sed -n 's/^BOARD_TMUX_TARGET=//p' "$HOME/.board/config" 2>/dev/null | tail -1)
    fi
    echo "$(date -u '+%F %T')Z ${target:-nowhere}: $msg" >> "$LOGDIR/notify.log"
    [ -n "$target" ] && tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1 || return 0
    tmux send-keys -t "$target" -l -- "$msg" && sleep 0.5 && tmux send-keys -t "$target" Enter
}

# apply the hand-written bootstrap (idempotent) and sync the JWT secret PostgREST verifies with into
# board.secret, which register()/login() sign with. They MUST match or every minted token is rejected.
apply() {
    psql "$DBURI" -q -f "$DIR/sql/bootstrap.sql" || return 1
    psql "$DBURI" -q -v secret="$PGRST_JWT_SECRET" <<'SQL'
INSERT INTO board.secret (jwt_secret) VALUES (:'secret')
ON CONFLICT (singleton) DO UPDATE SET jwt_secret = EXCLUDED.jwt_secret;
SQL
    echo "schema applied, JWT secret synced"
    [ -x "$DIR/claude-ui/sql/apply.sh" ] && (set -a; source "$DIR/.env"; set +a; "$DIR/claude-ui/sql/apply.sh")
}

# alert_once KEY MSG: notify once per failure EPISODE (an hourly retry against an
# unresolvable condition buried everything else). Repeats only if the message changes (a different
# failure mode) or after ALERT_REPEAT_HOURS. alert_clear KEY ends the episode and says so once.
alert_once() {
    local f="$LOGDIR/.alert-$1" msg="$2"
    if [ -f "$f" ] && [ "$(cat "$f")" = "$msg" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt $(( ${ALERT_REPEAT_HOURS:-24} * 3600 )) ]; then
        return 0
    fi
    printf '%s' "$msg" > "$f"
    notify_claude "$msg"
}
alert_clear() {
    local f="$LOGDIR/.alert-$1"
    [ -f "$f" ] || return 0
    rm -f "$f"
    notify_claude "$1 recovered"
}

# ---------- session lifecycle ----------
destroy() { tmux kill-session -t "$session" 2>/dev/null && echo "destroyed $session" || true; }
create()  {
    # free ports from any stray (non-tmux) instances we own
    pkill -u "$(whoami)" -f "postgrest postgrest.conf" 2>/dev/null || true
    for port in "${UI_PORT:-8110}" "${POSTGRESTPORT:-3070}"; do
        for pid in $(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
            kill "$pid" 2>/dev/null || true
        done
    done
    sleep 1
    tmux new-session -d -s "$session" -n postgrest "${WORKERS[postgrest]}; exec bash"
    tmux select-pane -t "$session:postgrest" -T postgrest
    sleep 2
}
attach()  { [ -n "$TMUX" ] && tmux switch-client -t "$session" || tmux attach -t "$session"; }
status()  { echo "session: $(tmux has-session -t "$session" 2>/dev/null && echo UP || echo DOWN)"; all; }

# ---------- entrypoint: sourced -> just helpers; executed -> full bringup ----------
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    : # sourced -- helper functions are now defined; no bringup
else
    case "${1:-up}" in
      up)
        destroy
        create
        start ui
        start push
        tnw claude; tmux send-keys -t "$session:claude" "${WORKERS[claude]}" Enter
        echo "stack up: API:${POSTGRESTPORT} UI:${UI_PORT}  (attach: tmux attach -t $session)"
        attach
        ;;
      apply)   apply ;;
      down)    destroy ;;
      status)  status ;;
      restart) destroy; sleep 2; exec "$0" up ;;
      *) echo "usage: source tmux.sh   |   ./tmux.sh [up|apply|down|status|restart]"; ;;
    esac
fi

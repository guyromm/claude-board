#!/bin/bash
# board-watch.sh -- notifier for the agent message board. Polls api.poll every BOARD_POLL seconds and
# types each new notification into this agent's Claude session with tmux send-keys. Run it through
# `board watch-start`, which wraps it in a restart loop in its own tmux window.
#
# api.poll hands out each notification exactly ONCE, so lines that cannot be delivered right now
# (pane gone, pane in copy-mode, session logged out, login in progress) are kept in
# $BOARD_HOME/pending and retried -- never dropped.
#
# It also watches the Claude session's health (reads the pane) and reports it with api.watch_sync, and
# carries out remote /login requests from the board UI: types /login, reads the sign-in URL off the
# pane for the human, types the code the human pasted into the UI, and reports success or the error.
#
# Self-upgrade: every UPGRADE_EVERY seconds it compares WATCH_VERSION with $BOARD_WEB/client/version
# and, when the board has a newer one, installs the new board + board-watch.sh and exits, so its restart
# loop (board watch-start, or the project's tmux.sh worker) starts the new version. Bump WATCH_VERSION
# here to push a change to every agent.
WATCH_VERSION=12
BOARD_HOME="${BOARD_HOME:-$HOME/.board}"
source "$BOARD_HOME/config" || { echo "no $BOARD_HOME/config"; exit 1; }
BOARD_API="${BOARD_API:-@BOARD_API@}"
BOARD_WEB="${BOARD_WEB:-@BOARD_WEB@}"
UPGRADE_EVERY="${BOARD_UPGRADE_EVERY:-300}"
POLL="${BOARD_POLL:-10}"
FAST=2                                      # poll interval while a login is in progress
PENDING="$BOARD_HOME/pending"
LOG="$BOARD_HOME/watch.log"
T="$BOARD_TMUX_TARGET"
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

# rpc FN [curl args] -> sets RPC_OUT (body) and RPC_CODE (HTTP status); returns 1 unless 2xx.
# (Globals, not stdout: a $(rpc ...) subshell would lose RPC_CODE.)
rpc() {
    local fn="$1" out; shift
    out=$(curl -sS -m 20 -X POST -H "Authorization: Bearer $(cat "$BOARD_HOME/token")" \
               -H 'Accept: text/plain, application/json' -w $'\n%{http_code}' "$@" "$BOARD_API/rpc/$fn" 2>&1)
    RPC_CODE="${out##*$'\n'}"; RPC_OUT="${out%$'\n'*}"
    [[ "$RPC_CODE" == 2* ]]
}

pane_ok() { tmux display-message -p -t "$T" '#{pane_id}' >/dev/null 2>&1; }
in_mode() { [ "$(tmux display-message -p -t "$T" '#{pane_in_mode}' 2>/dev/null)" != 0 ]; }
screen() { tmux capture-pane -p -J -t "$T" 2>/dev/null | sed 's/[[:space:]]*$//'; }

# ---------------------------------------------------------------- session health
# Claude Code prints auth failures as an assistant line, e.g. "● Login expired · Please run /login".
# Logged out = the newest "●" line on screen is such an error and no "Login successful" came after it.
# The error line is short and shaped "<problem> · <remedy>"; anchoring on that keeps an assistant reply that merely
# quotes "Please run /login" from counting.
LOGOUT_RE='^[[:space:]]*(●|⏺)[[:space:]]+[^·]{1,80}[[:space:]]·[[:space:]](Please run /login|Run /login|Sign in again)'
# first-run onboarding: the theme picker, then the login method picker (no /login needed, nor possible)
FIRSTRUN_RE='^[[:space:]]*(Choose the text style that looks best with your terminal|Select login method:)'
# Blocked = the session can't take input (and so can't get notifications) for BLOCKED_AFTER seconds:
#   needs_input  no input line: a question (AskUserQuestion), permission or other dialog waits for a human
#   no_claude    no Claude process under the pane (Claude exited; the pane's shell is all that is left).
#                By process tree, not #{pane_current_command}: a pane started as `bash -c "claude; exec bash"`
#                keeps bash as its foreground group leader, so tmux names it "bash" while Claude runs.
# detail = the bottom of the screen (the dialog's question and options), for the human to see on the board.
BLOCKED_AFTER="${BOARD_BLOCKED_AFTER:-120}"
# is a Claude process (Claude Code names its process "claude") running anywhere under process $1?
claude_under() {
    [ -n "$1" ] || return 1
    # if ps can't list processes here, say yes: a false "no Claude" would hold every notification
    ps -e -o pid=,ppid=,comm= 2>/dev/null | awk -v root="$1" '
        { par[$1] = $2; cmd[$1] = $3 }
        END { if (NR < 2) exit 0
              for (p in par) if (cmd[p] == "claude")
                  for (q = p; q != "" && q > 1; q = par[q]) if (q == root) exit 0
              exit 1 }'
}
SESSION=ok; SESSION_DETAIL=; BLOCKED_SINCE=0
check_session() {
    pane_ok || return
    local line state=ok detail= cmd
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*(●|⏺)[[:space:]] ]]; then
            if [[ "$line" =~ $LOGOUT_RE ]]; then state=logged_out; detail="${line#*[●⏺] }"; else state=ok; detail=; fi
        elif [[ "$line" == *"Login successful"* ]]; then state=ok; detail=
        fi
    done < <(screen)
    # a never-logged-in Claude (fresh install) opens on its first-run screens, not on a "Please run /login" line.
    # Only with no input line: a session merely SHOWING that text (in a tool result) still has one.
    if [ "$state" = ok ] && screen | grep -q -E "$FIRSTRUN_RE" && input_busy && [[ "$INPUT_WHY" == "no Claude input line"* ]]; then
        state=logged_out; detail="not logged in yet (Claude's first-run login screen)"
    fi
    if [ "$state" = ok ]; then
        if ! claude_under "$(tmux display-message -p -t "$T" '#{pane_pid}' 2>/dev/null)"; then
            cmd=$(tmux display-message -p -t "$T" '#{pane_current_command}' 2>/dev/null)
            state=no_claude; detail="no Claude process in the pane (it runs ${cmd:-?})"
        elif input_busy && [[ "$INPUT_WHY" == "no Claude input line"* ]]; then
            state=needs_input
            # the dialog: what follows the second-to-last horizontal rule (dialogs are drawn between rules)
            detail=$(screen | awk '{ l[NR] = $0 } /[^[:space:]]/ { n = NR } /^[[:space:]]*[─━]{10,}[[:space:]]*$/ { r2 = r1; r1 = NR }
                END { s = r2 ? r2 + 1 : n - 13; if (s < 1 || n - s > 30) s = n - 13; if (s < 1) s = 1
                      for (i = s; i <= n; i++) if (l[i] !~ /^[[:space:]]*$/ && l[i] !~ /^[[:space:]]*[─━]+[[:space:]]*$/) print l[i] }' \
                     | sed -E 's/^[[:space:]│]+//; s/[[:space:]│]+$//' | awk 'NR > 1 { printf " / " } { printf "%s", $0 }')
        fi
        if [ "$state" != ok ]; then
            # debounced: a dialog someone is answering right now, or a restarting claude, is not "blocked"
            [ "$BLOCKED_SINCE" = 0 ] && BLOCKED_SINCE=$(now)
            if [ $(( $(now) - BLOCKED_SINCE )) -lt "$BLOCKED_AFTER" ]; then state=ok; detail=; fi
        else
            BLOCKED_SINCE=0
        fi
    else
        BLOCKED_SINCE=0
    fi
    if [ "$state" != "$SESSION" ]; then log "session: $SESSION -> $state ${detail:+($detail)}"; fi
    SESSION=$state; SESSION_DETAIL=$detail
}

# ---------------------------------------------------------------- notification delivery
# Is someone using the Claude input line? Claude Code draws it as "❯" (or "!" in shell mode) + NBSP + the
# text; an EMPTY input shows a dim placeholder ("Try ..."). Typing into a half-written line would append to
# it and submit it, so delivery waits. No input line at all (a permission or other dialog is up) also
# waits: keystrokes would answer the dialog.
INPUT_WHY=
# A selection dialog (AskUserQuestion, permission prompt) marks its current option with the same "❯"+NBSP
# as the input line ("❯ 1. Posts only"), so the line alone can't tell them apart: a numbered option behind
# the marker, or the dialog's footer near the bottom, means a dialog is up and there is no input line.
dialog_open() {
    screen | awk '{ l[NR] = $0 } /[^[:space:]]/ { n = NR } END { for (i = (n > 25 ? n - 24 : 1); i <= n; i++) print l[i] }' \
        | grep -a -q -E $'^[[:space:]]*❯(\xc2\xa0|[[:space:]])+[0-9]+\\.[[:space:]]|^[[:space:]]*Enter to select ·'
}
input_busy() {
    local line pre rest codes text
    if dialog_open; then INPUT_WHY="no Claude input line visible (dialog open)"; return 0; fi
    line=$(tmux capture-pane -p -e -t "$T" 2>/dev/null | grep -a -E $'^(\e\\[[0-9;]*m)*[[:space:]]*(❯|!)\xc2\xa0' | tail -n 1)
    if [ -z "$line" ]; then INPUT_WHY="no Claude input line visible (dialog open?)"; return 0; fi
    pre="${line%%$'\xc2\xa0'*}"; rest="${line#*$'\xc2\xa0'}"
    if [[ "$pre" == *'!' ]]; then INPUT_WHY="input line is in shell (!) mode"; return 0; fi
    local sgr=$'\e''\[[0-9;]*m'
    # the styles around the first character: the cursor can sit on it in inverse video ("\e[7ma\e[27m\e[2msk..."),
    # so a dim placeholder or prompt suggestion may only turn dim after it
    [[ "$rest" =~ ^(($sgr)*)(.)?(($sgr)*) ]]
    codes="${BASH_REMATCH[1]}${BASH_REMATCH[4]}"; text=$(sed -E $'s/\e\\[[0-9;]*m//g; s/[[:space:]]+$//' <<<"$rest")
    [ -z "$text" ] && return 1
    [[ "$codes" =~ \[(2|[0-9\;]*\;2)[\;m] ]] && return 1        # SGR 2 (dim) = the placeholder or a suggestion
    INPUT_WHY="someone is typing in the input line (styles: $(sed -E $'s/\e\\[([0-9;]*)m/<\\1>/g' <<<"$codes"))"; return 0
}

HELD_SINCE=0
deliver() {
    local text
    [ -s "$PENDING" ] || return 0
    if ! pane_ok; then log "target pane $T not found; holding $(wc -l < "$PENDING") notification(s)"; return 1; fi
    # copy-mode would swallow the keystrokes as navigation commands
    if in_mode; then log "target pane in copy-mode; retrying later"; return 1; fi
    # a logged-out session would only answer "Please run /login"; a login dialog must not get typed into
    [ "$SESSION" = ok ] && [ -z "$L_ID" ] || return 1
    if input_busy; then
        [ "$HELD_SINCE" = 0 ] && { HELD_SINCE=$(now); log "holding delivery: $INPUT_WHY"; }
        [ $(( $(now) - HELD_SINCE )) -ge 900 ] && { log "still holding after 15 min: $INPUT_WHY"; HELD_SINCE=$(now); }
        return 1
    fi
    HELD_SINCE=0
    # one submission per poll: Claude Code queues it if it is mid-turn
    text=$(awk 'NR > 1 { printf "  ||  " } { printf "%s", $0 }' "$PENDING")
    tmux send-keys -t "$T" -l -- "$text" && sleep 0.5 && tmux send-keys -t "$T" Enter \
        && { log "delivered: $text"; : > "$PENDING"; }
}

# ---------------------------------------------------------------- remote /login
L_ID=; L_T0=0; L_URL=; L_CAND=; L_PICK=0; L_GONE=0; L_SENT_STATE=; L_REJECT=
now() { date +%s; }

# the part of the screen after the newest "/login" command echo (older output may hold stale text)
login_screen() {
    screen | awk '/(^|[>❯›][[:space:]]*)\/login[[:space:]]*$/ { buf = ""; next } { buf = buf $0 "\n" } END { printf "%s", buf }'
}
# the sign-in URL as Claude Code shows it: one line starting https://, hard-wrapped over the next lines
extract_url() {
    awk 'u == "" { if (match($0, /https:\/\/[^ ]*(oauth|authorize)[^ ]*/)) { u = substr($0, RSTART, RLENGTH); next } }
         u != "" { s = $0; sub(/^[ \t│|]+/, "", s); sub(/[ \t│|]+$/, "", s); if (s ~ /^[A-Za-z0-9%._~:\/?#\[\]@!$&'"'"'()*+,;=-]+$/) { u = u s } else { print u; u = ""; exit } }
         END { if (u != "") print u }'
}
progress() {  # STATE MESSAGE [URL] [PANE_TAIL]
    local args=(--data-urlencode "id=$L_ID" --data-urlencode "state=$1" --data-urlencode "message=$2") r
    [ -n "$3" ] && args+=(--data-urlencode "url=$3")
    [ -n "$4" ] && args+=(--data-urlencode "pane_tail=$4")
    rpc login_progress "${args[@]}" || { log "login #$L_ID: progress $1 failed ($RPC_CODE): $RPC_OUT"; return 1; }
    r=$RPC_OUT
    log "login #$L_ID: $1 -- $2"
    L_SENT_STATE=$1
    if [[ "$r" == closed:* ]]; then log "login #$L_ID was ${r#closed:} on the board; stopping"; login_abort; fi
}
login_abort() {  # close the dialog in the session (ONE Esc: a second one would reach the prompt) and forget the request
    [ -n "$L_ID" ] && [ -n "$L_SENT_STATE" ] && pane_ok && tmux send-keys -t "$T" Escape
    L_ID=; L_URL=; L_CAND=; L_SENT_STATE=
}
login_fail() {  # MESSAGE
    progress failed "$1" "" "$(screen | tail -n 30)"
    login_abort
}

# drive one step of login request ID in server state STATE (CODE only when state = code_submitted)
login_step() {
    local id="$1" state="$2" code="$3" scr url err t
    t=$(now)
    if [ "$id" != "$L_ID" ]; then
        [ -n "$L_ID" ] && login_abort
        L_ID=$id; L_T0=$t; L_URL=; L_CAND=; L_PICK=0; L_GONE=0; L_SENT_STATE=; L_REJECT=
        log "login #$id: new request ($state)"
    fi
    if ! pane_ok; then login_fail "the Claude pane $T does not exist"; return; fi
    in_mode && tmux send-keys -t "$T" -X cancel

    case "$state" in
    requested)
        L_T0=$t
        if screen | grep -q -E "$FIRSTRUN_RE"; then
            # first run: the login picker is (about to be) on screen already; the started step answers it
            progress started "first-run login screen in $T; waiting for the sign-in URL"
        else
            tmux send-keys -t "$T" -l -- "/login" && sleep 0.4 && tmux send-keys -t "$T" Enter
            progress started "typed /login into $T; waiting for the sign-in URL"
        fi
        ;;
    started|url_ready|code_rejected)
        scr=$(login_screen)
        if [[ "$scr" == *"Login successful"* ]]; then
            tmux send-keys -t "$T" Enter; progress succeeded "Claude Code reports: Login successful"; login_done; return
        fi
        url=$(printf '%s\n' "$scr" | extract_url)
        if [[ "$url" == *code_challenge=*state=* || "$url" == *state=*code_challenge=* ]]; then
            L_GONE=0
            # report once the URL is stable across two reads (the screen may still be rendering)
            if [ "$url" = "$L_CAND" ] && [ "$url" != "$L_URL" ]; then
                L_URL=$url
                if [ -n "$L_REJECT" ]; then
                    progress url_ready "$L_REJECT -- this is a NEW link (the old one is dead): open it, authorize, paste the new code" "$url"
                else
                    progress url_ready "open the link, authorize, then paste the code shown by claude.ai" "$url"
                fi
            fi
            L_CAND=$url
        elif [[ "$scr" == *"Select login method"* || "$scr" == *"Choose the text style"* ]]; then
            # (the theme picker comes first on a fresh install: Enter keeps its default too)
            # first option = "Claude account with subscription" (the default)
            if [ $((t - L_PICK)) -ge 3 ]; then tmux send-keys -t "$T" Enter; L_PICK=$t; log "login #$id: picked the default login method"; fi
        elif [[ "$scr" == *"Press Enter to retry"* || "$scr" == *"to retry."* ]]; then
            [ $((t - L_PICK)) -ge 3 ] && { tmux send-keys -t "$T" Enter; L_PICK=$t; }
        elif [ "$state" != started ]; then
            # we showed a URL before and now there is none: the dialog was closed in the session
            L_GONE=$((L_GONE + 1))
            [ "$L_GONE" -ge 3 ] && { login_fail "the login dialog disappeared from the session (closed with Esc?)"; return; }
        fi
        if [ "$state" = started ] && [ $((t - L_T0)) -gt 90 ]; then
            login_fail "no sign-in URL appeared within 90s of typing /login"
        fi
        ;;
    code_submitted)
        scr=$(login_screen)
        if [[ "$scr" != *"Paste code here"* && -z "$(printf '%s\n' "$scr" | extract_url)" ]]; then
            login_fail "the session is no longer waiting for a code (login dialog closed)"; return
        fi
        tmux send-keys -t "$T" -l -- "$code" && sleep 0.4 && tmux send-keys -t "$T" Enter
        L_T0=$t
        progress code_entered "code typed in; waiting for Claude Code to confirm"
        ;;
    code_entered)
        scr=$(login_screen)
        if [[ "$scr" == *"Login successful"* ]]; then
            sleep 0.5; tmux send-keys -t "$T" Enter    # "Press Enter to continue"
            progress succeeded "Claude Code reports: Login successful"
            login_done
        elif err=$(printf '%s\n' "$scr" | grep -E -m1 'Invalid code|OAuth error|OAuth login failed|Login failed|[Ee]rror:' ) && [ -n "$err" ]; then
            err=$(sed -E 's/^[[:space:]]*[^[:alnum:]]*//' <<<"$err")
            tmux send-keys -t "$T" Enter                # "Press Enter to retry" -> back to the method picker -> new URL
            L_URL=; L_CAND=; L_T0=$t; L_REJECT="Claude Code rejected the code ($err)"
            progress code_rejected "$L_REJECT -- getting a new sign-in link"
        elif [ $((t - L_T0)) -gt 60 ]; then
            login_fail "Claude Code did not confirm the login within 60s of typing the code"
        fi
        ;;
    esac
}
login_done() {
    SESSION=ok; SESSION_DETAIL=
    echo "[board] this Claude session was logged out and has been logged back in from the board. Messages that arrived meanwhile: board inbox" >> "$PENDING"
    L_ID=; L_URL=; L_CAND=; L_SENT_STATE=
}

# ---------------------------------------------------------------- self-upgrade
L_UPCHECK=0
check_upgrade() {
    local t v f bin="$BOARD_HOME/bin"
    t=$(now); [ $((t - L_UPCHECK)) -ge "$UPGRADE_EVERY" ] || return 0
    L_UPCHECK=$t
    [ -z "$L_ID" ] || return 0                 # never in the middle of a login
    v=$(curl -fsS -m 10 "$BOARD_WEB/client/version" 2>/dev/null) || return 0
    [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt "$WATCH_VERSION" ] || return 0
    for f in board board-watch.sh; do
        if ! curl -fsS -m 30 "$BOARD_WEB/client/$f" -o "$bin/$f.new" || ! bash -n "$bin/$f.new"; then
            log "upgrade to v$v failed (download/syntax of $f); staying on v$WATCH_VERSION"; rm -f "$bin"/*.new; return 0
        fi
    done
    for f in board board-watch.sh; do chmod +x "$bin/$f.new" && mv "$bin/$f.new" "$bin/$f"; done
    log "upgraded v$WATCH_VERSION -> v$v; exiting so the restart loop starts the new version"
    exit 0
}

# ---------------------------------------------------------------- main loop
log "watching as ${BOARD_HANDLE:-?} -> $T (every ${POLL}s, $BOARD_API, watcher v$WATCH_VERSION)"
fails=0
while true; do
    rpc poll; out=$RPC_OUT
    if [ "$RPC_CODE" = 200 ]; then
        fails=0
        [ -n "$out" ] && printf '%s\n' "$out" >> "$PENDING"
    else
        fails=$((fails + 1))
        [ $((fails % 30)) = 1 ] && log "poll failed (http $RPC_CODE): $out"
        # a revoked token is permanent: tell the agent once instead of failing silently forever
        if [ "$RPC_CODE" = 401 ] || [[ "$out" == *"token revoked"* ]]; then
            echo "[board] the board rejected this agent's token ($out). Ask the human for a new one; then restart: board watch-start" >> "$PENDING"
            deliver; log "token rejected; idling (restart with: board watch-start)"
            while true; do sleep 3600; done   # do not exit: the restart loop would re-notify every 5s
        fi
    fi

    [ -z "$L_ID" ] && check_session
    task=
    rpc watch_sync --data-urlencode "session_state=$SESSION" --data-urlencode "session_detail=$SESSION_DETAIL" \
        --data-urlencode "version=$WATCH_VERSION" && task=$RPC_OUT
    if [[ "$task" == login$'\t'* ]]; then
        IFS=$'\t' read -r _ lid lstate lcode <<<"$task"
        login_step "$lid" "$lstate" "$lcode"
    elif [ -n "$L_ID" ] && [ "$RPC_CODE" = 200 ]; then
        log "login #$L_ID is no longer active on the board (cancelled or expired)"; login_abort
    fi

    deliver
    check_upgrade
    if [ -n "$L_ID" ]; then sleep "$FAST"; else sleep "$POLL"; fi
done

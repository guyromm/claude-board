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
# Hourly it also reports the Claude session's activity (active minutes + the tasks/threads it mentioned, read off
# its transcripts) with api.activity_push: the board's /load page.
#
# Self-upgrade: every UPGRADE_EVERY seconds it compares WATCH_VERSION with $BOARD_WEB/client/version
# and, when the board has a newer one, installs the new board + board-watch.sh and exits, so its restart
# loop (board watch-start, or the project's tmux.sh worker) starts the new version. Bump WATCH_VERSION
# here to push a change to every agent.
WATCH_VERSION=24  # v24: answers "Try the new fullscreen renderer?" with "Yes, try it"
# v23: types /restart when Claude Code shows "Update installed · /restart to apply" and the session is idle (Remote Control: off for the restart, back on after)
# v22: a draft left in the input line holds delivery at most 10 min, then it is set aside and typed back
# v21: board review submit --base EMPTY / unborn base (first commits)
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
# BOARD_TMUX_TARGET usually names a window ("proj:claude"), which tmux resolves to that window's ACTIVE pane:
# once a human splits the window and works in the new pane, that is their shell (ofana, 11-04: notifications
# nearly went into a `git add -p` prompt). So every poll T becomes the window's pane that runs Claude (the
# active pane if none does). A pane id (%23) or an explicit pane (proj:claude.1) is used as given.
resolve_target() {
    if [[ "$BOARD_TMUX_TARGET" == %* || "$BOARD_TMUX_TARGET" =~ \.[0-9]+$ ]]; then T="$BOARD_TMUX_TARGET"; return; fi
    local id pid
    T="$BOARD_TMUX_TARGET"
    while read -r id pid; do
        if claude_under "$pid"; then T="$id"; return; fi
    done < <(tmux list-panes -t "$BOARD_TMUX_TARGET" -F '#{pane_id} #{pane_pid}' 2>/dev/null)
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

# A draft someone left in the input line holds delivery for at most DRAFT_GRACE seconds of no change
# (guy, 11-16: a few stale letters in auth's input held its notifications for over an hour). Then the draft
# is set aside (cleared line by line: Ctrl+E Ctrl+U, Backspace joins the line above), the notification is
# delivered, and the draft is typed back exactly (multi-line with backslash+Enter), so nothing is lost.
# The draft text is also logged. A dialog or shell (!) mode is never touched: those keep holding.
DRAFT_GRACE="${BOARD_DRAFT_GRACE:-600}"
# the draft's lines: the "❯ " line and its continuation lines down to the box's bottom rule
draft_lines() {
    tmux capture-pane -p -J -t "$T" 2>/dev/null | awk -v p="^[[:space:]]*❯"$'\xc2\xa0' '
        $0 ~ p { n = 0; inbox = 1; sub(p, ""); d[++n] = $0; next }
        inbox && /^[[:space:]]*[─━]{10,}[[:space:]]*$/ { inbox = 0; m = n; next }
        inbox { sub(/^  /, ""); d[++n] = $0 }
        END { if (inbox) m = n; for (i = 1; i <= m; i++) { sub(/[[:space:]]+$/, "", d[i]); print d[i] } }'
}
# empty the input line; 0 = it is empty now
clear_input() {
    local i
    for i in $(seq 1 40); do
        tmux send-keys -t "$T" C-e C-u; sleep 0.3
        input_busy || return 0
        [[ "$INPUT_WHY" == "someone is typing"* ]] || return 1
        tmux send-keys -t "$T" BSpace; sleep 0.2
    done
    return 1
}
# type the set-aside draft back into an EMPTY input line (never into a dialog); 0 = done or nothing to do
restore_draft() {
    [ -n "$STASH" ] || return 0
    input_busy && return 1
    local first=1 l
    while IFS= read -r l; do
        [ $first = 1 ] || { tmux send-keys -t "$T" -l -- '\'; tmux send-keys -t "$T" Enter; }
        first=0
        tmux send-keys -t "$T" -l -- "$l"
    done <<<"$STASH"
    log "draft typed back into the input line"
    STASH=
}
HELD_SINCE=0 HELD_DRAFT= STASH=
deliver() {
    local text d
    restore_draft || return 1
    [ -s "$PENDING" ] || return 0
    if ! pane_ok; then log "target pane $T not found; holding $(wc -l < "$PENDING") notification(s)"; return 1; fi
    # copy-mode would swallow the keystrokes as navigation commands
    if in_mode; then log "target pane in copy-mode; retrying later"; return 1; fi
    # a logged-out session would only answer "Please run /login"; a login dialog must not get typed into
    [ "$SESSION" = ok ] && [ -z "$L_ID" ] || return 1
    if input_busy; then
        if [[ "$INPUT_WHY" == "someone is typing"* ]]; then
            d=$(draft_lines)
            # the clock restarts whenever the draft changes: someone is still typing
            [ "$d" != "$HELD_DRAFT" ] && { HELD_DRAFT=$d; HELD_SINCE=0; }
        fi
        [ "$HELD_SINCE" = 0 ] && { HELD_SINCE=$(now); log "holding delivery: $INPUT_WHY"; }
        if [[ "$INPUT_WHY" == "someone is typing"* ]] && [ $(( $(now) - HELD_SINCE )) -ge "$DRAFT_GRACE" ]; then
            log "draft unchanged for ${DRAFT_GRACE}s; setting it aside to deliver, then typing it back: $(printf '%s' "$HELD_DRAFT" | awk 'NR > 1 { printf " \\n " } { printf "%s", $0 }')"
            if ! clear_input; then log "could not clear the draft ($INPUT_WHY); still holding"; HELD_SINCE=$(now); return 1; fi
            STASH=$HELD_DRAFT
        else
            [ $(( $(now) - HELD_SINCE )) -ge 900 ] && { log "still holding after 15 min: $INPUT_WHY"; HELD_SINCE=$(now); }
            return 1
        fi
    fi
    HELD_SINCE=0 HELD_DRAFT=
    # one submission per poll: Claude Code queues it if it is mid-turn
    text=$(awk 'NR > 1 { printf "  ||  " } { printf "%s", $0 }' "$PENDING")
    tmux send-keys -t "$T" -l -- "$text" && sleep 0.5 && tmux send-keys -t "$T" Enter \
        && { log "delivered: $text"; : > "$PENDING"; }
    [ -n "$STASH" ] && { sleep 1; restore_draft; }
    return 0
}

# ---------------------------------------------------------------- Claude Code self-update (guy, 11-16)
# Claude Code installs updates in the background and then shows "✔ Update installed · /restart to apply" just
# above the input box. /restart resumes the same conversation ("Session resumed"), so the watcher types it when
# the session is idle: nothing pending, input line empty, no dialog, no turn running ("esc to interrupt").
# Remote Control blocks /restart ("Can't restart while Remote Control is connected"): then /rc -> "Disconnect this
# session", /restart, and /rc -> "Enable Remote Control" again, so the phone/web link comes back (a new link).
# Anything unexpected on screen: one Esc and give up until the next attempt (at most every RESTART_RETRY s).
RESTART_RETRY="${BOARD_RESTART_RETRY:-1800}"; RESTART_TRIED=0
# the last N NON-BLANK lines of the screen (Claude Code pads the space between the output and the input box)
tail_screen() { screen | grep -a -v '^[[:space:]]*$' | tail -n "${1:-12}"; }
type_cmd() { tmux send-keys -t "$T" -l -- "$1" && sleep 0.5 && tmux send-keys -t "$T" Enter; }
# pick the menu option whose text matches $1 (moving the ❯ marker with Up/Down), then Enter; 1 = not found
pick_option() {
    local i
    # only inside a menu: Up on the bare input line would recall history into it
    tail_screen 16 | grep -a -q -E 'Enter to (select|confirm)' || return 1
    for i in 1 2 3 4 5 6; do
        tail_screen 14 | grep -a -q -E "❯.{0,12}$1" && { tmux send-keys -t "$T" Enter; return 0; }
        tmux send-keys -t "$T" Up; sleep 0.3
    done
    return 1
}
maybe_restart() {
    local rc=0
    [ "$SESSION" = ok ] && [ -z "$L_ID" ] && [ ! -s "$PENDING" ] || return 0
    tail_screen 8 | grep -a -q 'Update installed' && tail_screen 8 | grep -a -q '/restart to apply' || return 0
    [ $(( $(now) - RESTART_TRIED )) -ge "$RESTART_RETRY" ] || return 0
    in_mode && return 0
    tail_screen 4 | grep -a -q 'esc to interrupt' && return 0     # a turn is running
    input_busy && return 0                                         # a draft, a dialog or ! mode
    RESTART_TRIED=$(now)
    log "Claude Code update installed; typing /restart"
    type_cmd "/restart"; sleep 6
    if tail_screen 12 | grep -a -q 'restart while Remote Control is connected'; then
        log "Remote Control is connected: disconnecting it for the restart (/rc), re-enabling after"
        type_cmd "/rc"; sleep 3
        if ! pick_option 'Disconnect this session'; then log "no 'Disconnect this session' option; giving up"; tmux send-keys -t "$T" Escape; return 0; fi
        sleep 4; rc=1
        type_cmd "/restart"; sleep 8
    fi
    if tail_screen 14 | grep -a -q 'Session resumed'; then log "restarted on the installed version (session resumed)"
    else log "no 'Session resumed' after /restart; will retry in ${RESTART_RETRY}s"; fi
    if [ "$rc" = 1 ]; then
        type_cmd "/rc"; sleep 4
        # a session that had it before reconnects at once; otherwise the menu offers "Enable Remote Control"
        if tail_screen 6 | grep -a -q 'remote-control is active'; then log "Remote Control re-enabled"
        elif pick_option 'Enable Remote Control'; then sleep 6; log "Remote Control re-enabled"
        else log "could not re-enable Remote Control (no option on screen)"; tail_screen 16 | grep -a -q 'Enter to select' && tmux send-keys -t "$T" Escape; fi
    fi
}
# Known Claude Code prompts with a standing answer (guy, 11-16), answered so they don't hold notifications:
#   "Try the new fullscreen renderer?" -> "Yes, try it"
answer_known_dialogs() {
    [ -z "$L_ID" ] || return 0
    if tail_screen 12 | grep -a -q 'Try the new fullscreen renderer?'; then
        if pick_option 'Yes, try it'; then log "answered 'Try the new fullscreen renderer?' with 'Yes, try it'"; sleep 3
        else log "fullscreen renderer prompt seen but no 'Yes, try it' option"; fi
    fi
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

# ---------------------------------------------------------------- model + Claude Code version
# Read off the session's transcript: Claude Code writes ~/.claude/projects/<cwd, non-alphanumerics as "-">/<session>.jsonl,
# where each line carries "version":"<Claude Code version>" and each assistant reply "model":"<model id>".
# The newest transcript of the Claude process's working directory = the running session. Every INFO_EVERY seconds.
INFO_EVERY="${BOARD_INFO_EVERY:-300}"
CLAUDE_MODEL=; CLAUDE_VERSION=; L_INFO=0
claude_pid() {  # the first Claude process under process $1
    [ -n "$1" ] || return 1
    ps -e -o pid=,ppid=,comm= 2>/dev/null | awk -v root="$1" '
        { par[$1] = $2; cmd[$1] = $3 }
        END { for (p in par) if (cmd[p] == "claude")
                  for (q = p; q != "" && q > 1; q = par[q]) if (q == root) { print p; exit 0 }
              exit 1 }'
}
# the transcript directory of the session's Claude process (its cwd, non-alphanumerics as "-")
claude_dir() {
    local pid cwd
    pid=$(claude_pid "$(tmux display-message -p -t "$T" '#{pane_pid}' 2>/dev/null)") || return 1
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    [ -n "$cwd" ] || cwd=$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
    [ -n "$cwd" ] || return 1
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
}
check_info() {
    local t dir f tail_
    t=$(now); [ $((t - L_INFO)) -ge "$INFO_EVERY" ] || return 0
    L_INFO=$t
    dir=$(claude_dir) || return 0
    f=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -n 1); [ -n "$f" ] || return 0
    tail_=$(tail -c 1000000 "$f" 2>/dev/null | grep -v '"isSidechain":true')     # not subagents' replies
    CLAUDE_MODEL=$(grep -o '"model":"claude-[^"]*"' <<<"$tail_" | tail -n 1 | cut -d'"' -f4)
    CLAUDE_VERSION=$(grep -o '"version":"[0-9][^"]*"' <<<"$tail_" | tail -n 1 | cut -d'"' -f4)
}

# ---------------------------------------------------------------- Claude activity (hourly, incremental)
# Which minutes the Claude session was active, and which board objects (tasks, threads) it mentioned in them, read
# off its transcripts: ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<the Claude process's cwd>/**/*.jsonl (its sessions and
# their subagents). Only that directory: several agents can share one unix user (caladan), each in its own directory.
# While Claude isn't running, the directory found last time ($BOARD_HOME/activity.dir) is read.
# Every ACTIVITY_EVERY seconds, in the background (a first run reads up to ACTIVITY_DAYS of history), it reads what
# was appended since the last run ($BOARD_HOME/activity2.state: file, bytes read, last entry's time and kind), turns it
# into "<minute>\t<entries>\t<refs>" lines with ACTIVITY_AWK and pushes them to api.activity_push. The board derives
# the periods of activity and the load per task from them (the /load page).
ACTIVITY_EVERY="${BOARD_ACTIVITY_EVERY:-3600}"
ACTIVITY_DAYS="${BOARD_ACTIVITY_DAYS:-60}"
L_ACTIVITY=$(( $(date +%s) - ACTIVITY_EVERY + 120 ))   # first run 2 minutes after start
ACTIVITY_AWK='
function epoch(t,   y, m, d, H, M, S, era, yoe, doy, doe) {
    y = substr(t, 1, 4) + 0; m = substr(t, 6, 2) + 0; d = substr(t, 9, 2) + 0
    H = substr(t, 12, 2) + 0; M = substr(t, 15, 2) + 0; S = substr(t, 18, 2) + 0
    if (m <= 2) y--
    era = int(y / 400); yoe = y - era * 400
    doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return ((era * 146097 + doe - 719468) * 86400) + H * 3600 + M * 60 + S
}
function mark(mn) { if (!(mn in cnt)) { cnt[mn] = 0; order[++nm] = mn } }
function add(mn, r) { if (!((mn, r) in seen)) { seen[mn, r] = 1; tok[mn] = tok[mn] " " r } }
function grab(s, re, kind,   v, pre, nxt, p) {
    while (match(s, re)) {
        v = substr(s, RSTART, RLENGTH); pre = RSTART > 1 ? substr(s, RSTART - 1, 1) : ""
        p = RSTART > 2 ? substr(s, RSTART - 2, 2) : ""
        nxt = substr(s, RSTART + RLENGTH, 1)
        s = substr(s, RSTART + RLENGTH)
        if (kind == "hash") {
            if ((pre ~ /[A-Za-z0-9_&]/ && p !~ /\\[nt]/) || nxt ~ /[A-Za-z_]/) continue
            sub(/^#/, "", v)
            if (v ~ /\//) { sub(/\/$/, "", v); L[++nl] = "p:" v } else if (length(v) <= 6) L[++nl] = "n:" v
        } else if (kind == "path") { sub(/^tasks\//, "", v); L[++nl] = "p:" v }
        else { sub(/^[^0-9]*/, "", v); L[++nl] = kind ":" v }
    }
}
BEGIN { if (gap == "") gap = 120; if (maxbusy == "") maxbusy = 3600; pe += 0 }
/^\{"type":"api-request/ { next }
{
    if (!match($0, /"uuid":"[^"]*","timestamp":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) next
    e = epoch(substr($0, RSTART + RLENGTH - 19, 19))
    if (index($0, "\"type\":\"assistant\",\"uuid\"")) k = index($0, "\"type\":\"tool_use\"") ? "a" : "e"
    else if (index($0, "\"type\":\"user\"")) k = index($0, "\"tool_use_id\":") ? "r" : "u"
    else k = "s"
    mn = int(e / 60) * 60
    if (pe > 0 && e > pe && (e - pe <= gap || (pk != "e" && e - pe <= maxbusy)))
        for (x = int(pe / 60) * 60; x < mn; x += 60) mark(x)
    mark(mn); cnt[mn]++
    if (pe == 0 || e >= pe) pe = e
    if (k != "s") pk = k
    if (k == "a" || k == "e" || k == "u") {
        s = $0; gsub(/"signature":"[^"]*"/, "", s)
        nl = 0
        grab(s, "#[1-9][0-9]*(\\/[0-9]+)*\\/?", "hash")
        grab(s, "tasks\\/[0-9]+(\\/[0-9]+)*", "path")
        grab(s, "\\/m\\/[0-9]+", "m")
        grab(s, "board task (note |update |link )?[0-9]+", "t")
        grab(s, "--(task|parent) [0-9]+", "t")
        grab(s, "board (read|reply|thread|summarize) [0-9]+", "m")
        if (nl <= 12) for (i = 1; i <= nl; i++) add(mn, L[i])
        if (k == "u") {
            # who drove it: a human writing through claude-ui ("[from guy] ..."), or the watcher ("[board] ...",
            # possibly inside a pasted block)
            if (match(s, /\[from [A-Za-z0-9_.-]+\]/)) {
                v = substr(s, RSTART, RLENGTH); sub(/^\[from /, "", v); sub(/\]$/, "", v); add(mn, "u:" v)
            } else if (index(s, "[board] ")) add(mn, "u:board")
        }
    }
}
END {
    for (i = 1; i <= nm; i++) { mn = order[i]; t = tok[mn]; sub(/^ /, "", t); printf "%d\t%d\t%s\n", mn, cnt[mn], t }
    if (st != "") printf "%d\t%s\n", pe, pk > st
}'
# one pass over every transcript; the state is only advanced once the push went through
activity_run() {
    local root="$1" st="$BOARD_HOME/activity2.state" w="$BOARD_HOME/activity.tmp"
    local f size off pe pk n part used fails=0 c
    [ -n "$root" ] && [ -d "$root" ] || return 0
    mkdir -p "$w" && rm -f "$w"/*
    : > "$w/state"; : > "$w/out"
    while IFS= read -r f; do
        size=$(wc -c < "$f" 2>/dev/null) || continue
        IFS=$'\t' read -r _ off pe pk < <(awk -F'\t' -v f="$f" '$1 == f' "$st" 2>/dev/null) || true
        off=${off:-0}; pe=${pe:-0}
        [ "$size" -lt "$off" ] && { off=0; pe=0; pk=; }      # rewritten from scratch
        if [ "$size" -gt "$off" ]; then
            # only whole lines: the session may be writing the last one right now
            tail -c +"$((off + 1))" "$f" 2>/dev/null | head -c "$((size - off))" > "$w/chunk"
            used=$(wc -c < "$w/chunk")
            if [ "$used" -gt 0 ] && [ "$(tail -c 1 "$w/chunk" | od -An -c | tr -d ' ')" != '\n' ]; then
                part=$(tail -n 1 "$w/chunk" | wc -c); used=$((used - part + 1))
                [ "$used" -lt 0 ] && used=0
                head -c "$used" "$w/chunk" > "$w/chunk2" && mv "$w/chunk2" "$w/chunk"
            fi
            : > "$w/st1"
            awk -v pe="$pe" -v pk="$pk" -v st="$w/st1" "$ACTIVITY_AWK" "$w/chunk" >> "$w/out"
            IFS=$'\t' read -r pe pk < "$w/st1" 2>/dev/null
            off=$((off + used))
        fi
        printf '%s\t%s\t%s\t%s\n' "$f" "$off" "${pe:-0}" "$pk" >> "$w/state"
    done < <(find "$root" -name '*.jsonl' -mtime "-$ACTIVITY_DAYS" 2>/dev/null)
    n=$(wc -l < "$w/out")
    if [ "$n" -gt 0 ]; then
        split -l 3000 "$w/out" "$w/push."
        for c in "$w"/push.*; do
            rpc activity_push --data-urlencode "data@$c" || { fails=1; log "activity: push failed ($RPC_CODE): $RPC_OUT"; break; }
        done
    fi
    if [ "$fails" = 0 ]; then
        mv "$w/state" "$st"
        [ "$n" -gt 0 ] && log "activity: pushed $n active minute(s)"
    fi
    rm -rf "$w"
}
check_activity() {
    local t pid dir
    t=$(now); [ $((t - L_ACTIVITY)) -ge "$ACTIVITY_EVERY" ] || return 0
    L_ACTIVITY=$t
    pid=$(cat "$BOARD_HOME/activity.pid" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0      # the last run is still going
    dir=$(claude_dir) && [ -n "$dir" ] && printf '%s\n' "$dir" > "$BOARD_HOME/activity.dir"
    dir=$(cat "$BOARD_HOME/activity.dir" 2>/dev/null)
    [ -n "$dir" ] || return 0
    ( activity_run "$dir" ) </dev/null >/dev/null 2>&1 &
    echo $! > "$BOARD_HOME/activity.pid"
}

# ---------------------------------------------------------------- main loop
log "watching as ${BOARD_HANDLE:-?} -> $T (every ${POLL}s, $BOARD_API, watcher v$WATCH_VERSION)"
fails=0
while true; do
    resolve_target
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

    [ -z "$L_ID" ] && { check_session; check_info; check_activity; }
    task=
    rpc watch_sync --data-urlencode "session_state=$SESSION" --data-urlencode "session_detail=$SESSION_DETAIL" \
        --data-urlencode "version=$WATCH_VERSION" --data-urlencode "model=$CLAUDE_MODEL" \
        --data-urlencode "claude_version=$CLAUDE_VERSION" && task=$RPC_OUT
    if [[ "$task" == login$'\t'* ]]; then
        IFS=$'\t' read -r _ lid lstate lcode <<<"$task"
        login_step "$lid" "$lstate" "$lcode"
    elif [ -n "$L_ID" ] && [ "$RPC_CODE" = 200 ]; then
        log "login #$L_ID is no longer active on the board (cancelled or expired)"; login_abort
    fi

    answer_known_dialogs
    deliver
    maybe_restart
    check_upgrade
    if [ -n "$L_ID" ]; then sleep "$FAST"; else sleep "$POLL"; fi
done

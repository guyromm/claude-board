#!/usr/bin/env bash
# Idle-agent nudge watcher (guy, 2026-11-12, #119/23): nudge agents that look idle but
# have open, actionable work on them, so guy doesn't have to wake them by hand.
#
# "Idle" = no session output (board.activity_minute) AND no board message sent AND none
# received, for >= THRESH_MIN. A nudge is suppressed if board nudged the agent within
# COOLDOWN_MIN. The nudge lists the agent's open todo/doing tasks (not needs_human) with
# links and invites "scheduled later / blocked / busy on my own product" replies.
#
# DRY_RUN=1 prints who it WOULD nudge and the message, and posts nothing.
set -euo pipefail
cd "$(dirname "$0")"
U="$(grep ^DBURI .env | cut -d= -f2-)"
THRESH_MIN="${THRESH_MIN:-20}"
COOLDOWN_MIN="${COOLDOWN_MIN:-90}"
REPLIED_H="${REPLIED_H:-6}"
DRY_RUN="${DRY_RUN:-0}"
BOARD="https://board.webgma.co.il"

idle_agents() {
  psql -X -At "$U" <<SQL
with act as (select handle, max(minute) last_min from board.activity_minute group by handle),
 sent as (select sender handle, max(created_at) t from board.message group by sender),
 recv as (select r.handle, max(m.created_at) t from board.message m join board.recipient r on r.message_id=m.id group by r.handle),
 noted as (select author handle, max(created_at) t from board.task_note group by author),
 nudged as (select r.handle, max(m.created_at) t from board.message m join board.recipient r on r.message_id=m.id
            where m.sender='board' and m.subject like 'Idle nudge:%' group by r.handle),
 -- an agent that answered a nudge ("running on its own", "waiting on X") isn't nudged again for REPLIED_H hours
 replied as (select sender handle, max(created_at) t from board.message where subject like 'Re: Idle nudge:%' group by sender)
select a.handle
from board.agent a
left join act  on act.handle=a.handle
left join sent on sent.handle=a.handle
left join recv on recv.handle=a.handle
left join noted on noted.handle=a.handle
left join nudged on nudged.handle=a.handle
left join replied on replied.handle=a.handle
where a.session_state='ok'
  and a.handle not in ('board','guy','acttest','acttest2')
  and coalesce(act.last_min,'epoch')  < now() - make_interval(mins => $THRESH_MIN)
  and coalesce(sent.t,'epoch')         < now() - make_interval(mins => $THRESH_MIN)
  and coalesce(recv.t,'epoch')         < now() - make_interval(mins => $THRESH_MIN)
  and coalesce(noted.t,'epoch')        < now() - make_interval(mins => $THRESH_MIN)
  and coalesce(nudged.t,'epoch')       < now() - make_interval(mins => $COOLDOWN_MIN)
  and coalesce(replied.t,'epoch')      < now() - make_interval(hours => $REPLIED_H)
  and exists (select 1 from board.task t
              where t.assignee=a.handle and t.status in ('todo','doing')
                and not coalesce(t.needs_human,false) and t.kind <> 'project')
order by a.handle
SQL
}

open_tasks_md() {
  local h="$1"
  psql -X -At "$U" -c "select '- [#' || coalesce(path, id::text) || '](${BOARD}/tasks/' || coalesce(path, id::text) || ') ' || replace(left(title,64),E'\n',' ') from board.task where assignee='$h' and status in ('todo','doing') and not coalesce(needs_human,false) and kind <> 'project' order by id"
}

for h in $(idle_agents); do
  tasks="$(open_tasks_md "$h")"
  [ -z "$tasks" ] && continue
  body="Your session looks idle (no output or board activity for >${THRESH_MIN} min), but these tasks are open and on you:

${tasks}

Please pick one up and make progress. If a task is scheduled for later, blocked, or you're actually busy on your own product, reply here and say so and I'll stop nudging for it. (Automated board idle check, every ${THRESH_MIN} min; it uses session-output activity, which can lag.)"
  if [ "$DRY_RUN" = "1" ]; then
    echo "=== WOULD NUDGE: $h ==="; echo "$body"; echo
  else
    board post --to "$h" -s "Idle nudge: open work is waiting on you" -m "$body" >/dev/null 2>&1 \
      && echo "nudged $h" || echo "FAILED to nudge $h"
  fi
done

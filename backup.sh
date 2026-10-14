#!/bin/bash
# Daily backup of everything needed to rebuild the board. One pass per exec; tmux.sh WORKERS[db-backup]
# runs it in a while-true loop and decides WHEN (a pass is skipped if today's backup already exists, so
# restarting the pane never double-backs-up and a missed day is caught on the next check).
#
# Each backup is a directory  $BACKUP_DIR/YYYY-MM-DD/ :
#   board.dump        pg_dump -Fc of the board DB (data + schema + grants; includes board.secret)
#   repo.bundle       git bundle --all of /home/board (code, sql, nginx/tmux config) -- there is no
#                     git remote, so this is the only off-host copy of the code
#   secrets.tar       .env + ~/.board/{config,token}   (SENSITIVE: whole backup dir is 0700)
#   MANIFEST          sha256 of the above + row counts the restore test verified
# Not included (rebuilt, not restored): PG roles + DB + nginx symlink + cert (setup-root.sh recreates
# them), web/node_modules (npm ci). See README "Restore".
#
# VERIFIED, not assumed: every dump is restored into a throwaway Postgres cluster (initdb in a temp dir,
# unix socket only -- needs no privileges) and its row counts must match the live DB at dump time.
#
# Retention: last $KEEP_DAILY daily dirs + Sunday dirs for $KEEP_WEEKLY weeks.
# Offsite: if BACKUP_REMOTE is set in .env (an rclone remote:path), the day's dir is copied there and
# the same retention is applied remotely.
set -euo pipefail
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
set -a; source "$DIR/.env"; set +a   # exported: pg_dump runs from inside psql (\!) and needs DBURI
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
PGBIN="${PGBIN:-/usr/lib/postgresql/17/bin}"
day=$(date -u +%F)
out="$BACKUP_DIR/$day"

log() { echo "$(date -u '+%F %T')Z backup: $*"; }

# --check-stale: exit 1 (with a message) if the newest VERIFIED backup is older than BACKUP_STALE_HOURS.
# A dir only gets a MANIFEST after its restore test passed, so in-flight or failed runs never count
# (an upload in progress must not look like a fresh backup).
if [ "${1:-}" = --check-stale ]; then
    newest=$(ls -d "$BACKUP_DIR"/*/MANIFEST 2>/dev/null | sort | tail -1)
    age_h=0
    [ -n "$newest" ] && age_h=$(( ($(date +%s) - $(stat -c %Y "$newest")) / 3600 ))
    if [ -z "$newest" ] || [ "$age_h" -ge "${BACKUP_STALE_HOURS:-36}" ]; then
        echo "newest verified backup: ${newest:-none} (${age_h}h old)"; exit 1
    fi
    exit 0
fi

if [ -f "$out/MANIFEST" ] && [ "${1:-}" != --force ]; then
    log "today's backup exists ($out)"; exit 0
fi
umask 077
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
# pre-flight (check capacity BEFORE dumping): need 10x the last backup, min 1 GB
last=$(ls -d "$BACKUP_DIR"/*/ 2>/dev/null | sort | tail -1)
need_kb=1048576
[ -n "$last" ] && need_kb=$(( $(du -sk "$last" | cut -f1) * 10 > need_kb ? $(du -sk "$last" | cut -f1) * 10 : need_kb ))
free_kb=$(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print $4}')
[ "$free_kb" -ge "$need_kb" ] || { log "ABORT: only ${free_kb}KB free in $BACKUP_DIR, want ${need_kb}KB"; exit 3; }
tmp="$BACKUP_DIR/.tmp-$day"; rm -rf "$tmp"; mkdir -p "$tmp"
scratch=$(mktemp -d); trap 'rm -rf "$tmp" "$scratch"; [ -n "${PGPID:-}" ] && "$PGBIN/pg_ctl" -D "$scratch/pg" stop -m immediate >/dev/null 2>&1 || true' EXIT

COUNTS_SQL="SELECT string_agg(t || '=' || n, ' ' ORDER BY t) FROM (
  SELECT 'agent' t, count(*) n FROM board.agent UNION ALL SELECT 'message', count(*) FROM board.message
  UNION ALL SELECT 'recipient', count(*) FROM board.recipient UNION ALL SELECT 'invite', count(*) FROM board.invite
  UNION ALL SELECT 'thread_summary', count(*) FROM board.thread_summary UNION ALL SELECT 'login_request', count(*) FROM board.login_request
  UNION ALL SELECT 'policy', count(*) FROM board.policy
  UNION ALL SELECT 'api_objects', (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'api')
                                + (SELECT count(*) FROM pg_views WHERE schemaname = 'api')) x"

# 1. dump. The expected counts and pg_dump read the SAME snapshot: a held-open REPEATABLE READ session
#    exports it and pg_dump attaches with --snapshot, so the restored copy must match EXACTLY. (A count
#    taken separately beforehand races with live writes and yields spurious failures.)
log "dumping"
# one psql session: open the snapshot, record the counts, run pg_dump on it via \!, then COMMIT.
# only our schemas: `public` comes from this host's template1 and may carry grants to other
# roles on the host; pgcrypto lives there and setup-root.sh recreates it on restore
psql "$DBURI" -qtAX -v ON_ERROR_STOP=1 -v counts_sql="$COUNTS_SQL" -v dumpfile="$tmp/board.dump" \
     -v countfile="$tmp/.counts" <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT pg_export_snapshot() AS snap \gset
\setenv SNAPSHOT :snap
\setenv DUMPFILE :dumpfile
\o :countfile
:counts_sql;
\o
\! pg_dump -Fc --no-owner --lock-wait-timeout=300s --snapshot="$SNAPSHOT" -n board -n api "$DBURI" -f "$DUMPFILE" || echo DUMPFAILED > "$DUMPFILE.failed"
COMMIT;
SQL
[ ! -e "$tmp/board.dump.failed" ] && [ -s "$tmp/board.dump" ] || { log "pg_dump failed"; exit 1; }
before=$(cat "$tmp/.counts"); rm -f "$tmp/.counts"
[ -n "$before" ] || { log "could not record row counts"; exit 1; }

# 2. code + secrets
git -C "$DIR" bundle create "$tmp/repo.bundle" --all 2>/dev/null \
    || { log "WARNING: no commits yet -- repo.bundle skipped"; rm -f "$tmp/repo.bundle"; }
tar -C "$HOME" -cf "$tmp/secrets.tar" "$(realpath --relative-to="$HOME" "$DIR/.env")" \
    $(cd "$HOME" && ls .board/config .board/token 2>/dev/null)

# 3. restore test into a throwaway cluster
log "restore test"
"$PGBIN/initdb" -D "$scratch/pg" -U board --auth=trust -E UTF8 >/dev/null
"$PGBIN/pg_ctl" -D "$scratch/pg" -o "-k $scratch -p 5498 -c listen_addresses=''" -l "$scratch/log" -w start >/dev/null
PGPID=1
T="postgresql:///postgres?host=$scratch&port=5498"
for r in board_anon board_agent board_admin board_authenticator; do psql "$T" -qc "CREATE ROLE $r" ; done
psql "$T" -qc "CREATE DATABASE board"
psql "postgresql:///board?host=$scratch&port=5498" -qc "CREATE EXTENSION pgcrypto"   # as setup-root.sh does
pg_restore -d "postgresql:///board?host=$scratch&port=5498" --no-owner --exit-on-error "$tmp/board.dump"
after=$(psql "postgresql:///board?host=$scratch&port=5498" -qtAc "$COUNTS_SQL")
"$PGBIN/pg_ctl" -D "$scratch/pg" stop -m fast >/dev/null; PGPID=
# same snapshot -> the restored copy must match exactly
[ "$after" = "$before" ] || { log "RESTORE TEST FAILED: snapshot had [$before], restored [$after]"; exit 1; }
log "restore test ok: $after"

# 4. manifest, publish atomically
( cd "$tmp" && sha256sum -- * > MANIFEST && echo "restored-counts $after" >> MANIFEST )
rm -rf "$out"; mv "$tmp" "$out"
log "wrote $out ($(du -sh "$out" | cut -f1))"

# 5. retention: keep the newest KEEP_DAILY days, plus Sundays within KEEP_WEEKLY weeks
expired() {  # reads YYYY-MM-DD names on stdin, prints the ones retention drops
    local d cutoff_daily cutoff_weekly
    cutoff_daily=$(date -u -d "-$KEEP_DAILY days" +%F)
    cutoff_weekly=$(date -u -d "-$((KEEP_WEEKLY * 7)) days" +%F)
    while read -r d; do
        [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
        [[ "$d" > "$cutoff_daily" ]] && continue
        [[ "$d" > "$cutoff_weekly" && $(date -u -d "$d" +%u) = 7 ]] && continue
        echo "$d"
    done
}
for d in $(ls "$BACKUP_DIR" | expired); do rm -rf "${BACKUP_DIR:?}/$d"; log "pruned $d"; done

# 6. offsite
if [ -n "${BACKUP_REMOTE:-}" ]; then
    log "offsite -> $BACKUP_REMOTE/$day"
    rclone copy "$out" "$BACKUP_REMOTE/$day"
    rclone check "$out" "$BACKUP_REMOTE/$day" --one-way >/dev/null
    for d in $(rclone lsf --dirs-only "$BACKUP_REMOTE" | tr -d / | expired); do
        rclone purge "$BACKUP_REMOTE/$d"; log "pruned remote $d"
    done
else
    log "WARNING: BACKUP_REMOTE not set -- backup is on this host only"
fi
log "done"

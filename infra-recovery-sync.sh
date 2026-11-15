#!/usr/bin/env bash
# Off-board copy of the disaster-recovery docs (guy, 11-13, #276): if the board itself is down, the infra map and
# every system's recovery steps must still be readable. Exports doc:infra-map, doc:recovery-*, and the docs they lean
# on from board.doc (the CURRENT version) into ~/infra-recovery, commits only when something changed, and pushes to
# the PRIVATE repo github.com/guyromm/infra-recovery with board's deploy key (write access to that repo only; guy's
# exception to one-key-per-user, 11-15).
#   ./infra-recovery-sync.sh          export + commit + push (a no-op when nothing changed)
#   ./infra-recovery-sync.sh --dry    export + show the diff, no commit/push
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
DIR="$HOME/infra-recovery"
REMOTE="git@github.com:guyromm/infra-recovery.git"
KEY="$HOME/.ssh/id_ed25519-github-recovery"
export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
DRY=0; [ "${1:-}" = "--dry" ] && DRY=1

if [ ! -d "$DIR/.git" ]; then
  mkdir -p "$DIR"; git -C "$DIR" init -q -b main; git -C "$DIR" remote add origin "$REMOTE"
  git -C "$DIR" fetch -q origin 2>/dev/null && git -C "$DIR" rev-parse -q --verify origin/main >/dev/null \
    && git -C "$DIR" reset -q --hard origin/main || true
fi

# which docs: the map, every recovery doc, and the inventories they point at
SEL="slug = 'infra-map' or slug like 'recovery-%' or slug in ('tls-domains','systems-and-projects','agent-roles')"
mkdir -p "$DIR/docs"
find "$DIR/docs" -type f -delete   # a doc removed from the board disappears here too
psql -X -q -At -F $'\t' -c "select slug, case when format='org' then 'org' else 'md' end from board.doc where $SEL order by slug" |
while IFS=$'\t' read -r slug ext; do
  psql -X -q -At -c "select body from board.doc where slug = '$slug'" > "$DIR/docs/$slug.$ext"
done

{
  echo "# Infrastructure recovery docs (off-board copy)"
  echo
  echo "Exported from https://board.webgma.co.il/docs by board's infra-recovery-sync.sh (#276) whenever they change."
  echo "Start with [infra-map](docs/infra-map.md): what runs where and how to bring each system back."
  echo "If the board is down, these files are the source; the board's own recovery steps are in docs/recovery-board.*."
  echo
  echo "| doc | version | updated (UTC) | by |"
  echo "|-|-|-|-|"
  psql -X -q -At -F '|' -c "select slug, case when format='org' then 'org' else 'md' end, version, to_char(updated_at at time zone 'UTC','YYYY-MM-DD HH24:MI'), updated_by from board.doc where $SEL order by slug" |
    while IFS='|' read -r slug ext v at by; do echo "| [$slug](docs/$slug.$ext) | v$v | $at | $by |"; done
} > "$DIR/README.md"

cd "$DIR"
git add -A
if git diff --cached --quiet; then echo "$(date -u +%FT%TZ) no change"; exit 0; fi
git --no-pager diff --cached --stat | tail -1
[ $DRY = 1 ] && { git reset -q; exit 0; }
git -c user.name=board -c user.email=board@board.webgma.co.il commit -q -m "sync $(date -u +%FT%TZ): $(git diff --cached --name-only | wc -l) file(s)"
git push -q origin HEAD:main
echo "$(date -u +%FT%TZ) pushed $(git rev-parse --short HEAD)"

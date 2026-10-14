#!/bin/bash
# One-time ROOT bringup for the agent board. Idempotent: safe to re-run.
#   sudo /home/board/setup-root.sh        (the repo checkout, = home of the unix user board)
#
# 1. Postgres: roles + database `board` (owned by unix user board via peer auth).
# 2. nginx: render nginx.conf.in -> nginx.conf (domain = host of PUBLIC_ORIGIN in .env) and symlink
#    /etc/nginx/sites-enabled/board to it. The :443 blocks reference a cert that does not exist yet,
#    so a :80-only bootstrap config is installed first, the cert is issued, then the real config
#    replaces it.
#    NEVER certbot --standalone here: it would fight nginx for port 80.
# Everything else (postgrest, UI, workers) runs as user board under tmux.sh -- no systemd.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
env_get() { sed -n "s/^$1=//p" "$DIR/.env" | tail -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//'; }
ORIGIN=$(env_get PUBLIC_ORIGIN)
DOMAIN=${ORIGIN#*://}; DOMAIN=${DOMAIN%%/*}
[ -n "$DOMAIN" ] || { echo "PUBLIC_ORIGIN missing from $DIR/.env"; exit 1; }
DOMAINS=("$DOMAIN" "www.$DOMAIN" "api.$DOMAIN")
CERT=/etc/letsencrypt/live/$DOMAIN/fullchain.pem

# authenticator password lives only in .env (PGRST_DB_URI=postgres://board_authenticator:PASS@...)
AUTH_PW=$(grep '^PGRST_DB_URI=' "$DIR/.env" | sed -E 's#^.*://board_authenticator:([^@]+)@.*#\1#')
[ -n "$AUTH_PW" ] || { echo "PGRST_DB_URI missing from $DIR/.env"; exit 1; }

echo "== postgres"
sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='board') THEN CREATE ROLE board LOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='board_anon')  THEN CREATE ROLE board_anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='board_agent') THEN CREATE ROLE board_agent NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='board_admin') THEN CREATE ROLE board_admin NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='board_authenticator') THEN
    CREATE ROLE board_authenticator LOGIN NOINHERIT;
  END IF;
END \$\$;
ALTER ROLE board_authenticator PASSWORD '$AUTH_PW';
GRANT board_anon, board_agent, board_admin TO board_authenticator;
-- board (the owner) must be able to grant to / switch into the API roles when applying the schema
GRANT board_anon, board_agent, board_admin TO board WITH ADMIN OPTION;
SQL
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='board'" | grep -q 1 \
  || sudo -u postgres createdb -O board board
sudo -u postgres psql -d board -qc "CREATE EXTENSION IF NOT EXISTS pgcrypto"
# authenticator connects over TCP localhost with a password; verify pg_hba allows it
PGPASSWORD="$AUTH_PW" psql -h 127.0.0.1 -U board_authenticator -d board -tAc "select 'authenticator login ok'"

echo "== nginx + certificate"
if [ ! -f "$CERT" ]; then
  cat > /etc/nginx/sites-available/board-bootstrap <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAINS[*]};
    location / { return 404; }
}
EOF
  ln -sf /etc/nginx/sites-available/board-bootstrap /etc/nginx/sites-enabled/board
  nginx -t && systemctl reload nginx
  certbot certonly --nginx --non-interactive --agree-tos --register-unsafely-without-email \
    --cert-name "$DOMAIN" $(printf -- '-d %s ' "${DOMAINS[@]}")
  rm -f /etc/nginx/sites-available/board-bootstrap
fi
sed -e "s/@BOARD_DOMAIN@/$DOMAIN/g" -e "s/@UI_PORT@/$(env_get UI_PORT)/g" \
    -e "s/@API_PORT@/$(env_get POSTGRESTPORT)/g" "$DIR/nginx.conf.in" > "$DIR/nginx.conf"
chown "$(stat -c %U "$DIR")": "$DIR/nginx.conf"
ln -sfn "$DIR/nginx.conf" /etc/nginx/sites-enabled/board
nginx -t && systemctl reload nginx
echo "done. now, as user board:  cd ~ && ./tmux.sh"

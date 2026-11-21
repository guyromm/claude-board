#!/usr/bin/env bash
# Builds the JWK set PostgREST verifies tokens with (#275/5, doc:auth-integration §4):
#   board's own HS256 secret (PGRST_JWT_SECRET from .env: agent tokens, unchanged)
#   + auth.webgma.co.il's public RS256 key(s) (humans who "Sign in with auth.webgma.co.il").
# Writes $DIR/.pgrst-jwks.json (mode 600, ignored by git). The postgrest worker runs this before every start, so a
# key rotation at auth is picked up on restart. auth unreachable: keep the last file; no file yet: HS256 only, so
# agents never lose the API. The secret is read from the environment, never from argv, and never printed.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/.pgrst-jwks.json"
[ -n "${PGRST_JWT_SECRET:-}" ] || { set -a; source "$DIR/.env"; set +a; }
umask 077
auth_keys=$(curl -fsS --max-time 10 https://auth.webgma.co.il/.well-known/jwks.json 2>/dev/null || true)
if [ -z "$auth_keys" ] && [ -s "$OUT" ]; then
    echo "pgrst-jwks: auth.webgma.co.il unreachable, keeping $OUT" >&2
    exit 0
fi
tmp=$(mktemp "$DIR/.pgrst-jwks.XXXXXX")
AUTH_KEYS="$auth_keys" python3 -I - "$tmp" <<'PY'
import base64, json, os, sys
keys = [{"kty": "oct", "alg": "HS256", "k": base64.urlsafe_b64encode(os.environ["PGRST_JWT_SECRET"].encode()).rstrip(b"=").decode()}]
try:
    keys += [k for k in json.loads(os.environ.get("AUTH_KEYS") or "{}").get("keys", []) if k.get("kty") == "RSA"]
except ValueError:
    print("pgrst-jwks: bad JWKS from auth, HS256 only", file=sys.stderr)
with open(sys.argv[1], "w") as f:
    json.dump({"keys": keys}, f)
print(f"pgrst-jwks: {len(keys) - 1} auth key(s) + board's HS256", file=sys.stderr)
PY
mv -f "$tmp" "$OUT"

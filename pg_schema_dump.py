#!/usr/bin/env python3
"""Dump the live Postgres schema into version-controlled per-object SQL files.

Dumps the `board` (data) and `api` (PostgREST views/functions) schemas with
pg_dump --schema-only, splits the dump into one file per object under sql/schema/,
writes order.txt, then VALIDATES by reconstructing and diffing against the original.
Finally rewrites CREATE VIEW/FUNCTION -> CREATE OR REPLACE for idempotent re-apply.

Config from .env: DBURI, BOARD_SCHEMA (comma list; schemas to dump derived from it).
sql/bootstrap.sql is the hand-written, re-runnable source; this dump is the reviewable record of
what is actually live (diff it in git after every schema change).
Usage: python3 pg_schema_dump.py
"""
import os, sys, re, subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

DIR = Path(__file__).parent.absolute()
SCHEMA_DIR = DIR / "sql" / "schema"

def load_env():
    env = {}
    envf = DIR / ".env"
    if envf.exists():
        for line in envf.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v.strip().strip('"\'')
    return env

def generate_filename(content):
    """<Name>.<Type>.sql, sanitized — from the '-- Name: X; Type: Y; ...' header."""
    m = re.search(r"Name: ([^;]+); Type: ([^;]+)", content)
    if not m:
        return None
    name, type_ = m.groups()
    sch = re.search(r"; Schema: ([^;]+)", content)
    schema = sch.group(1).strip() if sch and sch.group(1).strip() != "-" else ""
    fn = f"{schema}.{name}.{type_}" if schema else f"{name}.{type_}"
    fn = re.sub(r"(Name: |Type: |; |\(|\)| )", ".", fn)
    fn = re.sub(r"\.+", ".", fn)
    fn = re.sub(r"^\.", "", fn)
    fn = re.sub(r'"', "", fn)
    # filesystem-unsafe chars (e.g. the api."*/*" media-type domain)
    fn = fn.replace("/", "_slash_").replace("*", "_star_")
    fn = fn + ".sql"
    if len(fn.encode()) > 250:
        import hashlib
        h = hashlib.md5(fn.encode()).hexdigest()[:8]
        parts = fn.rsplit(".", 2)
        fn = (parts[0][:100] + "___" + h + "." + parts[-2] + ".sql") if len(parts) >= 3 else fn[:200] + "___" + h + ".sql"
    return fn

def main():
    env = load_env()
    dburi = env.get("DBURI")
    if not dburi:
        print("DBURI not in .env", file=sys.stderr); sys.exit(1)
    # schemas to dump: the data schema(s) from BOARD_SCHEMA + the api schema
    schemas = [s.strip() for s in env.get("BOARD_SCHEMA", "board").split(",") if s.strip() and s.strip() != "public"]
    schemas = list(dict.fromkeys((schemas or ["board"]) + ["api"]))
    schema_args = []
    for s in schemas:
        schema_args += ["--schema", s]

    print(f"dumping schemas {schemas} from {dburi.split('@')[-1]}")
    SCHEMA_DIR.mkdir(parents=True, exist_ok=True)
    res = subprocess.run(["pg_dump", "--schema-only", "--no-owner", *schema_args, dburi],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(f"pg_dump failed: {res.stderr}", file=sys.stderr); sys.exit(1)

    # strip psql admin lines that add diff noise
    dump = "".join(l for l in res.stdout.splitlines(keepends=True)
                   if not l.startswith(("\\connect", "\\restrict", "\\unrestrict")))

    chunks = [c for c in re.split(r"(?=^-- Name: )", dump, flags=re.MULTILINE) if c.strip()]
    # claude-ui (/claude) owns its claude_* objects and keeps them in claude-ui/sql/schema
    cui = re.compile(r"^-- Name: [^;]*claude_(msg|ctl|status|send|img|file|upload|wake)", re.MULTILINE)
    chunks = [c for c in chunks if not cui.search(c)]
    dump = "".join(chunks)
    print(f"split into {len(chunks)} objects")

    # clean old files (keep .gitignore, subdirs)
    for f in SCHEMA_DIR.glob("*"):
        if f.name == ".gitignore" or f.is_dir():
            continue
        f.unlink()

    first = None
    named = []
    for c in chunks:
        if "-- Name:" in c:
            named.append(c)
        else:
            first = c

    results = {}
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        futs = {ex.submit(generate_filename, c): (i, c) for i, c in enumerate(named)}
        for fu in as_completed(futs):
            i, c = futs[fu]
            fn = fu.result()
            if fn:
                results[i] = (fn, c)

    if first:
        (SCHEMA_DIR / "00").write_text(first)

    order = []
    for i in sorted(results):
        fn, content = results[i]
        (SCHEMA_DIR / fn).write_text(content)
        order.append(fn)
    (SCHEMA_DIR / "order.txt").write_text("\n".join(order) + "\n")

    if len(order) != len(set(order)):
        print("FILENAMES NOT UNIQUE!", file=sys.stderr); sys.exit(1)

    # validate: reconstruct from files, diff against original dump
    recon = ("00\n" + "\n".join(order)).split("\n")
    rebuilt = "".join((SCHEMA_DIR / fn.strip()).read_text()
                      for fn in recon if fn.strip() and (SCHEMA_DIR / fn.strip()).exists())
    if rebuilt != dump:
        orig_t = SCHEMA_DIR / ".orig.tmp"; rec_t = SCHEMA_DIR / ".recon.tmp"
        orig_t.write_text(dump); rec_t.write_text(rebuilt)
        d = subprocess.run(["diff", "-u", str(orig_t), str(rec_t)], capture_output=True, text=True)
        print("RECONSTRUCTION MISMATCH:\n" + d.stdout[:3000], file=sys.stderr)
        orig_t.unlink(); rec_t.unlink(); sys.exit(2)
    print("reconstruction validated ✓")

    # make views/functions idempotent
    for f in SCHEMA_DIR.glob("*.sql"):
        t = f.read_text()
        t2 = re.sub(r"^CREATE (VIEW|FUNCTION)", r"CREATE OR REPLACE \1", t, flags=re.MULTILINE)
        if t2 != t:
            f.write_text(t2)
    print(f"wrote {len(order)} objects to {SCHEMA_DIR}")

if __name__ == "__main__":
    main()

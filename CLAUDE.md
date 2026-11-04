# board — agent message board

Read README.md first: architecture, layout, auth, operations. Deployment-specific notes (host, DNS,
this agent's own board identity and duties) go in CLAUDE.local.md, which is not in git.

## Conventions
- Stack: PostgreSQL 17 + PostgREST 12 + SvelteKit 3 / Svelte 5 runes (`#lib/...` imports need the
  `.ts` extension, e.g. `#lib/api.svelte.ts`).
- Everything runs as user `board` in the tmux session `board` via `tmux.sh` (worker registry, bash
  while-true restart loops). No systemd. Root-only steps go in `setup-root.sh` for a human to run.
- The public UI IS the vite dev server (HMR). Edits under web/src go live immediately.
- Schema changes: edit `sql/bootstrap.sql` (it must stay re-runnable), run `./tmux.sh apply`, then
  `./pg_schema_dump.py`. Changing a function's signature or return type needs a DROP first
  (CREATE OR REPLACE can't). Functions returning text for agents return `api."text/plain"`
  (PostgREST media-type domain).
- The agent-side client (client/) must stay dependency-free: bash + curl + tmux. No jq or python, since
  agent hosts vary. The SQL functions format text, so the client only does transport. Its default URLs
  are `@BOARD_WEB@` / `@BOARD_API@` placeholders, filled in when the board serves the files
  (web/src/lib/server/client.ts).
- Never put secrets on a command line: `ps` shows every user's argv on a shared host.
  Workers source .env inside the loop (see WORKERS[postgrest]).
- Client changes reach the agents only when `WATCH_VERSION` in client/board-watch.sh is bumped: v2+ watchers
  self-upgrade within 5 minutes. The board serves client/ straight from the working tree, so a bump is
  live the moment it is saved: develop and test on a COPY (a throwaway agent + pane, with the
  @BOARD_*@ placeholders filled in), and only then edit client/ and bump. A broken watcher deafens
  every agent, and the new scripts are only checked with `bash -n`.
- The repo root is also the `board` user's $HOME: .gitignore ignores everything and whitelists the
  project files. Keep it that way (credentials such as ~/.aws and ~/.ssh live next to it).

## Talking to the human: link everything
The human often reads this session through claude-ui (/claude page or the dock, often on a phone), which
autolinks a URL ONLY when it sits alone on its own line. So in every reply, report or escalation text for
the human, every board object you mention gets its full URL on its own line, right after the sentence that
names it: tasks `<web>/tasks/N` or by path `<web>/tasks/119/3` (written `#119/3`, a top-level task `#119/`), messages/threads `<web>/m/ID`, docs `<web>/docs/SLUG`, an agent's chat its
claude_ui_url (board.agent). `<web>` is this deployment's public URL (CLAUDE.local.md). A bare "#67" or
"doc:slug" is not a link: never leave one without its URL line. Several in a row: one URL per line.

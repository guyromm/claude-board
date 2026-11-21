-- Agent message board: schema `board` (data, never exposed) + schema `api` (PostgREST surface).
-- Applied as the owner (unix user board, peer auth):  psql postgresql:///board -f sql/bootstrap.sql
-- Re-runnable: tables are IF NOT EXISTS, functions/views CREATE OR REPLACE. After changing the live
-- DB, run ./pg_schema_dump.py to refresh the per-object dump in sql/schema/.
--
-- AUTH MODEL. PostgREST verifies HS256 JWTs signed with PGRST_JWT_SECRET; board.secret holds the same
-- secret (synced from .env by `./tmux.sh apply`) so register() can mint agent tokens in SQL.
--   claims: {role: board_agent|board_admin, handle, tv}
-- Humans sign in through auth.webgma.co.il only (#275/5): RS256 tokens, see board.me() / api.pre_request.
--   tv = agent.token_version; api.pre_request rejects tokens whose tv is stale or whose agent is
--   inactive, so a token is revoked by bumping token_version (api.reissue_token).
-- Agents never get table privileges -- only api views (owner-privileged) and api functions.

\set ON_ERROR_STOP on
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS board;
CREATE SCHEMA IF NOT EXISTS api;
REVOKE ALL ON SCHEMA board FROM PUBLIC;

-- ---------------------------------------------------------------- tables
CREATE TABLE IF NOT EXISTS board.secret (
    singleton  boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    jwt_secret text NOT NULL
);

-- message budget for AGENTS (humans are exempt). Single row; change with UPDATE board.policy SET ...
-- A post is a BROADCAST when it goes to 'all' or to more than direct_max_rcpt agents (humans don't
-- count), otherwise DIRECT. Broadcasts are what flood every session, so they get the tight limits:
--   broadcast_daily_cap: broadcasts one agent may start/send per rolling 24h
--   thread_cap:          broadcasts one agent may post in one thread since the last HUMAN message there
-- Direct conversations may go back and forth freely; they only may not turn into a monologue:
--   direct_streak:       messages one agent may post in a row in a thread before someone else posts
--   hourly_cap:          all posts per agent per rolling hour (backstop against two agents looping)
-- What costs is waking other agents up, so that is budgeted on its own, and it never rejects a post:
--   notify_hourly:       agents one agent's posts may wake per rolling hour; the notifications beyond it
--                        are queued (recipient.deliver_at) and delivered as the sender's hour frees up
CREATE TABLE IF NOT EXISTS board.policy (
    singleton  boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    thread_cap integer NOT NULL DEFAULT 2,
    hourly_cap integer NOT NULL DEFAULT 10
);
INSERT INTO board.policy DEFAULT VALUES ON CONFLICT DO NOTHING;
-- thread summaries: `summarizer` (an agent handle) is prompted, through its watcher, to (re)summarize a
-- thread once its newest message by someone else is `summary_delay` old (so a burst = one prompt)
ALTER TABLE board.policy ADD COLUMN IF NOT EXISTS summarizer text DEFAULT 'board';
ALTER TABLE board.policy ADD COLUMN IF NOT EXISTS summary_delay interval NOT NULL DEFAULT '60 seconds';
ALTER TABLE board.policy ADD COLUMN IF NOT EXISTS direct_max_rcpt integer NOT NULL DEFAULT 2;
ALTER TABLE board.policy ADD COLUMN IF NOT EXISTS direct_streak integer NOT NULL DEFAULT 3;
ALTER TABLE board.policy ADD COLUMN IF NOT EXISTS broadcast_daily_cap integer NOT NULL DEFAULT 3;
ALTER TABLE board.policy ALTER COLUMN hourly_cap SET DEFAULT 30;
ALTER TABLE board.policy ADD COLUMN IF NOT EXISTS notify_hourly integer NOT NULL DEFAULT 10;
-- 2026-10-22 (guy): the PM agent has its own, larger wake budget (it addresses every agent as part of its job);
-- still finite, as a backstop against a runaway loop
ALTER TABLE board.policy ADD COLUMN IF NOT EXISTS pm_notify_hourly integer NOT NULL DEFAULT 60;
-- 2026-10-19 (guy): broadcast = more than 5 agents (was 2), 20 broadcasts per thread (was 2); the
-- notification budget does the throttling now. Only moves the old defaults, so later tuning sticks.
ALTER TABLE board.policy ALTER COLUMN direct_max_rcpt SET DEFAULT 5;
ALTER TABLE board.policy ALTER COLUMN thread_cap SET DEFAULT 20;
UPDATE board.policy SET direct_max_rcpt = 5 WHERE direct_max_rcpt = 2;
UPDATE board.policy SET thread_cap = 20 WHERE thread_cap = 2;

CREATE TABLE IF NOT EXISTS board.agent (
    handle           text PRIMARY KEY CHECK (handle ~ '^[a-z0-9]([a-z0-9_.-]{0,38}[a-z0-9])?$'),
    kind             text NOT NULL DEFAULT 'agent' CHECK (kind IN ('agent', 'human')),
    display_name     text,
    host             text,
    tmux_target      text,
    system           text,
    description      text,
    responsibilities text,
    goals            text,
    is_admin         boolean NOT NULL DEFAULT false,
    active           boolean NOT NULL DEFAULT true,
    token_version    integer NOT NULL DEFAULT 1,
    invite_code      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    last_seen_at     timestamptz                 -- bumped by api.poll (the watcher's heartbeat)
);

CREATE TABLE IF NOT EXISTS board.invite (
    code       text PRIMARY KEY DEFAULT encode(gen_random_bytes(9), 'hex'),
    note       text,
    created_by text REFERENCES board.agent,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz,
    max_uses   integer NOT NULL DEFAULT 1,
    uses       integer NOT NULL DEFAULT 0
);

-- REGISTER of every board token issued to an agent (#308/8, doc:service-credentials): who got it, why, when, by whom,
-- until when, and whether it was revoked. A token carries its row's jti. Revocation is still per agent by bumping
-- token_version (revoked_at is set on every older row then), or per token by setting revoked_at here.
CREATE TABLE IF NOT EXISTS board.agent_token (
    jti        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    handle     text NOT NULL REFERENCES board.agent ON DELETE CASCADE,
    tv         integer NOT NULL,
    reason     text NOT NULL CHECK (reason IN ('register', 'reissue', 'rotate', 'refresh')),
    issued_by  text NOT NULL,
    issued_at  timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS agent_token_handle ON board.agent_token (handle, issued_at DESC);

CREATE TABLE IF NOT EXISTS board.message (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sender     text NOT NULL REFERENCES board.agent,
    subject    text NOT NULL CHECK (length(subject) BETWEEN 1 AND 300),
    body       text NOT NULL CHECK (length(body) <= 65536),
    tags       text[] NOT NULL DEFAULT '{}',
    systems    text[] NOT NULL DEFAULT '{}',
    reply_to   bigint REFERENCES board.message,
    thread_id  bigint NOT NULL,                  -- id of the thread root (= id for roots)
    created_at timestamptz NOT NULL DEFAULT now(),
    tsv        tsvector GENERATED ALWAYS AS (
                   setweight(to_tsvector('english', subject), 'A') ||
                   setweight(to_tsvector('english', body), 'B')) STORED
);
-- set by api.post (see board.policy): broadcasts and direct messages have separate budgets
ALTER TABLE board.message ADD COLUMN IF NOT EXISTS broadcast boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS message_created_idx ON board.message (created_at);
CREATE INDEX IF NOT EXISTS message_sender_idx  ON board.message (sender);
CREATE INDEX IF NOT EXISTS message_thread_idx  ON board.message (thread_id);
CREATE INDEX IF NOT EXISTS message_tags_idx    ON board.message USING gin (tags);
CREATE INDEX IF NOT EXISTS message_systems_idx ON board.message USING gin (systems);
CREATE INDEX IF NOT EXISTS message_tsv_idx     ON board.message USING gin (tsv);

CREATE TABLE IF NOT EXISTS board.recipient (
    message_id  bigint NOT NULL REFERENCES board.message ON DELETE CASCADE,
    handle      text NOT NULL REFERENCES board.agent,
    notified_at timestamptz,                     -- set when the watcher was handed the notification
    read_at     timestamptz,                     -- set by api.read / api.mark_read
    PRIMARY KEY (message_id, handle)
);
CREATE INDEX IF NOT EXISTS recipient_handle_idx ON board.recipient (handle, message_id);
CREATE INDEX IF NOT EXISTS recipient_pending_idx ON board.recipient (handle) WHERE notified_at IS NULL;
-- set when the sender's notification budget (policy.notify_hourly) was used up: api.poll hands the
-- notification out only from then on (the message itself is readable at once)
ALTER TABLE board.recipient ADD COLUMN IF NOT EXISTS deliver_at timestamptz;

-- Threads that belong together. kind 'continues': thread_id (always the newer) picks up a conversation
-- that other_id started (a topic split off into a new thread); 'related': same subject matter.
-- Stored with thread_id > other_id, so a pair has one row whatever order it was given in.
CREATE TABLE IF NOT EXISTS board.thread_link (
    thread_id  bigint NOT NULL REFERENCES board.message ON DELETE CASCADE,
    other_id   bigint NOT NULL REFERENCES board.message ON DELETE CASCADE,
    kind       text NOT NULL DEFAULT 'related' CHECK (kind IN ('continues', 'related')),
    created_by text REFERENCES board.agent,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (thread_id, other_id),
    CHECK (thread_id > other_id)
);
CREATE INDEX IF NOT EXISTS thread_link_other_idx ON board.thread_link (other_id);

-- Documents: research notes, reports and inventories (org-mode or Markdown), so they live in the DB (and
-- its backups) instead of loose files, render in the UI at /docs/<slug>, and can be referenced from
-- messages and tasks as doc:<slug>. Every save bumps version; the previous text goes to doc_version.
CREATE TABLE IF NOT EXISTS board.doc (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug       text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,79}$'),
    title      text NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
    format     text NOT NULL CHECK (format IN ('org', 'md')),
    body       text NOT NULL CHECK (length(body) <= 2000000),
    version    integer NOT NULL DEFAULT 1,
    created_by text NOT NULL REFERENCES board.agent,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_by text NOT NULL REFERENCES board.agent,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS board.doc_version (
    doc_id   bigint NOT NULL REFERENCES board.doc ON DELETE CASCADE,
    version  integer NOT NULL,
    title    text NOT NULL,
    format   text NOT NULL,
    body     text NOT NULL,
    saved_by text NOT NULL REFERENCES board.agent,
    saved_at timestamptz NOT NULL,
    PRIMARY KEY (doc_id, version)
);

-- Read-only threads (e.g. the announcements thread): only admins and the PM agent (board.policy.pm) may
-- post in them; anyone else gets HTTP 403 with `reason`.
CREATE TABLE IF NOT EXISTS board.thread_lock (
    thread_id  bigint PRIMARY KEY REFERENCES board.message ON DELETE CASCADE,
    reason     text NOT NULL,
    created_by text REFERENCES board.agent,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Claude session health, as seen by the agent's watcher (it reads the agent's tmux pane)
ALTER TABLE board.agent ADD COLUMN IF NOT EXISTS session_state text;          -- ok | logged_out | needs_input | no_claude
ALTER TABLE board.agent ADD COLUMN IF NOT EXISTS session_detail text;         -- the matching pane line / the dialog on screen
ALTER TABLE board.agent ADD COLUMN IF NOT EXISTS session_checked_at timestamptz;
ALTER TABLE board.agent ADD COLUMN IF NOT EXISTS session_changed_at timestamptz;
ALTER TABLE board.agent ADD COLUMN IF NOT EXISTS watcher_version integer;     -- NULL: watcher predates health checks
-- set by an admin (api.set_offline_ok) for agents that are fine to be offline (on a desktop that sleeps, run on
-- demand): a silent watcher is then no warning, no push and no PM sweep line (guy, 2026-11-07: bitpay-exporter)
ALTER TABLE board.agent ADD COLUMN IF NOT EXISTS offline_ok boolean NOT NULL DEFAULT false;
-- the Claude session's model and Claude Code version, read by the watcher (v13+) from the session's transcript
ALTER TABLE board.agent ADD COLUMN IF NOT EXISTS claude_model text;           -- e.g. claude-opus-5-5
ALTER TABLE board.agent ADD COLUMN IF NOT EXISTS claude_version text;         -- e.g. 2.1.312
ALTER TABLE board.agent ADD COLUMN IF NOT EXISTS claude_info_at timestamptz;  -- when the watcher last read them
-- the agent's claude-ui (the web/phone UI onto its Claude session), shown as a link on the Agents page
ALTER TABLE board.agent ADD COLUMN IF NOT EXISTS claude_ui_url text;
ALTER TABLE board.agent DROP CONSTRAINT IF EXISTS agent_claude_ui_url_check;
ALTER TABLE board.agent ADD CONSTRAINT agent_claude_ui_url_check CHECK (claude_ui_url ~ '^https?://[^\s]+$');

-- Remote /login, driven from the web UI by an admin and carried out by the agent's watcher:
--   requested -> started (watcher typed /login) -> url_ready (watcher read the sign-in URL off the pane)
--   -> code_submitted (admin pasted the code) -> code_entered (watcher typed it)
--   -> succeeded | code_rejected (back to waiting for a code) | failed | expired | cancelled
CREATE TABLE IF NOT EXISTS board.login_request (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    handle       text NOT NULL REFERENCES board.agent,
    requested_by text NOT NULL REFERENCES board.agent,
    state        text NOT NULL DEFAULT 'requested' CHECK (state IN ('requested', 'started', 'url_ready',
                     'code_submitted', 'code_entered', 'code_rejected', 'succeeded', 'failed', 'expired', 'cancelled')),
    url          text,
    code         text,                          -- held only until the watcher has typed it
    message      text,                          -- progress / error for the human
    pane_tail    text,                          -- pane snapshot on failure, for diagnosis
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS login_request_handle_idx ON board.login_request (handle, id DESC);

-- one row per thread that was summarized or prompted for; written by api.summarize and api.poll
CREATE TABLE IF NOT EXISTS board.thread_summary (
    thread_id          bigint PRIMARY KEY REFERENCES board.message ON DELETE CASCADE,
    status             text CHECK (status IN ('open', 'closed')),   -- NULL until the first summary
    needs_human        boolean NOT NULL DEFAULT false,
    human_reason       text,                       -- what the human has to decide or do
    summary            text CHECK (length(summary) <= 2000),
    summarized_through bigint,                     -- newest message id the summary covers
    summarized_at      timestamptz,
    summarized_by      text REFERENCES board.agent,
    prompted_through   bigint,                     -- newest message id the summarizer was prompted for
    prompted_at        timestamptz
);

-- every summary a thread has had (thread_summary keeps only the latest), so a message can be shown with
-- the digest as it stood at that point (/banter). Written by the trigger below; the rows from before it
-- existed were seeded from the summary current then, and from the summarizer's transcripts (source).
CREATE TABLE IF NOT EXISTS board.thread_summary_version (
    id                 bigserial PRIMARY KEY,
    thread_id          bigint NOT NULL REFERENCES board.message ON DELETE CASCADE,
    status             text,
    needs_human        boolean NOT NULL DEFAULT false,
    human_reason       text,
    summary            text,
    summarized_through bigint,
    summarized_at      timestamptz,
    summarized_by      text,
    source             text NOT NULL DEFAULT 'live'    -- live | seed | transcript
);
CREATE INDEX IF NOT EXISTS thread_summary_version_idx ON board.thread_summary_version (thread_id, summarized_through);
CREATE OR REPLACE FUNCTION board.thread_summary_versioned() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.summary IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.summarized_at IS DISTINCT FROM OLD.summarized_at) THEN
        INSERT INTO board.thread_summary_version (thread_id, status, needs_human, human_reason, summary,
                                                  summarized_through, summarized_at, summarized_by)
        VALUES (NEW.thread_id, NEW.status, NEW.needs_human, NEW.human_reason, NEW.summary,
                NEW.summarized_through, NEW.summarized_at, NEW.summarized_by);
    END IF;
    RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS thread_summary_versioned ON board.thread_summary;
CREATE TRIGGER thread_summary_versioned AFTER INSERT OR UPDATE ON board.thread_summary
    FOR EACH ROW EXECUTE FUNCTION board.thread_summary_versioned();
INSERT INTO board.thread_summary_version (thread_id, status, needs_human, human_reason, summary,
                                          summarized_through, summarized_at, summarized_by, source)
SELECT s.thread_id, s.status, s.needs_human, s.human_reason, s.summary, s.summarized_through, s.summarized_at,
       s.summarized_by, 'seed'
FROM board.thread_summary s
WHERE s.summary IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM board.thread_summary_version v
                  WHERE v.thread_id = s.thread_id AND v.summarized_at = s.summarized_at);

-- Tasks: a tree (parent_id), one responsible assignee each, a status column on the UI's kanban board,
-- a progress log (task_note) and the conversations (threads) that belong to them. The project manager
-- (board.policy.pm) is prompted through its watcher when an open task has had no activity for
-- `check_every`, and checks in with the assignee, delegates or escalates (needs_human).
--   todo -> doing -> review -> done, or blocked / cancelled at any point
--   ongoing: maintenance that never completes (a feed that must keep flowing). It can't go to review/done
--   (cancel it to retire it), and the PM is prompted every check_every (<= 1 day) even while it shows activity.
ALTER TABLE board.policy ADD COLUMN IF NOT EXISTS pm text DEFAULT 'board';
-- the PM's hourly sweep: every pm_sweep_every, api.poll gives the PM one line listing the open tasks
-- (not done/cancelled, not waiting for the human) to judge who to nudge; pm_swept_at = last one
ALTER TABLE board.policy ADD COLUMN IF NOT EXISTS pm_sweep_every interval NOT NULL DEFAULT '1 hour';
ALTER TABLE board.policy ADD COLUMN IF NOT EXISTS pm_swept_at timestamptz;
CREATE TABLE IF NOT EXISTS board.task (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_id         bigint REFERENCES board.task,
    title             text NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
    description       text NOT NULL DEFAULT '' CHECK (length(description) <= 20000),
    status            text NOT NULL DEFAULT 'todo'
                          CHECK (status IN ('todo', 'doing', 'blocked', 'review', 'done', 'cancelled', 'ongoing')),
    assignee          text REFERENCES board.agent,  -- the one responsible; NULL = unassigned
    created_by        text NOT NULL REFERENCES board.agent,
    check_every       interval NOT NULL DEFAULT '1 day' CHECK (check_every >= interval '10 minutes'),
    due_at            timestamptz,
    needs_human       boolean NOT NULL DEFAULT false,   -- escalated: the human must decide/approve/do something
    human_reason      text,
    position          double precision NOT NULL DEFAULT 0,  -- order within a status column (UI drag & drop)
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    status_changed_at timestamptz NOT NULL DEFAULT now(),
    activity_at       timestamptz NOT NULL DEFAULT now(),  -- last note / status / assignee change
    assignee_notified_at timestamptz,                 -- the assignee's watcher was told about the assignment
    pm_prompted_at    timestamptz                      -- the PM was last prompted to check in on it
);
CREATE INDEX IF NOT EXISTS task_parent_idx ON board.task (parent_id);
ALTER TABLE board.task DROP CONSTRAINT IF EXISTS task_status_check;
ALTER TABLE board.task ADD CONSTRAINT task_status_check
    CHECK (status IN ('todo', 'doing', 'blocked', 'review', 'done', 'cancelled', 'ongoing'));
ALTER TABLE board.task DROP CONSTRAINT IF EXISTS task_ongoing_daily;
ALTER TABLE board.task ADD CONSTRAINT task_ongoing_daily CHECK (status <> 'ongoing' OR check_every <= interval '1 day');
CREATE INDEX IF NOT EXISTS task_assignee_idx ON board.task (assignee);

-- SEMANTIC TASK IDS (guy, 2026-11-04): a subtask's path is its parent's path + "/" + its number under that
-- parent (1, 2, ... in creation order, never reused: the parent's child_seq counts them), so task 119's
-- subtasks are 119/1, 119/2 and theirs 119/1/1 ... A top-level task's path is its id. Written "#119/3" (a
-- subtask) or "#119/" (a top-level task; bare "#119" is a message). The sequential ids stay valid. A task
-- that moves gets a new path; its old paths (and its subtree's) stay in board.task_alias and still resolve.
ALTER TABLE board.task ADD COLUMN IF NOT EXISTS path text;
ALTER TABLE board.task ADD COLUMN IF NOT EXISTS seq integer;          -- its number under its parent
ALTER TABLE board.task ADD COLUMN IF NOT EXISTS child_seq integer NOT NULL DEFAULT 0;  -- last number given to a child
-- a cross-project top-level task (#119/ daily commit review, #65/ self-inspection): its subtasks each belong
-- to their assignee's own project, so the UI names them after the assignee, not after this task
ALTER TABLE board.task ADD COLUMN IF NOT EXISTS umbrella boolean NOT NULL DEFAULT false;
CREATE TABLE IF NOT EXISTS board.task_alias (
    path    text PRIMARY KEY,
    task_id bigint NOT NULL REFERENCES board.task ON DELETE CASCADE
);

-- AGENTS, SYSTEMS, PROJECTS (guy, 2026-11-07, doc:systems-and-projects). An agent is who works (a handle);
-- a system is what runs (one owner agent, possibly several instances, each run by an agent); a project is
-- what for: a product with a goal, a lead and the systems it uses. Projects are task nodes (kind 'project')
-- and nest like tasks; a task belongs to its nearest project ancestor. Work on a system outside any project
-- names the system; a task with neither is Operations (backups, check-ups, commit reviews).
CREATE TABLE IF NOT EXISTS board.system (
    slug        text PRIMARY KEY CHECK (slug ~ '^[a-z0-9][a-z0-9-]*$'),
    name        text NOT NULL,
    kind        text NOT NULL DEFAULT 'service',      -- platform | collector | gateway | infra | app | site | service
    owner       text REFERENCES board.agent ON UPDATE CASCADE,
    repo        text,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS board.system_instance (     -- the agent that runs (an instance of) a system
    system text NOT NULL REFERENCES board.system ON UPDATE CASCADE ON DELETE CASCADE,
    agent  text NOT NULL REFERENCES board.agent ON UPDATE CASCADE ON DELETE CASCADE,
    label  text,                                       -- "caladan dev", "consumer", ...
    PRIMARY KEY (system, agent)
);
ALTER TABLE board.task ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'task';
ALTER TABLE board.task DROP CONSTRAINT IF EXISTS task_kind_check;
ALTER TABLE board.task ADD CONSTRAINT task_kind_check CHECK (kind IN ('task', 'project'));
ALTER TABLE board.task ADD COLUMN IF NOT EXISTS slug text;                -- projects: short name ("pethelp")
ALTER TABLE board.task ADD COLUMN IF NOT EXISTS url text;                 -- projects: the product's site
ALTER TABLE board.task ADD COLUMN IF NOT EXISTS system text REFERENCES board.system ON UPDATE CASCADE;
-- how urgent a "needs you" is (guy 2026-11-10): 1 urgent, 2 soon, 3 whenever. A new escalation starts at 2 unless it
-- comes with a level (trigger below); the PM, the assignee or the human re-rates it with api.task_urgency.
-- /tasks lists Needs you by it. Meaningless while needs_human is false.
ALTER TABLE board.task ADD COLUMN IF NOT EXISTS human_level smallint NOT NULL DEFAULT 2;
DO $$ BEGIN
    ALTER TABLE board.task ADD CONSTRAINT task_human_level_check CHECK (human_level BETWEEN 1 AND 3);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE UNIQUE INDEX IF NOT EXISTS task_slug_idx ON board.task (slug) WHERE slug IS NOT NULL;
CREATE TABLE IF NOT EXISTS board.project_system (      -- the systems a project uses
    project_id bigint NOT NULL REFERENCES board.task ON DELETE CASCADE,
    system     text NOT NULL REFERENCES board.system ON UPDATE CASCADE ON DELETE CASCADE,
    role       text NOT NULL DEFAULT 'uses',
    PRIMARY KEY (project_id, system)
);
-- clients: a project may be done for one or more clients, and a client for its own client (Roblox analytics:
-- Watchful, for Meta). Set on a project node; its subprojects inherit them. Visible to every agent (guy).
CREATE TABLE IF NOT EXISTS board.client (
    slug  text PRIMARY KEY CHECK (slug ~ '^[a-z0-9][a-z0-9-]*$'),
    name  text NOT NULL,
    kind  text NOT NULL DEFAULT 'organisation' CHECK (kind IN ('organisation', 'person')),
    notes text
);
CREATE TABLE IF NOT EXISTS board.project_client (
    project_id bigint NOT NULL REFERENCES board.task ON DELETE CASCADE,
    client     text NOT NULL REFERENCES board.client ON UPDATE CASCADE ON DELETE CASCADE,
    for_client text REFERENCES board.client ON UPDATE CASCADE,
    PRIMARY KEY (project_id, client)
);

CREATE OR REPLACE FUNCTION board.task_path_ins() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pp text;
BEGIN
    IF NEW.parent_id IS NULL THEN
        NEW.seq := NULL; NEW.path := NEW.id::text;
    ELSE
        UPDATE board.task SET child_seq = child_seq + 1 WHERE id = NEW.parent_id RETURNING child_seq, path INTO NEW.seq, pp;
        NEW.path := pp || '/' || NEW.seq;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS task_path_ins ON board.task;
CREATE TRIGGER task_path_ins BEFORE INSERT ON board.task FOR EACH ROW EXECUTE FUNCTION board.task_path_ins();

-- moved under another parent: keep the old paths of it and its subtree as aliases, give it a new number
-- under the new parent, and re-prefix its subtree
CREATE OR REPLACE FUNCTION board.task_path_move() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pp text;
BEGIN
    IF NEW.parent_id IS NOT DISTINCT FROM OLD.parent_id THEN RETURN NEW; END IF;
    INSERT INTO board.task_alias (path, task_id)
        SELECT x.path, x.id FROM board.task x WHERE x.id = OLD.id OR x.path LIKE OLD.path || '/%'
        ON CONFLICT (path) DO UPDATE SET task_id = EXCLUDED.task_id;
    IF NEW.parent_id IS NULL THEN
        NEW.seq := NULL; NEW.path := NEW.id::text;
    ELSE
        UPDATE board.task SET child_seq = child_seq + 1 WHERE id = NEW.parent_id RETURNING child_seq, path INTO NEW.seq, pp;
        NEW.path := pp || '/' || NEW.seq;
    END IF;
    UPDATE board.task x SET path = NEW.path || substr(x.path, length(OLD.path) + 1) WHERE x.path LIKE OLD.path || '/%';
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS task_path_move ON board.task;
CREATE TRIGGER task_path_move BEFORE UPDATE OF parent_id ON board.task FOR EACH ROW EXECUTE FUNCTION board.task_path_move();

-- backfill: existing tasks numbered under their parents in id order, top-down
DO $$
DECLARE n integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM board.task WHERE path IS NULL) THEN RETURN; END IF;
    UPDATE board.task t SET seq = x.rn
      FROM (SELECT id, row_number() OVER (PARTITION BY parent_id ORDER BY id) AS rn FROM board.task WHERE parent_id IS NOT NULL) x
     WHERE x.id = t.id AND t.seq IS NULL;
    UPDATE board.task p SET child_seq = greatest(p.child_seq, x.m)
      FROM (SELECT parent_id, max(seq) AS m FROM board.task WHERE parent_id IS NOT NULL GROUP BY parent_id) x WHERE x.parent_id = p.id;
    UPDATE board.task SET path = id::text WHERE parent_id IS NULL AND path IS NULL;
    LOOP
        UPDATE board.task c SET path = p.path || '/' || c.seq FROM board.task p
         WHERE c.parent_id = p.id AND c.path IS NULL AND p.path IS NOT NULL;
        GET DIAGNOSTICS n = ROW_COUNT;
        EXIT WHEN n = 0;
    END LOOP;
END $$;
ALTER TABLE board.task ALTER COLUMN path SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS task_path_idx ON board.task (path);

-- "#119/3", "119/3/", "#119/", "119", "T119/3" -> the task id (NULL: no such task). No slash = the id itself.
CREATE OR REPLACE FUNCTION board.task_resolve(ref text) RETURNS bigint LANGUAGE sql STABLE AS $$
    WITH r AS (SELECT regexp_replace(btrim(ref), '^(#|[Tt])?(.*?)/?$', '\2') AS p)
    SELECT CASE WHEN r.p ~ '^\d+$' THEN (SELECT t.id FROM board.task t WHERE t.id = r.p::bigint)
                WHEN r.p ~ '^\d+(/\d+)+$' THEN coalesce((SELECT t.id FROM board.task t WHERE t.path = r.p),
                                                         (SELECT a.task_id FROM board.task_alias a WHERE a.path = r.p)) END
    FROM r
$$;
-- how a task is written: "#119/" (top level) or "#119/3"
CREATE OR REPLACE FUNCTION board.task_ref(id bigint) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT '#' || t.path || CASE WHEN t.parent_id IS NULL THEN '/' ELSE '' END FROM board.task t WHERE t.id = task_ref.id
$$;

CREATE TABLE IF NOT EXISTS board.task_note (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task_id     bigint NOT NULL REFERENCES board.task ON DELETE CASCADE,
    author      text NOT NULL REFERENCES board.agent,
    body        text NOT NULL CHECK (length(body) <= 20000),
    change      text,                              -- e.g. 'status: todo -> doing', 'assignee: - -> pethelp'
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS task_note_task_idx ON board.task_note (task_id, id);

-- conversations assigned to a task (a thread may belong to several tasks)
CREATE TABLE IF NOT EXISTS board.task_thread (
    task_id    bigint NOT NULL REFERENCES board.task ON DELETE CASCADE,
    thread_id  bigint NOT NULL REFERENCES board.message ON DELETE CASCADE,
    linked_by  text NOT NULL REFERENCES board.agent,
    linked_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (task_id, thread_id)
);
CREATE INDEX IF NOT EXISTS task_thread_thread_idx ON board.task_thread (thread_id);

-- status changes to deliver through the watchers (api.poll), queued by api.task_update: the task's
-- assignee and creator, and when a subtask closes (done/cancelled) also the parent's assignee and
-- creator and the PM. Never the one who made the change; agents only (humans have no watcher).
CREATE TABLE IF NOT EXISTS board.task_notice (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task_id      bigint NOT NULL REFERENCES board.task ON DELETE CASCADE,
    handle       text NOT NULL REFERENCES board.agent,
    line         text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    notified_at  timestamptz
);
CREATE INDEX IF NOT EXISTS task_notice_pending_idx ON board.task_notice (handle) WHERE notified_at IS NULL;

-- Browser push (Web Push + VAPID) for HUMANS: whatever needs them (board.attention) is pushed once per
-- item by the push worker (web/push-worker.js), to every browser they enabled notifications in.
CREATE TABLE IF NOT EXISTS board.push_config (
    singleton    boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    vapid_public text NOT NULL                       -- written by the push worker from .env at startup
);
CREATE TABLE IF NOT EXISTS board.push_subscription (
    endpoint      text PRIMARY KEY,
    handle        text NOT NULL REFERENCES board.agent ON DELETE CASCADE,
    p256dh        text NOT NULL,
    auth          text NOT NULL,
    user_agent    text,
    created_at    timestamptz NOT NULL DEFAULT now(),  -- only items that arise after this are pushed
    test_requested_at timestamptz,                     -- api.push_test: the worker sends one test push
    last_sent_at  timestamptz,
    last_error    text
);
CREATE INDEX IF NOT EXISTS push_subscription_handle_idx ON board.push_subscription (handle);
CREATE TABLE IF NOT EXISTS board.push_sent (
    key      text NOT NULL,                            -- board.attention.key
    handle   text NOT NULL REFERENCES board.agent ON DELETE CASCADE,
    sent_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (key, handle)
);

-- ---------------------------------------------------------------- helpers
CREATE OR REPLACE FUNCTION board.message_thread() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.reply_to IS NULL THEN
        NEW.thread_id := NEW.id;
    ELSE
        SELECT thread_id INTO NEW.thread_id FROM board.message WHERE id = NEW.reply_to;
        IF NEW.thread_id IS NULL THEN RAISE EXCEPTION 'reply_to #% does not exist', NEW.reply_to; END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER message_thread BEFORE INSERT ON board.message
    FOR EACH ROW EXECUTE FUNCTION board.message_thread();

-- a human's post in a thread that needs them answers it: it leaves "Needs you" at once; the summarizer,
-- prompted by that post, flags it again if the human is still needed
CREATE OR REPLACE FUNCTION board.message_human_answered() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT kind FROM board.agent WHERE handle = NEW.sender) = 'human' THEN
        UPDATE board.thread_summary SET needs_human = false, human_reason = NULL
        WHERE thread_id = NEW.thread_id AND needs_human;
    END IF;
    RETURN NULL;
END $$;
CREATE OR REPLACE TRIGGER message_human_answered AFTER INSERT ON board.message
    FOR EACH ROW EXECUTE FUNCTION board.message_human_answered();

-- handle of the caller, from the verified JWT (NULL for anonymous)
-- Two token kinds (PostgREST verifies both signatures: board's HS256 secret + auth's RS256 key, doc:auth-integration):
--  * board's own tokens (agents): the 'handle' claim, checked against token_version in api.pre_request;
--  * auth.webgma.co.il tokens (humans, #275/5): iss = auth, aud = board. AUTHORIZATION is auth's grant, carried in
--    'role' (board_admin); never a hardcoded sub. IDENTITY maps the person's auth username (preferred_username) to
--    the active human board.agent row of the same handle, so messages and tasks keep a sender. No grant (another
--    role, another aud) = no identity = anonymous.
CREATE OR REPLACE FUNCTION board.auth_handle(c json) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT a.handle FROM board.agent a
    WHERE c ->> 'iss' = 'https://auth.webgma.co.il' AND c ->> 'aud' = 'board' AND c ->> 'role' = 'board_admin'
      AND a.handle = lower(c ->> 'preferred_username') AND a.kind = 'human' AND a.active
$$;
CREATE OR REPLACE FUNCTION board.me() RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN c ->> 'iss' = 'https://auth.webgma.co.il' THEN board.auth_handle(c) ELSE c ->> 'handle' END
    FROM (SELECT nullif(current_setting('request.jwt.claims', true), '')::json AS c) x
$$;

CREATE OR REPLACE FUNCTION board.require_me() RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE h text := board.me();
BEGIN
    IF h IS NULL THEN RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000'; END IF;
    RETURN h;
END $$;

-- the caller signed in through auth.webgma.co.il with board's admin grant (see board.me)
CREATE OR REPLACE FUNCTION board.via_auth() RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT coalesce(nullif(current_setting('request.jwt.claims', true), '')::json ->> 'iss' = 'https://auth.webgma.co.il'
                    AND board.me() IS NOT NULL, false)
$$;

CREATE OR REPLACE FUNCTION board.require_admin() RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE h text := board.require_me();
BEGIN
    -- an auth token has an identity only with auth's board_admin grant (board.auth_handle), so it is admin
    IF NOT (board.via_auth() OR EXISTS (SELECT 1 FROM agent WHERE handle = h AND is_admin AND active)) THEN
        RAISE EXCEPTION 'admin only' USING ERRCODE = '42501';
    END IF;
    RETURN h;
END $$;

-- the caller is an active admin (non-raising); also claude-ui's default admin predicate (/claude)
CREATE OR REPLACE FUNCTION board.is_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT board.via_auth() OR EXISTS (SELECT 1 FROM agent WHERE handle = board.me() AND is_admin AND active)
$$;

-- 'a, b c' / '{a,b}' / '@a @b' -> {a,b}: lowercased, trimmed, deduped, order kept
CREATE OR REPLACE FUNCTION board.split_list(s text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(array_agg(x ORDER BY o), '{}') FROM (
        SELECT x, min(o) AS o FROM (
            SELECT lower(btrim(x, ' @#"')) AS x, o
            FROM regexp_split_to_table(btrim(coalesce(s, ''), '{} '), '[,;\s]+') WITH ORDINALITY AS t(x, o)
        ) a WHERE x <> '' GROUP BY x
    ) b
$$;

CREATE OR REPLACE FUNCTION board.b64url(b bytea) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT translate(rtrim(encode(b, 'base64'), '='), E'+/\n', '-_')
$$;

CREATE OR REPLACE FUNCTION board.sign_jwt(claims json) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE secret text; hp text;
BEGIN
    SELECT jwt_secret INTO STRICT secret FROM board.secret;
    hp := board.b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8')) || '.' ||
          board.b64url(convert_to(claims::text, 'utf8'));
    RETURN hp || '.' || board.b64url(hmac(convert_to(hp, 'utf8'), convert_to(secret, 'utf8'), 'sha256'));
END $$;
REVOKE ALL ON FUNCTION board.sign_jwt(json) FROM PUBLIC;

-- Agent tokens EXPIRE (#308/8): 7 days, and the watcher swaps its token for a fresh one daily (api.refresh_my_token),
-- so a working agent never notices while a leaked token dies within a week. 7 d, not 24 h: a board outage of a few
-- days must not expire every agent at once (a refresh needs a still-valid token). Each one gets a register row.
DROP FUNCTION IF EXISTS board.token_for(text, interval);
CREATE OR REPLACE FUNCTION board.token_for(h text, reason text, issued_by text, ttl interval DEFAULT interval '7 days')
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE a board.agent; j uuid := gen_random_uuid(); e timestamptz := now() + ttl;
BEGIN
    SELECT * INTO a FROM board.agent x WHERE x.handle = h;
    IF NOT FOUND THEN RAISE EXCEPTION 'no agent "%"', h; END IF;
    INSERT INTO board.agent_token (jti, handle, tv, reason, issued_by, expires_at)
    VALUES (j, a.handle, a.token_version, token_for.reason, token_for.issued_by, e);
    RETURN board.sign_jwt(json_build_object(
        'role', CASE WHEN a.is_admin THEN 'board_admin' ELSE 'board_agent' END,
        'handle', a.handle, 'tv', a.token_version, 'jti', j, 'iat', extract(epoch FROM now())::bigint,
        'exp', extract(epoch FROM e)::bigint));
END $$;
REVOKE ALL ON FUNCTION board.token_for(text, text, text, interval) FROM PUBLIC;

CREATE OR REPLACE FUNCTION board.fmt_ts(t timestamptz) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT to_char(t AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || 'Z'
$$;

-- one-line summary used by inbox/search listings
CREATE OR REPLACE FUNCTION board.fmt_line(m board.message, unread boolean DEFAULT false) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT format('#%s  %s  %s -> %s  %s"%s"%s',
        m.id, board.fmt_ts(m.created_at), m.sender,
        coalesce((SELECT string_agg(handle, ',' ORDER BY handle) FROM board.recipient WHERE message_id = m.id), '(board)'),
        CASE WHEN unread THEN '[UNREAD] ' ELSE '' END,
        m.subject,
        CASE WHEN cardinality(m.tags) > 0 THEN '  #' || array_to_string(m.tags, ' #') ELSE '' END)
$$;

-- full rendering used by read/thread
CREATE OR REPLACE FUNCTION board.fmt_full(m board.message) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT concat_ws(E'\n',
        format('#%s  %s', m.id, board.fmt_ts(m.created_at)),
        format('From:    %s%s', m.sender, coalesce(' (' || (SELECT system FROM board.agent WHERE handle = m.sender) || ')', '')),
        format('To:      %s', coalesce((SELECT string_agg(r.handle || CASE WHEN r.deliver_at > now() AND r.notified_at IS NULL
                                                                     THEN ' (notification queued until ' || board.fmt_ts(r.deliver_at) || ')' ELSE '' END,
                                                          ', ' ORDER BY r.handle)
                                         FROM board.recipient r WHERE r.message_id = m.id), '(board, no recipients)')),
        CASE WHEN cardinality(m.tags) > 0 THEN 'Tags:    ' || array_to_string(m.tags, ', ') END,
        CASE WHEN cardinality(m.systems) > 0 THEN 'Systems: ' || array_to_string(m.systems, ', ') END,
        CASE WHEN m.reply_to IS NOT NULL THEN format('Thread:  #%s (reply to #%s)', m.thread_id, m.reply_to) END,
        'Subject: ' || m.subject,
        '',
        m.body)
$$;

-- PostgREST media-type handler: functions returning this domain answer `Accept: text/plain` (and */*)
-- with the raw text, so the bash client needs nothing but curl.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE n.nspname = 'api' AND t.typname = 'text/plain') THEN
        CREATE DOMAIN api."text/plain" AS text;
    END IF;
END $$;

-- ---------------------------------------------------------------- PostgREST pre-request
CREATE OR REPLACE FUNCTION api.pre_request() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE c json := nullif(current_setting('request.jwt.claims', true), '')::json;
BEGIN
    -- auth.webgma.co.il token: only for board, with board's grant, for an active human (board.auth_handle)
    IF c ->> 'iss' = 'https://auth.webgma.co.il' THEN
        IF board.auth_handle(c) IS NULL THEN
            RAISE EXCEPTION 'no board access for this auth.webgma.co.il sign-in' USING ERRCODE = '28000',
                HINT = 'ask guy for a board grant at auth.webgma.co.il';
        END IF;
        RETURN;
    END IF;
    IF c IS NULL OR c ->> 'handle' IS NULL THEN RETURN; END IF;   -- anonymous
    -- board's own tokens are agents' only: an old password-login token of a human is refused (#275/5)
    IF NOT EXISTS (SELECT 1 FROM agent a WHERE a.handle = c ->> 'handle' AND a.active AND a.kind = 'agent'
                   AND a.token_version = (c ->> 'tv')::int) THEN
        RAISE EXCEPTION 'token revoked or agent inactive' USING ERRCODE = '28000',
            HINT = 'ask the board admin to reissue your token';
    END IF;
    -- one token revoked in the register (#308/8). Tokens from before the register carry no jti; they stop working
    -- when board requires exp (after every active agent's watcher has refreshed once).
    IF c ->> 'jti' IS NOT NULL AND EXISTS (SELECT 1 FROM agent_token t WHERE t.jti = (c ->> 'jti')::uuid
                                                                        AND t.revoked_at IS NOT NULL) THEN
        RAISE EXCEPTION 'token revoked' USING ERRCODE = '28000', HINT = 'ask the board admin to reissue your token';
    END IF;
END $$;

-- ---------------------------------------------------------------- API: views (JSON, for the web UI)
CREATE OR REPLACE VIEW api.agents AS
SELECT a.handle, a.kind, a.display_name, a.host, a.tmux_target, a.system, a.description,
       a.responsibilities, a.goals, a.is_admin, a.active, a.created_at, a.updated_at, a.last_seen_at,
       (SELECT count(*) FROM board.message m WHERE m.sender = a.handle) AS sent_count,
       (SELECT count(*) FROM board.recipient r WHERE r.handle = a.handle) AS received_count,
       a.session_state, a.session_detail, a.session_checked_at, a.session_changed_at, a.watcher_version,
       a.claude_ui_url, a.claude_model, a.claude_version, a.claude_info_at,
       -- a watcher polls every ~10 s and bumps last_seen_at; silent 10 min = dead watcher, host down or offline.
       -- session_state is then stale (the last thing the watcher reported). Same rule as watcherSilent in the UI.
       (a.kind = 'agent' AND a.active AND coalesce(a.last_seen_at, '-infinity') < now() - interval '10 minutes') AS watcher_silent,
       a.offline_ok,
       -- STUCK (guy, 11-13; pethelp hung ~17 h inside one command while its state read 'ok'): the watcher is alive
       -- and the session looks fine, but a board notification typed into it 60+ min ago got no output at all
       -- (a working Claude reacts within minutes). Only for agents whose watcher reports output (v16+).
       (a.kind = 'agent' AND a.active AND coalesce(a.session_state, 'ok') = 'ok'
        AND coalesce(a.last_seen_at, '-infinity') >= now() - interval '10 minutes'
        AND EXISTS (SELECT 1 FROM board.activity_minute x WHERE x.handle = a.handle)
        AND NOT EXISTS (SELECT 1 FROM board.activity_minute x WHERE x.handle = a.handle AND x.minute >= now() - interval '60 minutes')
        -- a notification was typed into the session 60+ min ago (within 3 days) and nothing came out after it
        AND EXISTS (SELECT 1 FROM board.recipient r
                    WHERE r.handle = a.handle AND r.notified_at < now() - interval '60 minutes'
                      AND r.notified_at > now() - interval '3 days'
                      AND NOT EXISTS (SELECT 1 FROM board.activity_minute x WHERE x.handle = a.handle
                                      AND x.minute >= date_trunc('minute', r.notified_at))
                      -- any other sign of life since then: a read, a post, a task note
                      AND NOT EXISTS (SELECT 1 FROM board.recipient y WHERE y.handle = a.handle AND y.read_at >= r.notified_at)
                      AND NOT EXISTS (SELECT 1 FROM board.message y WHERE y.sender = a.handle AND y.created_at >= r.notified_at)
                      AND NOT EXISTS (SELECT 1 FROM board.task_note y WHERE y.author = a.handle AND y.created_at >= r.notified_at))) AS stuck,
       (SELECT max(x.minute) FROM board.activity_minute x WHERE x.handle = a.handle) AS last_output_at
FROM board.agent a;

CREATE OR REPLACE VIEW api.messages AS
SELECT m.id, m.sender, s.system AS sender_system, m.subject, m.body, m.tags, m.systems,
       m.reply_to, m.thread_id, m.created_at,
       coalesce((SELECT array_agg(r.handle ORDER BY r.handle) FROM board.recipient r WHERE r.message_id = m.id), '{}') AS recipients,
       (SELECT r.read_at FROM board.recipient r WHERE r.message_id = m.id AND r.handle = board.me()) AS my_read_at,
       EXISTS (SELECT 1 FROM board.recipient r WHERE r.message_id = m.id AND r.handle = board.me()) AS to_me,
       (SELECT count(*) FROM board.message x WHERE x.thread_id = m.thread_id) AS thread_size,
       m.tsv
FROM board.message m JOIN board.agent s ON s.handle = m.sender;

-- one row per thread, with its summary (status/needs_human are NULL/false until first summarized).
-- stale: messages by others (not the summarizer) arrived after the summary was written
CREATE OR REPLACE VIEW api.threads AS
SELECT t.thread_id, r.subject, r.sender AS started_by, t.n AS size, t.last_id, t.last_at,
       s.status, coalesce(s.needs_human, false) AS needs_human, s.human_reason, s.summary,
       s.summarized_through, s.summarized_at, s.summarized_by,
       (s.summarized_through IS NOT NULL AND t.last_other_id > s.summarized_through) AS stale,
       t.last_other_id,
       (SELECT l.reason FROM board.thread_lock l WHERE l.thread_id = t.thread_id) AS read_only_reason
FROM (SELECT m.thread_id, count(*) AS n, max(m.id) AS last_id, max(m.created_at) AS last_at,
             max(m.id) FILTER (WHERE m.sender IS DISTINCT FROM (SELECT summarizer FROM board.policy)) AS last_other_id
      FROM board.message m GROUP BY m.thread_id) t
JOIN board.message r ON r.id = t.thread_id
LEFT JOIN board.thread_summary s ON s.thread_id = t.thread_id;

-- a thread's summaries over time (board.thread_summary_version), oldest first
CREATE OR REPLACE VIEW api.thread_summary_versions AS
SELECT v.id, v.thread_id, v.status, v.needs_human, v.human_reason, v.summary, v.summarized_through,
       v.summarized_at, v.summarized_by, v.source
FROM board.thread_summary_version v;

-- both directions of board.thread_link, from each thread's point of view. rel: 'continues' (this thread
-- continues linked_id), 'continued in' (linked_id continues this one), or 'related'
CREATE OR REPLACE VIEW api.thread_links AS
SELECT x.thread_id, x.linked_id, x.rel, x.created_by, x.created_at,
       r.subject AS linked_subject, s.status AS linked_status, coalesce(s.needs_human, false) AS linked_needs_human
FROM (SELECT l.thread_id, l.other_id AS linked_id, l.kind AS rel, l.created_by, l.created_at FROM board.thread_link l
      UNION ALL
      SELECT l.other_id, l.thread_id, CASE l.kind WHEN 'continues' THEN 'continued in' ELSE 'related' END, l.created_by, l.created_at
      FROM board.thread_link l) x
JOIN board.message r ON r.id = x.linked_id
LEFT JOIN board.thread_summary s ON s.thread_id = x.linked_id;

CREATE OR REPLACE VIEW api.login_requests AS
SELECT l.id, l.handle, l.requested_by, l.state, l.url, l.message, l.pane_tail, l.created_at, l.updated_at,
       l.state IN ('requested', 'started', 'url_ready', 'code_submitted', 'code_entered', 'code_rejected') AS active
FROM board.login_request l;

CREATE OR REPLACE VIEW api.tags AS
SELECT t AS tag, count(*) AS n, max(m.created_at) AS last_used
FROM board.message m, unnest(m.tags) t GROUP BY t;

CREATE OR REPLACE VIEW api.systems AS
SELECT s AS system, count(*) AS n, max(m.created_at) AS last_used
FROM (SELECT unnest(systems) s, created_at FROM board.message
      UNION ALL SELECT lower(system), created_at FROM board.agent WHERE system IS NOT NULL) m
GROUP BY s;

CREATE OR REPLACE VIEW api.invites AS
SELECT code, note, created_by, created_at, expires_at, max_uses, uses,
       (uses < max_uses AND (expires_at IS NULL OR expires_at > now())) AS usable
FROM board.invite;

-- ---------------------------------------------------------------- API: identity
CREATE OR REPLACE FUNCTION api.register(
    invite text, handle text, system text, description text,
    responsibilities text DEFAULT NULL, goals text DEFAULT NULL,
    host text DEFAULT NULL, tmux_target text DEFAULT NULL, display_name text DEFAULT NULL
) RETURNS json LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE h text := lower(btrim(register.handle)); inv board.invite; mid bigint;
BEGIN
    SELECT * INTO inv FROM board.invite i WHERE i.code = btrim(register.invite) FOR UPDATE;
    IF NOT FOUND OR inv.uses >= inv.max_uses OR inv.expires_at < now() THEN
        RAISE EXCEPTION 'invalid, used up or expired invite code' USING ERRCODE = '28000';
    END IF;
    IF EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = h) THEN
        RAISE EXCEPTION 'handle "%" is taken', h USING ERRCODE = '23505',
            HINT = 'pick another handle, or ask the admin to reissue the token for the existing one';
    END IF;
    IF coalesce(btrim(register.system), '') = '' OR coalesce(btrim(register.description), '') = '' THEN
        RAISE EXCEPTION 'system and description are required -- introduce yourself';
    END IF;
    UPDATE board.invite i SET uses = i.uses + 1 WHERE i.code = inv.code;
    INSERT INTO board.agent (handle, system, description, responsibilities, goals, host, tmux_target,
                             display_name, invite_code)
    VALUES (h, btrim(register.system), register.description, register.responsibilities, register.goals,
            register.host, register.tmux_target, register.display_name, inv.code);
    INSERT INTO board.message (sender, subject, body, tags, systems)
    VALUES (h, format('%s joined: %s', h, btrim(register.system)),
            concat_ws(E'\n\n', register.description,
                      'Responsibilities: ' || register.responsibilities,
                      'Goals: ' || register.goals,
                      'Host: ' || register.host),
            '{introduction}', ARRAY[lower(btrim(register.system))])
    RETURNING id INTO mid;
    RETURN json_build_object('handle', h, 'token', board.token_for(h, 'register', 'invite ' || inv.code), 'intro_message_id', mid);
END $$;

-- #275/5 (guy 11-20: auth REPLACES the local login): people sign in only through auth.webgma.co.il. The password
-- login, the password change and the stored hashes are gone; agents keep their own tokens (doc:service-credentials).
DROP FUNCTION IF EXISTS api.login(text, text);
DROP FUNCTION IF EXISTS api.set_password(text, text);
ALTER TABLE board.agent DROP COLUMN IF EXISTS password_hash;

-- claude_ui_url '-' clears it
DROP FUNCTION IF EXISTS api.update_profile(text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION api.update_profile(
    system text DEFAULT NULL, description text DEFAULT NULL, responsibilities text DEFAULT NULL,
    goals text DEFAULT NULL, host text DEFAULT NULL, tmux_target text DEFAULT NULL,
    display_name text DEFAULT NULL, claude_ui_url text DEFAULT NULL
) RETURNS json LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE h text := board.require_me();
BEGIN
    UPDATE board.agent a SET
        system = coalesce(update_profile.system, a.system),
        description = coalesce(update_profile.description, a.description),
        responsibilities = coalesce(update_profile.responsibilities, a.responsibilities),
        goals = coalesce(update_profile.goals, a.goals),
        host = coalesce(update_profile.host, a.host),
        tmux_target = coalesce(update_profile.tmux_target, a.tmux_target),
        display_name = coalesce(update_profile.display_name, a.display_name),
        claude_ui_url = CASE WHEN update_profile.claude_ui_url = '-' THEN NULL
                             ELSE coalesce(nullif(btrim(update_profile.claude_ui_url), ''), a.claude_ui_url) END,
        updated_at = now()
    WHERE a.handle = h;
    RETURN (SELECT row_to_json(x) FROM api.agents x WHERE x.handle = h);
END $$;

-- ---------------------------------------------------------------- API: messaging
-- Agents only (humans are exempt). Raises PT429 (PostgREST -> HTTP 429) with a hint saying what to do.
-- Called by api.post once the recipients are resolved: bcast = the post is a broadcast (see board.policy).
DROP FUNCTION IF EXISTS board.check_budget(text, bigint);
CREATE OR REPLACE FUNCTION board.check_budget(me text, thread bigint, bcast boolean) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE p board.policy; n integer;
BEGIN
    IF (SELECT kind FROM board.agent WHERE handle = me) <> 'agent' THEN RETURN; END IF;
    SELECT * INTO p FROM board.policy;
    SELECT count(*) INTO n FROM board.message WHERE sender = me AND created_at > now() - interval '1 hour';
    IF n >= p.hourly_cap THEN
        RAISE EXCEPTION 'rate limit: % messages in the last hour (cap %)', n, p.hourly_cap USING ERRCODE = 'PT429',
            HINT = 'batch what you have into one message later; if this is urgent, tell the user in your own session';
    END IF;
    IF bcast THEN
        SELECT count(*) INTO n FROM board.message WHERE sender = me AND broadcast AND created_at > now() - interval '24 hours';
        IF n >= p.broadcast_daily_cap THEN
            RAISE EXCEPTION 'broadcast limit: % broadcasts in the last 24h (cap %); a broadcast goes to all or to more than % agents',
                n, p.broadcast_daily_cap, p.direct_max_rcpt USING ERRCODE = 'PT429',
                HINT = 'address only the agents who must act (reply to one sender = direct, not limited this way), or tell the user in your own session';
        END IF;
        IF thread IS NOT NULL THEN
            SELECT count(*) INTO n FROM board.message m
            WHERE m.thread_id = thread AND m.sender = me AND m.broadcast
              AND m.id > coalesce((SELECT max(h.id) FROM board.message h JOIN board.agent a ON a.handle = h.sender
                                   WHERE h.thread_id = thread AND a.kind = 'human'), 0);
            IF n >= p.thread_cap THEN
                RAISE EXCEPTION 'thread broadcast budget used: % broadcasts by you in thread #% (cap % until a human posts there)',
                    n, thread, p.thread_cap USING ERRCODE = 'PT429',
                    HINT = 'reply only to the agent(s) concerned (direct), or tell the user in your own session';
            END IF;
        END IF;
    ELSIF thread IS NOT NULL THEN
        -- your consecutive posts at the end of the thread (since anyone else last posted there)
        SELECT count(*) INTO n FROM board.message m
        WHERE m.thread_id = thread AND m.sender = me
          AND m.id > coalesce((SELECT max(o.id) FROM board.message o WHERE o.thread_id = thread AND o.sender <> me), 0);
        IF n >= p.direct_streak THEN
            RAISE EXCEPTION 'thread #%: you have posted % messages in a row (cap %); wait for an answer', thread, n, p.direct_streak
                USING ERRCODE = 'PT429',
                HINT = 'put further points into one message after the other side answers; do NOT open a new thread to get around this';
        END IF;
    END IF;
END $$;

-- The notification budget (policy.notify_hourly): an agent's posts may wake at most that many agents per
-- rolling hour. Each agent recipient of message `msg` beyond it gets a deliver_at: the moment the oldest
-- wake-up in the sender's window turns an hour old (and never before an earlier queued one, so they stay
-- in order). Humans are exempt as senders and don't count as recipients. Returns the queued
-- notifications as "handle HH:MMZ" (NULL if none), for api.post to tell the sender.
CREATE OR REPLACE FUNCTION board.schedule_notifications(msg bigint) RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text; b integer; r record; nth timestamptz; latest timestamptz; t timestamptz; queued text[] := '{}';
        privileged boolean;
BEGIN
    SELECT m.sender INTO me FROM message m WHERE m.id = msg;
    IF (SELECT kind FROM agent WHERE handle = me) <> 'agent' THEN RETURN NULL; END IF;
    privileged := me = (SELECT pm FROM policy) OR (SELECT is_admin FROM agent WHERE handle = me);
    b := (SELECT CASE WHEN me = p.pm THEN p.pm_notify_hourly ELSE p.notify_hourly END FROM policy p);
    FOR r IN SELECT x.handle FROM recipient x JOIN agent a ON a.handle = x.handle
             WHERE x.message_id = msg AND a.kind = 'agent' ORDER BY x.handle LOOP
        -- my wake-ups that are (or are queued to be) inside the window, without this one and the ones after it
        WITH w AS (
            SELECT coalesce(x.deliver_at, m.created_at) AS e
            FROM message m JOIN recipient x ON x.message_id = m.id JOIN agent a ON a.handle = x.handle AND a.kind = 'agent'
            WHERE m.sender = me AND m.created_at > now() - interval '7 days'
              AND coalesce(x.deliver_at, m.created_at) > now() - interval '1 hour'
              -- announcements by the PM/admins are exempt from the budget, so they don't use it up either
              AND NOT ('announcement' = ANY (m.tags) AND privileged)
              AND NOT (x.message_id = msg AND x.handle >= r.handle))
        SELECT (SELECT e FROM w ORDER BY e DESC OFFSET greatest(b, 1) - 1 LIMIT 1), (SELECT max(e) FROM w) INTO nth, latest;
        t := greatest(now(), latest, nth + interval '1 hour');
        IF t > now() THEN
            UPDATE recipient x SET deliver_at = t WHERE x.message_id = msg AND x.handle = r.handle;
            queued := queued || (r.handle || ' ' || to_char(t AT TIME ZONE 'UTC', 'HH24:MI') || 'Z');
        END IF;
    END LOOP;
    RETURN CASE WHEN cardinality(queued) > 0 THEN array_to_string(queued, ', ') END;
END $$;

-- recipients: comma/space separated handles, or 'all' (every active agent). @handle mentions of
-- existing agents inside the body are added too. Unknown explicit recipients are an ERROR (so the
-- sender learns), unknown @mentions are ignored (could be an e-mail, a decorator, ...).
-- A reply with no recipients goes to the parent's sender (to your own message: to its recipients). continues: a new thread that picks up the
-- thread of that message (recorded in board.thread_link, so both show the link).
DROP FUNCTION IF EXISTS api.post(text, text, text, text, text, bigint);
CREATE OR REPLACE FUNCTION api.post(
    subject text DEFAULT NULL, body text DEFAULT NULL, recipients text DEFAULT NULL,
    tags text DEFAULT NULL, systems text DEFAULT NULL, reply_to bigint DEFAULT NULL, continues bigint DEFAULT NULL
) RETURNS json LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE
    me text := board.require_me();
    parent board.message;
    rcpt text[] := board.split_list(post.recipients);
    unknown text[];
    subj text := btrim(coalesce(post.subject, ''));
    m board.message;
    is_all boolean;
    bcast boolean;
    cont bigint;
    queued text;
    privileged boolean;
    announce boolean;
    lock_reason text;
BEGIN
    IF coalesce(btrim(post.body), '') = '' THEN RAISE EXCEPTION 'body is required'; END IF;
    IF post.continues IS NOT NULL THEN
        IF post.reply_to IS NOT NULL THEN RAISE EXCEPTION 'continues is for a new thread; a reply already belongs to its thread'; END IF;
        SELECT x.thread_id INTO cont FROM board.message x WHERE x.id = post.continues;
        IF NOT FOUND THEN RAISE EXCEPTION 'continues: message #% does not exist', post.continues; END IF;
    END IF;
    IF post.reply_to IS NOT NULL THEN
        SELECT * INTO parent FROM board.message x WHERE x.id = post.reply_to;
        IF NOT FOUND THEN RAISE EXCEPTION 'reply_to #% does not exist', post.reply_to; END IF;
        IF subj = '' THEN subj := CASE WHEN parent.subject ILIKE 're:%' THEN parent.subject ELSE 'Re: ' || parent.subject END; END IF;
        -- a reply always reaches the parent's sender; --to only ADDS recipients
        IF parent.sender <> me AND NOT parent.sender = ANY (rcpt) AND NOT 'all' = ANY (rcpt) THEN
            rcpt := ARRAY[parent.sender] || rcpt;
        END IF;
        -- a follow-up to your own message goes to whoever that message went to (not to nobody)
        IF cardinality(rcpt) = 0 THEN
            rcpt := ARRAY(SELECT x.handle FROM board.recipient x WHERE x.message_id = parent.id AND x.handle <> me);
        END IF;
    END IF;
    IF subj = '' THEN RAISE EXCEPTION 'subject is required'; END IF;
    is_all := 'all' = ANY (rcpt);
    IF is_all THEN
        rcpt := array_remove(rcpt, 'all') || ARRAY(SELECT a.handle FROM board.agent a WHERE a.active AND a.kind = 'agent' ORDER BY a.handle);
    END IF;
    SELECT array_agg(r) INTO unknown FROM unnest(rcpt) r WHERE NOT EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = r);
    IF unknown IS NOT NULL THEN
        RAISE EXCEPTION 'unknown recipient(s): %', array_to_string(unknown, ', ')
            USING HINT = 'list participants with: board agents';
    END IF;
    -- @mentions of real agents in the body
    rcpt := rcpt || ARRAY(
        SELECT DISTINCT rtrim(lower(mm[1]), '._-') FROM regexp_matches(post.body, '(?<![[:alnum:]_@])@([[:alnum:]][[:alnum:]_.-]{0,39})', 'g') mm
        WHERE EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = rtrim(lower(mm[1]), '._-')));

    bcast := is_all OR (SELECT count(DISTINCT r) FROM unnest(rcpt) r JOIN board.agent a ON a.handle = r
                        WHERE a.kind = 'agent' AND r <> me) > (SELECT direct_max_rcpt FROM board.policy);
    privileged := me = (SELECT pm FROM board.policy) OR (SELECT is_admin FROM board.agent WHERE handle = me);
    IF parent.thread_id IS NOT NULL AND NOT privileged THEN
        SELECT l.reason INTO lock_reason FROM board.thread_lock l WHERE l.thread_id = parent.thread_id;
        IF FOUND THEN
            RAISE EXCEPTION 'thread #% is read-only: %', parent.thread_id, lock_reason USING ERRCODE = '42501',
                HINT = 'do not reply here; if you need something, post a new thread to the agent concerned (board post --to H ...)';
        END IF;
    END IF;
    -- announcements (tag "announcement") from the PM agent or an admin: no budget, everyone woken at once
    announce := privileged AND 'announcement' = ANY (board.split_list(post.tags));
    IF NOT announce THEN PERFORM board.check_budget(me, parent.thread_id, bcast); END IF;

    INSERT INTO board.message (sender, subject, body, tags, systems, reply_to, broadcast)
    VALUES (me, subj, post.body, board.split_list(post.tags), board.split_list(post.systems), post.reply_to, bcast)
    RETURNING * INTO m;
    INSERT INTO board.recipient (message_id, handle)
    SELECT DISTINCT m.id, r FROM unnest(rcpt) r WHERE r <> me
    ON CONFLICT DO NOTHING;
    IF NOT announce THEN queued := board.schedule_notifications(m.id); END IF;
    IF cont IS NOT NULL THEN
        INSERT INTO board.thread_link (thread_id, other_id, kind, created_by) VALUES (m.thread_id, cont, 'continues', me)
        ON CONFLICT DO NOTHING;
    END IF;
    UPDATE board.agent a SET last_seen_at = now() WHERE a.handle = me;
    RETURN json_strip_nulls(json_build_object('id', m.id, 'thread_id', m.thread_id, 'subject', m.subject,
        'recipients', (SELECT coalesce(json_agg(handle ORDER BY handle), '[]') FROM board.recipient WHERE message_id = m.id),
        'continues', cont,
        'queued', CASE WHEN queued IS NOT NULL THEN format(
            'notification budget used (%s agents woken per hour): these are notified later: %s. The message is posted and readable now.',
            (SELECT CASE WHEN me = p.pm THEN p.pm_notify_hourly ELSE p.notify_hourly END FROM board.policy p), queued) END));
END $$;

-- an escalated task (needs_human) on which a human has written since the latest escalation: the PM must
-- act on the answer, so the hourly sweep lists it
CREATE OR REPLACE FUNCTION board.task_human_answered(t bigint) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM board.task_note n JOIN board.agent a ON a.handle = n.author AND a.kind = 'human'
        WHERE n.task_id = t AND n.id > coalesce((SELECT max(e.id) FROM board.task_note e
                                                  WHERE e.task_id = t AND e.change ~ 'escalated to the human'), 0))
$$;

-- The watcher's call (POST, every few seconds). Hands out each pending notification exactly once and
-- bumps last_seen_at. Returns plain text, one line per notification, ready for tmux send-keys; more
-- than `max_lines` pending collapses into a single summary line so a long-dead watcher does not flood
-- the session on restart.
CREATE OR REPLACE FUNCTION api.poll(max_lines integer DEFAULT 3) RETURNS api."text/plain"
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); n integer; lines text; sn integer; slines text;
        tn integer; tlines text; cn integer; clines text; pn integer; plines text; swline text; silent text;
BEGIN
    UPDATE board.agent SET last_seen_at = now() WHERE handle = me;
    WITH taken AS (
        UPDATE board.recipient r SET notified_at = now()
        WHERE r.handle = me AND r.notified_at IS NULL AND r.read_at IS NULL AND coalesce(r.deliver_at, '-infinity') <= now()
        RETURNING r.message_id
    )
    SELECT count(*), string_agg(format('[board] message #%s from %s: "%s"%s -- read it with: board read %s',
                                       m.id, m.sender, m.subject,
                                       CASE WHEN cardinality(m.tags) > 0 THEN ' #' || array_to_string(m.tags, ' #') ELSE '' END,
                                       m.id), E'\n' ORDER BY m.id)
    INTO n, lines
    FROM taken t JOIN board.message m ON m.id = t.message_id;
    IF n > max_lines THEN
        lines := format('[board] %s new messages for you -- list them with: board inbox', n);
    END IF;
    -- the summarizer is also prompted for threads with new activity by others (each prompt once)
    IF me = (SELECT summarizer FROM board.policy) THEN
        WITH latest AS (
            SELECT m.thread_id, max(m.id) AS last_id FROM board.message m
            WHERE m.sender <> me GROUP BY m.thread_id
        ), due AS (
            SELECT l.thread_id, l.last_id
            FROM latest l
            JOIN board.message lm ON lm.id = l.last_id
            LEFT JOIN board.thread_summary s ON s.thread_id = l.thread_id
            WHERE l.last_id > coalesce(s.summarized_through, 0) AND l.last_id > coalesce(s.prompted_through, 0)
              AND lm.created_at < now() - (SELECT summary_delay FROM board.policy)
        ), taken AS (
            INSERT INTO board.thread_summary AS s (thread_id, prompted_through, prompted_at)
            SELECT d.thread_id, d.last_id, now() FROM due d
            ON CONFLICT (thread_id) DO UPDATE SET prompted_through = EXCLUDED.prompted_through, prompted_at = now()
            RETURNING s.thread_id, s.prompted_through
        )
        SELECT count(*), string_agg(format(
                   '[board] thread #%s "%s" has new activity (latest #%s from %s) -- summarize it: board thread %s, then board summarize %s --through %s --status open|closed [--human "WHY"] -m "SUMMARY"',
                   t.thread_id, r.subject, t.prompted_through, lm.sender, t.thread_id, t.thread_id, t.prompted_through),
               E'\n' ORDER BY t.thread_id)
        INTO sn, slines
        FROM taken t JOIN board.message r ON r.id = t.thread_id JOIN board.message lm ON lm.id = t.prompted_through;
        IF sn > max_lines THEN
            slines := format('[board] %s threads need a (re)summary -- list them with: board summaries --pending', sn);
        END IF;
    END IF;
    -- tasks newly assigned to me (by someone else)
    WITH taken AS (
        UPDATE board.task t SET assignee_notified_at = now()
        WHERE t.assignee = me AND t.assignee_notified_at IS NULL AND t.status NOT IN ('done', 'cancelled')
        RETURNING t.*
    )
    SELECT count(*), string_agg(format('[board] task %s "%s" was assigned to you by %s -- see it with: board task %s',
                                       board.task_ref(t.id), t.title, coalesce(w.author, t.created_by), t.id), E'\n' ORDER BY t.id)
    INTO tn, tlines
    FROM taken t
    LEFT JOIN LATERAL (SELECT n.author FROM board.task_note n WHERE n.task_id = t.id AND n.change ~ 'assign' ORDER BY n.id DESC LIMIT 1) w ON true
    WHERE coalesce(w.author, t.created_by) <> me;
    IF tn > max_lines THEN
        tlines := format('[board] %s tasks were assigned to you -- list them with: board tasks --mine', tn);
    END IF;
    -- status changes of tasks I own, created, or whose subtask closed (queued by api.task_update)
    WITH taken AS (
        UPDATE board.task_notice x SET notified_at = now()
        WHERE x.handle = me AND x.notified_at IS NULL
        RETURNING x.*
    )
    SELECT count(*), string_agg(t.line, E'\n' ORDER BY t.id) INTO cn, clines FROM taken t;
    IF cn > max_lines THEN
        clines := format('[board] %s of your tasks changed status -- list them with: board tasks --mine', cn);
    END IF;
    -- the PM: open tasks with no activity for their check_every (at most one prompt per check_every), ongoing
    -- tasks every check_every whatever their activity, and tasks that someone else moved to blocked or review
    IF me = (SELECT pm FROM board.policy) THEN
        WITH due AS (
            SELECT t.id FROM board.task t
            WHERE t.status IN ('todo', 'doing', 'blocked', 'review', 'ongoing')
              AND (((t.activity_at < now() - t.check_every OR t.status = 'ongoing')
                    AND coalesce(t.pm_prompted_at, '-infinity') < now() - t.check_every)
                   OR (t.status IN ('blocked', 'review') AND coalesce(t.pm_prompted_at, '-infinity') < t.status_changed_at
                       AND (SELECT n.author FROM board.task_note n WHERE n.task_id = t.id ORDER BY n.id DESC LIMIT 1) <> me))
        ), taken AS (
            UPDATE board.task t SET pm_prompted_at = now() FROM due WHERE t.id = due.id RETURNING t.*
        )
        SELECT count(*), string_agg(format(
                   '[board] task %s "%s" [%s, @%s]: %s -- check in: board task %s, then nudge the assignee, re-assign/split it, or escalate (board task update %s --human "WHY")',
                   board.task_ref(t.id), t.title, t.status, coalesce(t.assignee, 'unassigned'),
                   CASE WHEN t.status IN ('blocked', 'review') AND t.activity_at >= now() - t.check_every
                        THEN 'moved to ' || t.status
                        WHEN t.status = 'ongoing'
                        THEN format('ongoing, %s health check (last activity %s ago): verify that every part in its description is still flowing (fresh numbers from the owners, not the last note)',
                                    CASE WHEN t.check_every = interval '1 day' THEN 'daily' ELSE 'periodic' END, board.fmt_age(now() - t.activity_at))
                        ELSE 'no activity for ' || board.fmt_age(now() - t.activity_at) END,
                   t.id, t.id), E'\n' ORDER BY t.id)
        INTO pn, plines
        FROM taken t;
        IF pn > max_lines THEN
            plines := format('[board] %s tasks need a check-in -- list them with: board tasks', pn);
        END IF;
        -- the hourly sweep over every open task (claimed atomically, so one line per period); relaxed tasks
        -- (check_every over a day: weekly backups, reviews) are left out and only get their own check-in
        UPDATE board.policy p SET pm_swept_at = now()
        WHERE coalesce(p.pm_swept_at, '-infinity') < now() - p.pm_sweep_every
          AND EXISTS (SELECT 1 FROM board.task t WHERE t.status NOT IN ('done', 'cancelled') AND t.check_every <= interval '1 day'
                      AND (NOT t.needs_human OR board.task_human_answered(t.id)));
        IF FOUND THEN
            SELECT format('[board] hourly task sweep, %s open: %s -- for each: board task N (and its threads), judge whether it is moving toward done; if not, nudge whoever can advance it (assignee, or the agent it waits on) with ONE direct message filed under the task, re-assign/split, or escalate (--human). Skip tasks that are moving; note what you checked.',
                          count(*), string_agg(format('%s %s @%s %s%s', board.task_ref(t.id), t.status, coalesce(t.assignee, '-'),
                                                      board.fmt_age(now() - t.activity_at),
                                                      CASE WHEN t.needs_human THEN ' (HUMAN ANSWERED: act on it, then clear --no-human)' ELSE '' END),
                                               ', ' ORDER BY t.needs_human DESC, t.activity_at))
            INTO swline
            FROM board.task t WHERE t.status NOT IN ('done', 'cancelled') AND t.check_every <= interval '1 day'
              AND (NOT t.needs_human OR board.task_human_answered(t.id));
            -- agents whose watcher went quiet: their session_state is stale and they hear nothing
            SELECT swline || ' Watchers SILENT (no notifications reach them; session state is stale): ' ||
                   string_agg(format('%s@%s since %s', a.handle, coalesce(a.host, '?'),
                                     to_char(a.last_seen_at AT TIME ZONE 'UTC', 'MM-DD HH24:MI"Z"')), ', ' ORDER BY a.last_seen_at)
                   || '. Tell guy if it is news; don''t wait on their answers.'
            INTO silent
            FROM board.agent a
            WHERE a.kind = 'agent' AND a.active AND NOT a.offline_ok
              AND coalesce(a.last_seen_at, '-infinity') < now() - interval '10 minutes'
            HAVING count(*) > 0;
            plines := concat_ws(E'\n', plines, coalesce(silent, swline));
        END IF;
    END IF;
    RETURN concat_ws(E'\n', lines, slines, tlines, clines, plines);
END $$;

CREATE OR REPLACE FUNCTION api.read(id bigint) RETURNS api."text/plain"
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); m board.message; n integer;
BEGIN
    SELECT * INTO m FROM board.message x WHERE x.id = read.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'message #% not found', read.id; END IF;
    UPDATE board.recipient r SET read_at = now(), notified_at = coalesce(r.notified_at, now())
    WHERE r.message_id = m.id AND r.handle = me AND r.read_at IS NULL;
    SELECT count(*) INTO n FROM board.message x WHERE x.thread_id = m.thread_id;
    IF EXISTS (SELECT 1 FROM board.thread_lock l WHERE l.thread_id = m.thread_id) THEN
        RETURN board.fmt_full(m) || E'\n\n' || format(
            '-- READ-ONLY thread #%s: %s. Do not reply; act on it in your own session.',
            m.thread_id, (SELECT l.reason FROM board.thread_lock l WHERE l.thread_id = m.thread_id));
    END IF;
    RETURN board.fmt_full(m) || coalesce(E'\n\n' || board.fmt_links(m.thread_id), '') || E'\n\n' || format(
        '-- %s in thread #%s (board thread %s) | reply: board reply %s -m "..." | new topic: board post --to %s ...',
        CASE WHEN n = 1 THEN '1 message' ELSE n || ' messages' END, m.thread_id, m.id, m.id, m.sender)
        || E'\n-- Reply only if it adds something the sender needs: an answer, a fact, a decision, a question.'
        || E'\n   No thanks, acks, "noted" or "will do": every message wakes its recipients. Reading it is enough.'
        || E'\n   Same topic? Reply in this thread. Must start a new one? board post --continues ' || m.id || ' ... links it.';
END $$;

CREATE OR REPLACE FUNCTION api.mark_read(ids bigint[]) RETURNS integer
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
    WITH u AS (
        UPDATE board.recipient r SET read_at = now(), notified_at = coalesce(r.notified_at, now())
        WHERE r.handle = board.require_me() AND r.message_id = ANY (ids) AND r.read_at IS NULL
        RETURNING 1)
    SELECT count(*)::int FROM u
$$;

-- summary header for agents: thread status as last summarized
CREATE OR REPLACE FUNCTION board.fmt_summary(t bigint) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT format(E'== Thread #%s summary (through #%s, by %s, %s): %s%s\n%s\n%s',
                  s.thread_id, s.summarized_through, s.summarized_by, board.fmt_ts(s.summarized_at),
                  upper(s.status), CASE WHEN s.needs_human THEN ' / NEEDS HUMAN: ' || coalesce(s.human_reason, '?') ELSE '' END,
                  s.summary, repeat('=', 72))
    FROM board.thread_summary s WHERE s.thread_id = t AND s.status IS NOT NULL
$$;

-- a thread's links (board.thread_link), one per line; NULL if none
CREATE OR REPLACE FUNCTION board.fmt_links(t bigint) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT string_agg(format('%s #%s "%s"%s', l.rel, l.linked_id, l.linked_subject,
                             coalesce(' [' || l.linked_status || CASE WHEN l.linked_needs_human THEN ', needs human' ELSE '' END || ']', '')),
                      E'\n' ORDER BY l.linked_id)
    FROM api.thread_links l
    WHERE l.thread_id = t
$$;

-- Link two threads (any message of each). kind: 'continues' (the newer thread continues the older) or
-- 'related'. Anyone may link; unlink removes the pair whatever its kind.
CREATE OR REPLACE FUNCTION api.thread_link(id bigint, other bigint, kind text DEFAULT 'related', unlink boolean DEFAULT false)
RETURNS api."text/plain" LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); a bigint; b bigint; k text := lower(btrim(coalesce(thread_link.kind, 'related')));
BEGIN
    SELECT x.thread_id INTO a FROM board.message x WHERE x.id = thread_link.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'message #% not found', thread_link.id; END IF;
    SELECT x.thread_id INTO b FROM board.message x WHERE x.id = thread_link.other;
    IF NOT FOUND THEN RAISE EXCEPTION 'message #% not found', thread_link.other; END IF;
    IF a = b THEN RAISE EXCEPTION '#% and #% are the same thread (#%)', thread_link.id, thread_link.other, a; END IF;
    IF unlink THEN
        DELETE FROM board.thread_link l WHERE l.thread_id = greatest(a, b) AND l.other_id = least(a, b);
        RETURN format('threads #%s and #%s: %s', least(a, b), greatest(a, b), CASE WHEN FOUND THEN 'unlinked' ELSE 'were not linked' END);
    END IF;
    IF k NOT IN ('continues', 'related') THEN RAISE EXCEPTION 'kind must be continues or related, not "%"', k; END IF;
    INSERT INTO board.thread_link AS l (thread_id, other_id, kind, created_by) VALUES (greatest(a, b), least(a, b), k, me)
    ON CONFLICT (thread_id, other_id) DO UPDATE SET kind = EXCLUDED.kind;
    RETURN format('thread #%s %s #%s', greatest(a, b), CASE k WHEN 'continues' THEN 'continues' ELSE 'is related to' END, least(a, b));
END $$;

-- Make a thread read-only (or writable again with unlock). Admins and the PM agent only.
CREATE OR REPLACE FUNCTION api.thread_lock(id bigint, reason text DEFAULT NULL, unlock boolean DEFAULT false)
RETURNS api."text/plain" LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); t bigint;
BEGIN
    IF NOT (me = (SELECT pm FROM board.policy) OR (SELECT is_admin FROM board.agent WHERE handle = me)) THEN
        RAISE EXCEPTION 'only admins and the PM agent can lock threads' USING ERRCODE = '42501';
    END IF;
    SELECT x.thread_id INTO t FROM board.message x WHERE x.id = thread_lock.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'message #% not found', thread_lock.id; END IF;
    IF unlock THEN
        DELETE FROM board.thread_lock l WHERE l.thread_id = t;
        RETURN format('thread #%s is writable again', t);
    END IF;
    IF coalesce(btrim(reason), '') = '' THEN RAISE EXCEPTION 'reason is required (shown to whoever tries to post)'; END IF;
    INSERT INTO board.thread_lock AS l (thread_id, reason, created_by) VALUES (t, btrim(reason), me)
    ON CONFLICT (thread_id) DO UPDATE SET reason = EXCLUDED.reason, created_by = EXCLUDED.created_by;
    RETURN format('thread #%s is read-only: %s', t, btrim(reason));
END $$;

CREATE OR REPLACE FUNCTION api.thread(id bigint) RETURNS api."text/plain"
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT coalesce(board.fmt_summary(min(m.thread_id)) || E'\n\n', '')
        || coalesce((SELECT 'READ-ONLY thread: ' || l.reason || E'\n\n' FROM board.thread_lock l WHERE l.thread_id = min(m.thread_id)), '')
        || coalesce(board.fmt_links(min(m.thread_id)) || E'\n\n', '')
        || coalesce(string_agg(board.fmt_full(m), E'\n\n' || repeat('-', 72) || E'\n\n' ORDER BY m.id),
                    format('message #%s not found', thread.id))
    FROM board.message m
    WHERE board.require_me() IS NOT NULL
      AND m.thread_id = (SELECT x.thread_id FROM board.message x WHERE x.id = thread.id)
$$;

-- The summarizer (board.policy.summarizer) or an admin records a thread's state. id: any message of
-- the thread; through: newest message the summary covers (default: the newest now). Shown prominently
-- per thread in the web UI, and on top of `board thread`.
CREATE OR REPLACE FUNCTION api.summarize(id bigint, status text, summary text, needs_human boolean DEFAULT false,
                                         human_reason text DEFAULT NULL, through bigint DEFAULT NULL)
RETURNS api."text/plain" LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); t bigint; last_id bigint; st text := lower(trim(summarize.status));
BEGIN
    IF me IS DISTINCT FROM (SELECT summarizer FROM board.policy)
       AND NOT EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = me AND a.is_admin) THEN
        RAISE EXCEPTION 'only the summarizer (%) or an admin may summarize threads', (SELECT summarizer FROM board.policy)
            USING ERRCODE = '42501';
    END IF;
    SELECT x.thread_id INTO t FROM board.message x WHERE x.id = summarize.id;
    IF t IS NULL THEN RAISE EXCEPTION 'message #% not found', summarize.id; END IF;
    IF st NOT IN ('open', 'closed') THEN RAISE EXCEPTION 'status must be open or closed'; END IF;
    IF nullif(trim(summarize.summary), '') IS NULL THEN RAISE EXCEPTION 'empty summary'; END IF;
    IF needs_human AND nullif(trim(human_reason), '') IS NULL THEN
        RAISE EXCEPTION 'needs_human requires human_reason' USING HINT = 'say what the human has to decide or do';
    END IF;
    IF needs_human AND length(trim(human_reason)) > 1500 THEN
        RAISE EXCEPTION 'human_reason too long (% chars, max 1500)', length(trim(human_reason)) USING HINT = 'Markdown, short: goal line, options as a list, **Recommendation**, deadline, where the human acts; background goes in a note or doc:SLUG';
    END IF;
    SELECT max(x.id) INTO last_id FROM board.message x WHERE x.thread_id = t;
    INSERT INTO board.thread_summary AS s (thread_id, status, needs_human, human_reason, summary,
                                           summarized_through, summarized_at, summarized_by)
    VALUES (t, st, needs_human, CASE WHEN needs_human THEN trim(human_reason) END, trim(summarize.summary),
            least(coalesce(through, last_id), last_id), now(), me)
    ON CONFLICT (thread_id) DO UPDATE SET
        status = EXCLUDED.status, needs_human = EXCLUDED.needs_human, human_reason = EXCLUDED.human_reason,
        summary = EXCLUDED.summary, summarized_through = EXCLUDED.summarized_through,
        summarized_at = now(), summarized_by = me;
    RETURN format('thread #%s: %s%s, summarized through #%s%s', t, st,
                  CASE WHEN needs_human THEN ', needs human' ELSE '' END, least(coalesce(through, last_id), last_id),
                  CASE WHEN coalesce(through, last_id) < last_id
                       THEN format(' (newer: up to #%s -- you will be prompted again)', last_id) ELSE '' END);
END $$;

-- pending = threads with activity by others since their last summary; otherwise the summaries
CREATE OR REPLACE FUNCTION api.summaries(pending boolean DEFAULT false, lim integer DEFAULT 30) RETURNS api."text/plain"
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT coalesce(string_agg(line, E'\n' ORDER BY last_id DESC),
                    CASE WHEN pending THEN 'no threads waiting for a summary' ELSE 'no summaries yet' END)
    FROM (
        SELECT t.last_id, CASE WHEN pending
            THEN format('#%s  "%s"  %s msgs, latest #%s %s  (summarized through: %s)', t.thread_id, t.subject,
                        t.size, t.last_id, board.fmt_ts(t.last_at), coalesce('#' || t.summarized_through, 'never'))
            ELSE format('#%s  %s%s%s  "%s"  %s', t.thread_id, upper(t.status),
                        CASE WHEN t.needs_human THEN ' NEEDS-HUMAN' ELSE '' END, CASE WHEN t.stale THEN ' (stale)' ELSE '' END,
                        t.subject, replace(left(t.summary, 160), E'\n', ' '))
            END AS line
        FROM api.threads t
        WHERE board.require_me() IS NOT NULL
          AND CASE WHEN pending THEN t.last_other_id > coalesce(t.summarized_through, 0) ELSE t.status IS NOT NULL END
        ORDER BY t.last_id DESC LIMIT lim
    ) x
$$;

CREATE OR REPLACE FUNCTION api.inbox(include_read boolean DEFAULT false, lim integer DEFAULT 30) RETURNS api."text/plain"
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT coalesce(string_agg(line, E'\n' ORDER BY id DESC),
                    CASE WHEN include_read THEN 'no messages addressed to you' ELSE 'no unread messages (board inbox --all shows read ones too)' END)
    FROM (
        SELECT m.id, board.fmt_line(m, r.read_at IS NULL) AS line
        FROM board.recipient r JOIN board.message m ON m.id = r.message_id
        WHERE r.handle = board.require_me() AND (include_read OR r.read_at IS NULL)
        ORDER BY m.id DESC LIMIT lim
    ) x
$$;

CREATE OR REPLACE FUNCTION api.search(
    q text DEFAULT NULL, sender text DEFAULT NULL, recipient text DEFAULT NULL, tag text DEFAULT NULL,
    system text DEFAULT NULL, since timestamptz DEFAULT NULL, until timestamptz DEFAULT NULL,
    lim integer DEFAULT 30
) RETURNS api."text/plain" LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT coalesce(string_agg(line, E'\n' ORDER BY id DESC), 'no matching messages')
    FROM (
        SELECT m.id, board.fmt_line(m) AS line
        FROM board.message m
        WHERE board.require_me() IS NOT NULL
          AND (nullif(q, '') IS NULL OR m.tsv @@ websearch_to_tsquery('english', q))
          AND (nullif(search.sender, '') IS NULL OR m.sender = lower(search.sender))
          AND (nullif(recipient, '') IS NULL OR EXISTS (SELECT 1 FROM board.recipient r WHERE r.message_id = m.id AND r.handle = lower(recipient)))
          AND (nullif(tag, '') IS NULL OR m.tags @> board.split_list(tag))
          AND (nullif(search.system, '') IS NULL OR m.systems @> board.split_list(search.system))
          AND (since IS NULL OR m.created_at >= since)
          AND (until IS NULL OR m.created_at < until)
        ORDER BY m.id DESC LIMIT lim
    ) x
$$;

CREATE OR REPLACE FUNCTION api.directory() RETURNS api."text/plain"
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT string_agg(format(E'%s%s  [%s]  system: %s  host: %s  last seen: %s\n    %s%s',
                             a.handle, CASE WHEN a.kind = 'human' THEN ' (human)' ELSE '' END,
                             CASE WHEN a.active THEN 'active' ELSE 'inactive' END,
                             coalesce(a.system, '-'), coalesce(a.host, '-'),
                             coalesce(board.fmt_ts(a.last_seen_at), 'never'),
                             replace(left(coalesce(a.description, ''), 300), E'\n', ' '),
                             coalesce(E'\n    responsibilities: ' || replace(left(a.responsibilities, 300), E'\n', ' '), '')),
                      E'\n' ORDER BY a.kind DESC, a.handle)
    FROM board.agent a
    WHERE board.require_me() IS NOT NULL
$$;

-- is_admin is the CALLER's admin right (an auth sign-in: auth's grant), not just the row's flag
CREATE OR REPLACE FUNCTION api.whoami() RETURNS json
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT (to_jsonb(x) || jsonb_build_object('is_admin', board.is_admin(), 'via_auth', board.via_auth()))::json
    FROM api.agents x WHERE x.handle = board.require_me()
$$;

-- ---------------------------------------------------------------- API: tasks
-- may `me` change task `t`? its assignee or creator, the assignee of any ancestor (delegation), the PM,
-- or an admin. Anyone may add notes and link threads.
CREATE OR REPLACE FUNCTION board.task_can_edit(t bigint, me text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    WITH RECURSIVE up AS (
        SELECT id, parent_id, assignee, created_by FROM board.task WHERE id = t
        UNION ALL
        SELECT p.id, p.parent_id, p.assignee, p.created_by FROM board.task p JOIN up ON p.id = up.parent_id
    )
    SELECT me = (SELECT pm FROM board.policy)
        OR EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = me AND a.is_admin)
        OR EXISTS (SELECT 1 FROM up WHERE up.assignee = me)
        OR (SELECT created_by FROM board.task WHERE id = t) = me
$$;

CREATE OR REPLACE FUNCTION board.task_status(s text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF lower(btrim(s)) NOT IN ('todo', 'doing', 'blocked', 'review', 'done', 'cancelled', 'ongoing') THEN
        RAISE EXCEPTION 'bad status "%"', s USING HINT = 'one of: todo, doing, blocked, review, done, cancelled, ongoing';
    END IF;
    RETURN lower(btrim(s));
END $$;

CREATE OR REPLACE FUNCTION board.task_interval(s text) RETURNS interval LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    -- '2h', '30m', '1d', '1w' or any Postgres interval ('3 days')
    RETURN CASE WHEN s ~ '^\s*\d+\s*[mhdw]\s*$'
        THEN (regexp_replace(s, '\D', '', 'g') || ' ' ||
              CASE right(btrim(s), 1) WHEN 'm' THEN 'minutes' WHEN 'h' THEN 'hours' WHEN 'd' THEN 'days' ELSE 'weeks' END)::interval
        ELSE s::interval END;
EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'bad interval "%"', s USING HINT = 'e.g. 30m, 4h, 1d, 1w';
END $$;

CREATE OR REPLACE FUNCTION board.fmt_age(i interval) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN i < interval '1 hour' THEN floor(extract(epoch FROM i) / 60) || 'm'
                WHEN i < interval '2 days' THEN floor(extract(epoch FROM i) / 3600) || 'h'
                ELSE floor(extract(epoch FROM i) / 86400) || 'd' END
$$;

-- for the web UI (kanban)
-- the nearest project node at or above a task (NULL: system work or operations)
CREATE OR REPLACE FUNCTION board.task_project(id bigint) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    WITH RECURSIVE up AS (
        SELECT t.id, t.parent_id, t.kind, 0 AS d FROM board.task t WHERE t.id = task_project.id
        UNION ALL
        SELECT p.id, p.parent_id, p.kind, up.d + 1 FROM board.task p JOIN up ON p.id = up.parent_id WHERE up.kind <> 'project'
    )
    SELECT up.id FROM up WHERE up.kind = 'project' ORDER BY d LIMIT 1
$$;

-- every project node, with its parent project, lead, systems and clients (own and inherited)
CREATE OR REPLACE VIEW api.projects AS
SELECT t.id, t.path, t.slug, t.title, t.status, t.assignee AS lead, t.url, t.description,
       board.task_project(t.parent_id) AS parent_project_id,
       coalesce((SELECT json_agg(json_build_object('system', ps.system, 'role', ps.role) ORDER BY ps.system)
                 FROM board.project_system ps WHERE ps.project_id = t.id), '[]') AS systems,
       coalesce((SELECT json_agg(json_build_object('client', c.slug, 'name', c.name, 'for_client', pc.for_client,
                                                   'for_name', f.name, 'inherited', pc.project_id <> t.id) ORDER BY c.name)
                 FROM board.project_client pc JOIN board.client c ON c.slug = pc.client
                 LEFT JOIN board.client f ON f.slug = pc.for_client
                 WHERE pc.project_id IN (SELECT a.id FROM board.task a WHERE t.path = a.path OR t.path LIKE a.path || '/%')), '[]') AS clients,
       (SELECT count(*) FROM board.task x WHERE x.path LIKE t.path || '/%' AND x.kind = 'task'
          AND x.status NOT IN ('done', 'cancelled')) AS open_tasks,
       (SELECT count(*) FROM board.task x WHERE (x.id = t.id OR x.path LIKE t.path || '/%') AND x.needs_human
          AND x.status NOT IN ('done', 'cancelled')) AS needs_you
FROM board.task t WHERE t.kind = 'project';

-- every system: its owner, instances (agent + host), the projects that use it and its open system work
CREATE OR REPLACE VIEW api.system_catalog AS
SELECT s.slug, s.name, s.kind, s.owner, s.repo, s.description,
       coalesce((SELECT json_agg(json_build_object('agent', i.agent, 'label', i.label, 'host', a.host) ORDER BY i.agent)
                 FROM board.system_instance i JOIN board.agent a ON a.handle = i.agent WHERE i.system = s.slug), '[]') AS instances,
       coalesce((SELECT json_agg(json_build_object('id', t.id, 'path', t.path, 'slug', t.slug, 'title', t.title, 'role', ps.role)
                                 ORDER BY t.path)
                 FROM board.project_system ps JOIN board.task t ON t.id = ps.project_id WHERE ps.system = s.slug), '[]') AS projects,
       (SELECT count(*) FROM board.task x WHERE x.system = s.slug AND x.status NOT IN ('done', 'cancelled')) AS open_tasks
FROM board.system s;

CREATE OR REPLACE VIEW api.clients AS
SELECT c.slug, c.name, c.kind, c.notes,
       coalesce((SELECT json_agg(json_build_object('id', t.id, 'path', t.path, 'title', t.title, 'for_client', pc.for_client))
                 FROM board.project_client pc JOIN board.task t ON t.id = pc.project_id WHERE pc.client = c.slug), '[]') AS projects
FROM board.client c;

CREATE OR REPLACE VIEW api.tasks AS
SELECT t.id, t.parent_id, t.title, t.description, t.status, t.assignee, t.created_by, t.check_every::text AS check_every,
       t.due_at, t.needs_human, t.human_reason, t.position, t.created_at, t.updated_at, t.status_changed_at, t.activity_at,
       t.pm_prompted_at,
       (t.status NOT IN ('done', 'cancelled') AND t.activity_at < now() - t.check_every) AS overdue_checkin,
       (SELECT count(*) FROM board.task c WHERE c.parent_id = t.id AND c.status <> 'cancelled') AS subtasks,
       (SELECT count(*) FROM board.task c WHERE c.parent_id = t.id AND c.status = 'done') AS subtasks_done,
       coalesce((SELECT array_agg(x.thread_id ORDER BY x.thread_id) FROM board.task_thread x WHERE x.task_id = t.id), '{}') AS threads,
       (SELECT count(*) FROM board.task_note n WHERE n.task_id = t.id) AS notes,
       (SELECT n.body FROM board.task_note n WHERE n.task_id = t.id AND n.body <> '' ORDER BY n.id DESC LIMIT 1) AS last_note,
       t.path, t.umbrella,
       t.kind, t.slug, t.url, t.system,
       board.task_project(t.id) AS project_id,
       (SELECT i.system FROM board.system_instance i WHERE i.agent = t.assignee ORDER BY i.system LIMIT 1) AS assignee_system,
       t.human_level
FROM board.task t;

CREATE OR REPLACE VIEW api.task_notes AS
SELECT n.id, n.task_id, n.author, n.body, n.change, n.created_at FROM board.task_note n;

-- one row per escalation ("needs you"), read back from the task log: raised (or re-worded) by a
-- task_update with needs_human, ended by the next escalation event on that task. outcome: open (still
-- needs the human), answered (a human's note/edit cleared it; answer = that note), cleared (cleared by
-- hand, or the task closed), reworded (replaced by a new escalation text)
CREATE OR REPLACE VIEW api.task_escalations AS
WITH ev AS (
    SELECT n.id, n.task_id, n.author, n.body, n.created_at,
           CASE WHEN n.change ~ 'escalated to the human: ' THEN 'raised'
                WHEN n.change ~ 'escalation answered by ' THEN 'answered' ELSE 'cleared' END AS kind,
           substring(n.change FROM 'escalated to the human: (.*)$') AS reason
    FROM board.task_note n
    WHERE n.change ~ '(escalated to the human: |escalation answered by |escalation cleared)'
)
SELECT r.id, r.task_id, t.title AS task_title, t.status AS task_status, r.author AS raised_by, r.created_at AS raised_at,
       r.reason, e.created_at AS ended_at, e.author AS ended_by,
       CASE WHEN e.id IS NULL THEN 'open' WHEN e.kind = 'raised' THEN 'reworded' ELSE e.kind END AS outcome,
       CASE WHEN e.kind = 'answered' THEN nullif(e.body, '') END AS answer
FROM ev r
JOIN board.task t ON t.id = r.task_id
LEFT JOIN LATERAL (SELECT x.* FROM ev x WHERE x.task_id = r.task_id AND x.id > r.id ORDER BY x.id LIMIT 1) e ON true
WHERE r.kind = 'raised';

CREATE OR REPLACE VIEW api.task_threads AS
SELECT x.task_id, x.thread_id, x.linked_by, x.linked_at, r.subject, t.last_at, t.size, t.status, t.needs_human, t.summary
FROM board.task_thread x JOIN board.message r ON r.id = x.thread_id
JOIN api.threads t ON t.thread_id = x.thread_id;

-- one row per message, light (no body): the /banter chart aggregates these per day and agent;
-- bytes = subject + body as stored, task_ids = tasks its thread is filed under
CREATE OR REPLACE VIEW api.message_stats AS
SELECT m.id, m.sender, m.thread_id, m.created_at, m.subject,
       octet_length(coalesce(m.subject, '')) + octet_length(m.body) AS bytes,
       COALESCE((SELECT array_agg(r.handle ORDER BY r.handle) FROM board.recipient r WHERE r.message_id = m.id), '{}'::text[]) AS recipients,
       COALESCE((SELECT array_agg(x.task_id ORDER BY x.task_id) FROM board.task_thread x WHERE x.thread_id = m.thread_id), '{}'::bigint[]) AS task_ids
FROM board.message m;

-- one line per task: #12 [doing] title  @pethelp  2/5 subtasks  last activity 3h  !needs human
CREATE OR REPLACE FUNCTION board.fmt_task(t board.task, indent integer DEFAULT 0) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT format('%s#%s%s [%s] %s  @%s%s  activity %s ago%s%s',
        repeat('  ', indent), t.path, CASE WHEN t.parent_id IS NULL THEN '/' ELSE format(' (id %s)', t.id) END, t.status, t.title, coalesce(t.assignee, 'unassigned'),
        (SELECT CASE WHEN count(*) > 0 THEN format('  %s/%s subtasks done', count(*) FILTER (WHERE c.status = 'done'), count(*)) ELSE '' END
         FROM board.task c WHERE c.parent_id = t.id AND c.status <> 'cancelled'),
        board.fmt_age(now() - t.activity_at),
        CASE WHEN t.due_at IS NOT NULL THEN '  due ' || board.fmt_ts(t.due_at) ELSE '' END,
        CASE WHEN t.needs_human THEN '  !NEEDS HUMAN: ' || coalesce(t.human_reason, '?') ELSE '' END)
$$;

CREATE OR REPLACE FUNCTION api.task_create(
    title text, description text DEFAULT NULL, assignee text DEFAULT NULL, parent bigint DEFAULT NULL,
    status text DEFAULT 'todo', check_every text DEFAULT NULL, due text DEFAULT NULL
) RETURNS api."text/plain" LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); t board.task; who text := nullif(lower(btrim(task_create.assignee, ' @')), '');
BEGIN
    IF who IS NOT NULL AND NOT EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = who) THEN
        RAISE EXCEPTION 'unknown assignee "%"', who USING HINT = 'list participants with: board agents';
    END IF;
    IF parent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM board.task x WHERE x.id = parent) THEN
        RAISE EXCEPTION 'parent task #% not found', parent;
    END IF;
    INSERT INTO board.task (parent_id, title, description, status, assignee, created_by, check_every, due_at)
    VALUES (parent, btrim(task_create.title), coalesce(task_create.description, ''), board.task_status(coalesce(task_create.status, 'todo')),
            who, me, coalesce(board.task_interval(nullif(task_create.check_every, '')), interval '1 day'),
            nullif(due, '')::timestamptz)
    RETURNING * INTO t;
    INSERT INTO board.task_note (task_id, author, body, change)
    VALUES (t.id, me, '', format('created%s', coalesce(', assigned to ' || who, '')));
    RETURN format('task %s created: %s', board.task_ref(t.id), board.fmt_task(t));
END $$;

-- NULL = unchanged. assignee '-' unassigns, parent 0 makes it a top-level task, due '-' clears the due date,
-- needs_human false clears an escalation. Every change (and the note) goes into the task's log.
CREATE OR REPLACE FUNCTION api.task_update(
    id bigint, status text DEFAULT NULL, note text DEFAULT NULL, assignee text DEFAULT NULL,
    title text DEFAULT NULL, description text DEFAULT NULL, parent bigint DEFAULT NULL,
    check_every text DEFAULT NULL, due text DEFAULT NULL,
    needs_human boolean DEFAULT NULL, human_reason text DEFAULT NULL, "position" double precision DEFAULT NULL
) RETURNS api."text/plain" LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE
    me text := board.require_me();
    o board.task; n board.task;
    who text := nullif(lower(btrim(task_update.assignee, ' @')), '');
    changes text[] := '{}';
    edits boolean;
    answered boolean := false;
BEGIN
    SELECT * INTO o FROM board.task x WHERE x.id = task_update.id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'task #% not found', task_update.id; END IF;
    n := o;
    edits := coalesce(task_update.status, who, task_update.title, task_update.description, task_update.parent::text,
                      task_update.check_every, task_update.due, task_update.needs_human::text, task_update."position"::text) IS NOT NULL;
    IF edits AND NOT board.task_can_edit(o.id, me) THEN
        RAISE EXCEPTION 'task #%: only its assignee, its creator, the assignee of a parent task, the PM or an admin may change it', o.id
            USING ERRCODE = '42501', HINT = 'add a note instead: board task note ID -m "..."';
    END IF;
    IF task_update.status IS NOT NULL THEN n.status := board.task_status(task_update.status); END IF;
    IF o.status = 'ongoing' AND n.status IN ('review', 'done') THEN
        RAISE EXCEPTION 'task #% is ongoing maintenance: it never completes', o.id
            USING HINT = 'report a problem with a note or --status blocked; retire it with --status cancelled';
    END IF;
    IF who = '-' THEN n.assignee := NULL;
    ELSIF who IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = who) THEN
            RAISE EXCEPTION 'unknown assignee "%"', who USING HINT = 'list participants with: board agents';
        END IF;
        n.assignee := who;
    END IF;
    IF nullif(btrim(task_update.title), '') IS NOT NULL THEN n.title := btrim(task_update.title); END IF;
    IF task_update.description IS NOT NULL THEN n.description := task_update.description; END IF;
    IF task_update.parent = 0 THEN n.parent_id := NULL;
    ELSIF task_update.parent IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM board.task x WHERE x.id = task_update.parent) THEN
            RAISE EXCEPTION 'parent task #% not found', task_update.parent;
        END IF;
        IF EXISTS (WITH RECURSIVE up AS (SELECT x.id, x.parent_id FROM board.task x WHERE x.id = task_update.parent
                                         UNION ALL SELECT p.id, p.parent_id FROM board.task p JOIN up ON p.id = up.parent_id)
                   SELECT 1 FROM up WHERE up.id = o.id) THEN
            RAISE EXCEPTION 'task #% can''t be under #%: that would make a cycle', o.id, task_update.parent;
        END IF;
        n.parent_id := task_update.parent;
    END IF;
    IF nullif(task_update.check_every, '') IS NOT NULL THEN n.check_every := board.task_interval(task_update.check_every); END IF;
    IF task_update.due = '-' THEN n.due_at := NULL; ELSIF nullif(task_update.due, '') IS NOT NULL THEN n.due_at := task_update.due::timestamptz; END IF;
    IF task_update.needs_human IS NOT NULL THEN
        IF task_update.needs_human AND nullif(btrim(task_update.human_reason), '') IS NULL THEN
            RAISE EXCEPTION 'needs_human requires human_reason' USING HINT = 'say what the human has to decide or do';
        END IF;
        IF task_update.needs_human AND length(btrim(task_update.human_reason)) > 1500 THEN
            RAISE EXCEPTION 'human_reason too long (% chars, max 1500)', length(btrim(task_update.human_reason)) USING HINT = 'Markdown, short: goal line, options as a list, **Recommendation**, deadline, where the human acts; background goes in a note or doc:SLUG';
        END IF;
        n.needs_human := task_update.needs_human;
        n.human_reason := CASE WHEN task_update.needs_human THEN btrim(task_update.human_reason) END;
    END IF;
    IF task_update."position" IS NOT NULL THEN n.position := task_update."position"; END IF;
    -- closing a task settles its escalation
    IF n.status IN ('done', 'cancelled') AND n.status IS DISTINCT FROM o.status AND n.needs_human
       AND task_update.needs_human IS NULL THEN
        n.needs_human := false; n.human_reason := NULL;
    END IF;
    -- a human's note or edit answers the escalation: the task leaves "Needs you" at once; the PM (told
    -- below) or the assignee escalates again if the human is still needed
    IF n.needs_human AND task_update.needs_human IS NULL AND (SELECT kind FROM board.agent WHERE handle = me) = 'human'
       AND (nullif(btrim(task_update.note), '') IS NOT NULL
            OR coalesce(task_update.status, who, task_update.title, task_update.description, task_update.parent::text,
                        task_update.check_every, task_update.due) IS NOT NULL) THEN
        n.needs_human := false; n.human_reason := NULL; answered := true;
    END IF;

    IF n.status IS DISTINCT FROM o.status THEN changes := changes || format('status: %s -> %s', o.status, n.status); END IF;
    IF n.assignee IS DISTINCT FROM o.assignee THEN
        changes := changes || format('assignee: %s -> %s', coalesce(o.assignee, '-'), coalesce(n.assignee, '-'));
    END IF;
    IF n.title IS DISTINCT FROM o.title THEN changes := changes || format('title: "%s"', n.title); END IF;
    IF n.description IS DISTINCT FROM o.description THEN changes := changes || 'description edited'::text; END IF;
    IF n.parent_id IS DISTINCT FROM o.parent_id THEN changes := changes || format('parent: %s', coalesce(board.task_ref(n.parent_id), '-')); END IF;
    IF n.check_every IS DISTINCT FROM o.check_every THEN changes := changes || format('check-in every %s', n.check_every); END IF;
    IF n.due_at IS DISTINCT FROM o.due_at THEN changes := changes || format('due: %s', coalesce(board.fmt_ts(n.due_at), '-')); END IF;
    IF n.needs_human IS DISTINCT FROM o.needs_human OR n.human_reason IS DISTINCT FROM o.human_reason THEN
        changes := changes || CASE WHEN n.needs_human THEN 'escalated to the human: ' || n.human_reason
                                   WHEN answered THEN format('escalation answered by %s, cleared', me) ELSE 'escalation cleared' END;
    END IF;
    IF cardinality(changes) = 0 AND nullif(btrim(task_update.note), '') IS NULL THEN
        IF n.position IS DISTINCT FROM o.position THEN
            UPDATE board.task x SET position = n.position WHERE x.id = o.id;
            RETURN format('task %s moved', board.task_ref(o.id));
        END IF;
        RETURN format('task %s: nothing changed', board.task_ref(o.id));
    END IF;

    UPDATE board.task x SET status = n.status, assignee = n.assignee, title = n.title, description = n.description,
        parent_id = n.parent_id, check_every = n.check_every, due_at = n.due_at, needs_human = n.needs_human,
        human_reason = n.human_reason, position = n.position, updated_at = now(), activity_at = now(),
        status_changed_at = CASE WHEN n.status IS DISTINCT FROM o.status THEN now() ELSE x.status_changed_at END,
        assignee_notified_at = CASE WHEN n.assignee IS DISTINCT FROM o.assignee THEN NULL ELSE x.assignee_notified_at END
    WHERE x.id = o.id RETURNING * INTO n;
    INSERT INTO board.task_note (task_id, author, body, change)
    VALUES (o.id, me, coalesce(btrim(task_update.note), ''), nullif(array_to_string(changes, '; '), ''));
    -- tell the people who depend on it about a status change (the PM's own blocked/review prompts and a
    -- new assignee's assignment notice already cover those)
    IF n.status IS DISTINCT FROM o.status THEN
        INSERT INTO board.task_notice (task_id, handle, line)
        SELECT DISTINCT ON (r.handle) o.id, r.handle, format('[board] task %s "%s" moved %s -> %s by %s%s%s -- see it with: board task %s',
               board.task_ref(o.id), n.title, o.status, n.status, me,
               CASE WHEN r.why = 'parent' THEN format(' (subtask of %s "%s")', board.task_ref(p.id), p.title) ELSE '' END,
               CASE WHEN nullif(btrim(task_update.note), '') IS NOT NULL
                    THEN ': "' || left(regexp_replace(btrim(task_update.note), '\s+', ' ', 'g'), 150)
                         || CASE WHEN length(btrim(task_update.note)) > 150 THEN '…' ELSE '' END || '"' ELSE '' END,
               o.id) || CASE WHEN answered THEN ' -- this answers its escalation (cleared): act on it, and escalate again (--human) only if the human is still needed' ELSE '' END
        FROM (SELECT 1) one
        LEFT JOIN board.task p ON p.id = n.parent_id
        CROSS JOIN LATERAL (VALUES (n.assignee, 'task'), (n.created_by, 'task'),
                                   (CASE WHEN n.status IN ('done', 'cancelled') THEN p.assignee END, 'parent'),
                                   (CASE WHEN n.status IN ('done', 'cancelled') THEN p.created_by END, 'parent'),
                                   (CASE WHEN n.status IN ('done', 'cancelled') OR answered THEN (SELECT pm FROM board.policy) END, 'task')) r(handle, why)
        JOIN board.agent a ON a.handle = r.handle AND a.kind = 'agent'
        WHERE r.handle <> me
          AND NOT (r.handle = n.assignee AND n.assignee IS DISTINCT FROM o.assignee)
          AND NOT (r.handle = (SELECT pm FROM board.policy) AND n.status IN ('blocked', 'review') AND NOT answered)
        ORDER BY r.handle, r.why;  -- 'parent' first: one line per person, with the subtask context
    ELSIF (SELECT kind FROM board.agent WHERE handle = me) = 'human' THEN
        -- a human's note or edit (an approval, an answer, a correction) must reach the agents who own the
        -- task; agents' own notes stay silent (progress reports)
        INSERT INTO board.task_notice (task_id, handle, line)
        SELECT DISTINCT o.id, r.handle, format('[board] task %s "%s": %s %s%s -- see it with: board task %s',
               board.task_ref(o.id), n.title, me,
               CASE WHEN nullif(btrim(task_update.note), '') IS NOT NULL
                    THEN 'noted "' || left(regexp_replace(btrim(task_update.note), '\s+', ' ', 'g'), 200)
                         || CASE WHEN length(btrim(task_update.note)) > 200 THEN '…' ELSE '' END || '"' ELSE 'edited it' END,
               CASE WHEN cardinality(changes) > 0 THEN ' (' || array_to_string(changes, '; ') || ')' ELSE '' END,
               o.id) || CASE WHEN answered THEN ' -- this answers its escalation (cleared): act on it, and escalate again (--human) only if the human is still needed' ELSE '' END
        FROM (VALUES (n.assignee), (n.created_by), (CASE WHEN answered THEN (SELECT pm FROM board.policy) END)) r(handle)
        JOIN board.agent a ON a.handle = r.handle AND a.kind = 'agent'
        WHERE NOT (r.handle = n.assignee AND n.assignee IS DISTINCT FROM o.assignee);
    END IF;
    RETURN format('task %s updated%s', board.task_ref(o.id), CASE WHEN cardinality(changes) > 0 THEN ' (' || array_to_string(changes, '; ') || ')' ELSE ': note added' END);
END $$;

CREATE OR REPLACE FUNCTION api.task_link(id bigint, thread bigint, unlink boolean DEFAULT false) RETURNS api."text/plain"
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); th bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM board.task x WHERE x.id = task_link.id) THEN RAISE EXCEPTION 'task #% not found', task_link.id; END IF;
    SELECT m.thread_id INTO th FROM board.message m WHERE m.id = task_link.thread;
    IF th IS NULL THEN RAISE EXCEPTION 'message #% not found', task_link.thread; END IF;
    IF unlink THEN
        DELETE FROM board.task_thread x WHERE x.task_id = task_link.id AND x.thread_id = th;
        RETURN format('thread #%s unlinked from task %s', th, board.task_ref(task_link.id));
    END IF;
    INSERT INTO board.task_thread (task_id, thread_id, linked_by) VALUES (task_link.id, th, me) ON CONFLICT DO NOTHING;
    RETURN format('thread #%s linked to task %s', th, board.task_ref(task_link.id));
END $$;

-- a task with its path, description, subtasks, threads and log
CREATE OR REPLACE FUNCTION api.task(id bigint) RETURNS api."text/plain"
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE t board.task; path text; subs text; ths text; log text;
BEGIN
    PERFORM board.require_me();
    SELECT * INTO t FROM board.task x WHERE x.id = task.id;
    IF NOT FOUND THEN RETURN format('task #%s not found', task.id); END IF;
    WITH RECURSIVE up AS (SELECT x.id, x.parent_id, x.title, 0 AS d FROM board.task x WHERE x.id = t.parent_id
                          UNION ALL SELECT p.id, p.parent_id, p.title, up.d + 1 FROM board.task p JOIN up ON p.id = up.parent_id)
    SELECT string_agg(format('%s %s', board.task_ref(up.id), up.title), ' > ' ORDER BY up.d DESC) INTO path FROM up;
    SELECT string_agg(board.fmt_task(c, 1), E'\n' ORDER BY c.status = 'done', c.position, c.id) INTO subs
    FROM board.task c WHERE c.parent_id = t.id AND c.status <> 'cancelled';
    SELECT string_agg(format('  #%s "%s"  %s%s', x.thread_id, x.subject, upper(coalesce(x.status, 'unsummarized')),
                             coalesce(': ' || replace(left(x.summary, 200), E'\n', ' '), '')), E'\n' ORDER BY x.thread_id) INTO ths
    FROM api.task_threads x WHERE x.task_id = t.id;
    SELECT string_agg(format('  %s %s: %s', board.fmt_ts(n.created_at), n.author,
                             concat_ws(' | ', '[' || n.change || ']', nullif(n.body, ''))), E'\n' ORDER BY n.id) INTO log
    -- the latest 15, plus the latest 10 by anyone but the PM: its own check-in notes must not push the
    -- owners' reports (and the human's answers) out of view
    FROM board.task_note n
    WHERE n.id IN (SELECT x.id FROM board.task_note x WHERE x.task_id = t.id ORDER BY x.id DESC LIMIT 15)
       OR n.id IN (SELECT x.id FROM board.task_note x WHERE x.task_id = t.id AND x.author <> (SELECT pm FROM board.policy)
                   ORDER BY x.id DESC LIMIT 10);
    RETURN concat_ws(E'\n',
        board.fmt_task(t),
        CASE WHEN path IS NOT NULL THEN 'Under:    ' || path END,
        format('Created:  %s by %s · check-in every %s · last activity %s ago', board.fmt_ts(t.created_at), t.created_by,
               t.check_every, board.fmt_age(now() - t.activity_at)),
        CASE WHEN t.description <> '' THEN E'\n' || t.description END,
        E'\nSubtasks:', coalesce(subs, '  (none)'),
        E'\nThreads:', coalesce(ths, '  (none)'),
        E'\nLog (latest 15, plus the 10 latest not by the PM):', coalesce(log, '  (empty)'),
        E'\n-- note: board task note ' || t.id || ' -m "..." | status: board task update ' || t.id
            || ' --status todo|doing|blocked|review|done | subtask: board task new --parent ' || t.id || ' --title "..." --assignee H');
END $$;

-- a task reference ("#119/3", "119/3", "#119/", "151") -> its id, for the CLI (error if none)
CREATE OR REPLACE FUNCTION api.task_id(ref text) RETURNS api."text/plain"
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE i bigint := board.task_resolve(ref);
BEGIN
    PERFORM board.require_me();
    IF i IS NULL THEN RAISE EXCEPTION 'task % not found', ref; END IF;
    RETURN i::text;
END $$;

-- open tasks as a tree (mine: tasks assigned to me, with their subtasks)
CREATE OR REPLACE FUNCTION api.task_list(include_closed boolean DEFAULT false, assignee text DEFAULT NULL, mine boolean DEFAULT false)
RETURNS api."text/plain" LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    WITH RECURSIVE pick AS (
        SELECT x.* FROM board.task x
        WHERE (include_closed OR x.status NOT IN ('done', 'cancelled'))
    ), roots AS (
        SELECT p.* FROM pick p
        WHERE CASE WHEN mine OR nullif(task_list.assignee, '') IS NOT NULL
                   THEN p.assignee = CASE WHEN mine THEN board.require_me() ELSE lower(task_list.assignee) END
                   ELSE p.parent_id IS NULL OR p.parent_id NOT IN (SELECT id FROM pick) END
    ), tree AS (
        SELECT r.id, 0 AS depth, ARRAY[r.position, r.id::double precision] AS sort FROM roots r
        UNION ALL
        SELECT c.id, tree.depth + 1, tree.sort || ARRAY[c.position, c.id::double precision]
        FROM pick c JOIN tree ON c.parent_id = tree.id
    )
    SELECT coalesce(string_agg(board.fmt_task(t, tr.depth), E'\n' ORDER BY tr.sort),
                    'no open tasks' || CASE WHEN mine THEN ' assigned to you' ELSE '' END)
    FROM (SELECT DISTINCT ON (id) * FROM tree ORDER BY id, depth) tr JOIN board.task t ON t.id = tr.id
    WHERE board.require_me() IS NOT NULL
$$;

-- ---------------------------------------------------------------- API: session health + remote /login
-- open requests older than this are expired by the next watch_sync / request_login
-- ---------------------------------------------------------------- API: documents
CREATE OR REPLACE VIEW api.docs AS
SELECT d.id, d.slug, d.title, d.format, d.body, d.version, d.created_by, d.created_at, d.updated_by, d.updated_at,
       length(d.body) AS size
FROM board.doc d;
CREATE OR REPLACE VIEW api.doc_versions AS
SELECT d.slug, v.version, v.title, v.format, v.body, v.saved_by, v.saved_at
FROM board.doc_version v JOIN board.doc d ON d.id = v.doc_id;

-- Create or update a document. format: 'org' or 'md' (default: org if it looks like org-mode, else md).
-- title default: #+TITLE / the first heading. Anyone may create; updating someone else's document needs
-- an admin or the PM agent. Returns a line with the version and the UI link.
CREATE OR REPLACE FUNCTION api.doc_save(slug text, body text, title text DEFAULT NULL, format text DEFAULT NULL)
RETURNS api."text/plain" LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); d board.doc; f text; t text; s text := lower(btrim(doc_save.slug));
BEGIN
    IF coalesce(btrim(doc_save.body), '') = '' THEN RAISE EXCEPTION 'body is required'; END IF;
    IF s !~ '^[a-z0-9][a-z0-9-]{1,79}$' THEN
        RAISE EXCEPTION 'slug must be 2-80 chars of a-z, 0-9 and -, starting with a letter or digit (got "%")', doc_save.slug;
    END IF;
    f := lower(coalesce(nullif(btrim(doc_save.format), ''),
             CASE WHEN doc_save.body ~* '(^|\n)#\+(title|begin_)' OR doc_save.body ~ '(^|\n)\*+ \S' THEN 'org' ELSE 'md' END));
    IF f NOT IN ('org', 'md') THEN RAISE EXCEPTION 'format must be org or md, not "%"', f; END IF;
    t := coalesce(nullif(btrim(doc_save.title), ''),
                  (regexp_match(doc_save.body, '(?:^|\n)#\+TITLE:\s*([^\n]+)', 'i'))[1],
                  (regexp_match(doc_save.body, '(?:^|\n)(?:\*+|#+) +([^\n]+)'))[1], s);
    SELECT * INTO d FROM doc x WHERE x.slug = s FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO doc (slug, title, format, body, created_by, updated_by) VALUES (s, left(btrim(t), 300), f, doc_save.body, me, me)
        RETURNING * INTO d;
    ELSE
        IF d.created_by <> me AND NOT (me = (SELECT pm FROM policy) OR (SELECT is_admin FROM agent WHERE handle = me)) THEN
            RAISE EXCEPTION 'doc "%" belongs to %; save yours under another slug', s, d.created_by USING ERRCODE = '42501';
        END IF;
        IF d.body = doc_save.body AND d.title = left(btrim(t), 300) AND d.format = f THEN
            RETURN format('doc:%s unchanged (v%s)', s, d.version);
        END IF;
        INSERT INTO doc_version (doc_id, version, title, format, body, saved_by, saved_at)
        VALUES (d.id, d.version, d.title, d.format, d.body, d.updated_by, d.updated_at);
        UPDATE doc x SET title = left(btrim(t), 300), format = f, body = doc_save.body, version = x.version + 1,
                         updated_by = me, updated_at = now()
        WHERE x.id = d.id RETURNING * INTO d;
    END IF;
    RETURN format('doc:%s saved (v%s, %s, %s chars) -- %s/docs/%s', s, d.version, d.format, length(d.body),
                  coalesce(nullif(current_setting('board.web_url', true), ''), 'https://board.webgma.co.il'), s);
END $$;

-- One document as plain text (the source, with a header), for agents. version: an older version.
CREATE OR REPLACE FUNCTION api.doc(slug text, version integer DEFAULT NULL) RETURNS api."text/plain"
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE d board.doc; v board.doc_version;
BEGIN
    PERFORM board.require_me();
    SELECT * INTO d FROM doc x WHERE x.slug = lower(btrim(doc.slug));
    IF NOT FOUND THEN RAISE EXCEPTION 'no doc "%" (list them with: board docs)', doc.slug; END IF;
    IF doc.version IS NOT NULL AND doc.version <> d.version THEN
        SELECT * INTO v FROM doc_version x WHERE x.doc_id = d.id AND x.version = doc.version;
        IF NOT FOUND THEN RAISE EXCEPTION 'doc "%" has no version % (current: v%)', d.slug, doc.version, d.version; END IF;
        RETURN format(E'== doc:%s v%s (of v%s) "%s" [%s] saved by %s %s\n\n%s', d.slug, v.version, d.version, v.title,
                      v.format, v.saved_by, board.fmt_ts(v.saved_at), v.body);
    END IF;
    RETURN format(E'== doc:%s v%s "%s" [%s] by %s, updated %s by %s\n\n%s', d.slug, d.version, d.title, d.format,
                  d.created_by, board.fmt_ts(d.updated_at), d.updated_by, d.body)
        || coalesce(format(E'\n\n== open comments (reply or resolve at %s/docs/%s#comments)\n',
                           coalesce(nullif(current_setting('board.web_url', true), ''), 'https://board.webgma.co.il'), d.slug) || (
            SELECT string_agg(format(E'#%s %s %s (on v%s) on "%s":\n    %s', c.id, c.author, board.fmt_ts(c.created_at), c.version,
                                     left(c.quote, 160), replace(c.body, E'\n', E'\n    ')), E'\n' ORDER BY c.created_at)
            FROM doc_comment c WHERE c.doc_id = d.id AND c.resolved_at IS NULL), '');
END $$;

CREATE OR REPLACE FUNCTION api.doc_list() RETURNS api."text/plain"
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT coalesce(string_agg(format('doc:%s  v%s  %s  %s  "%s"', d.slug, d.version, board.fmt_ts(d.updated_at),
                                      d.updated_by, d.title), E'\n' ORDER BY d.updated_at DESC), '(no docs yet)')
    FROM board.doc d WHERE board.require_me() IS NOT NULL
$$;

-- Comments on a selected passage of a doc (guy, 11-13). Anchored by the quoted text plus a little context
-- before/after it (prefix/suffix), so they re-attach to the passage in later versions while it still exists.
-- Each new comment notifies the doc's author (and its last editor) with a direct board message.
CREATE TABLE IF NOT EXISTS board.doc_comment (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc_id      bigint NOT NULL REFERENCES board.doc ON DELETE CASCADE,
    version     integer NOT NULL,
    quote       text NOT NULL CHECK (length(quote) BETWEEN 1 AND 2000),
    prefix      text NOT NULL DEFAULT '' CHECK (length(prefix) <= 200),
    suffix      text NOT NULL DEFAULT '' CHECK (length(suffix) <= 200),
    body        text NOT NULL CHECK (length(body) BETWEEN 1 AND 4000),
    author      text NOT NULL REFERENCES board.agent,
    created_at  timestamptz NOT NULL DEFAULT now(),
    message_id  bigint REFERENCES board.message ON DELETE SET NULL,
    resolved_at timestamptz,
    resolved_by text REFERENCES board.agent
);
CREATE INDEX IF NOT EXISTS doc_comment_doc ON board.doc_comment (doc_id, created_at);

CREATE OR REPLACE VIEW api.doc_comments AS
SELECT c.id, d.slug, c.version, c.quote, c.prefix, c.suffix, c.body, c.author, c.created_at, c.message_id,
       c.resolved_at, c.resolved_by
FROM board.doc_comment c JOIN board.doc d ON d.id = c.doc_id;

CREATE OR REPLACE FUNCTION api.doc_comment(slug text, quote text, body text, version integer DEFAULT NULL,
                                           prefix text DEFAULT '', suffix text DEFAULT '')
RETURNS json LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); d board.doc; c board.doc_comment; rcpt text; msg json; web text;
        q text := btrim(regexp_replace(coalesce(doc_comment.quote, ''), '\s+', ' ', 'g'));
BEGIN
    IF q = '' THEN RAISE EXCEPTION 'quote (the selected passage) is required'; END IF;
    IF coalesce(btrim(doc_comment.body), '') = '' THEN RAISE EXCEPTION 'comment text is required'; END IF;
    SELECT * INTO d FROM doc x WHERE x.slug = lower(btrim(doc_comment.slug));
    IF NOT FOUND THEN RAISE EXCEPTION 'no doc "%"', doc_comment.slug; END IF;
    INSERT INTO doc_comment (doc_id, version, quote, prefix, suffix, body, author)
    VALUES (d.id, coalesce(doc_comment.version, d.version), left(q, 2000),
            right(coalesce(doc_comment.prefix, ''), 200), left(coalesce(doc_comment.suffix, ''), 200),
            btrim(doc_comment.body), me)
    RETURNING * INTO c;
    -- notify the author and the last editor (not the commenter)
    SELECT string_agg(DISTINCT h, ',') INTO rcpt FROM unnest(ARRAY[d.created_by, d.updated_by]) h
    JOIN agent a ON a.handle = h WHERE h <> me AND a.active;
    IF rcpt IS NOT NULL THEN
        web := coalesce(nullif(current_setting('board.web_url', true), ''), 'https://board.webgma.co.il');
        msg := api.post(
            format('Comment on doc:%s from %s', d.slug, me),
            format(E'%s commented on [doc:%s](%s/docs/%s#comment-%s) (v%s), on this passage:\n\n> %s\n\n%s\n\n'
                   'Act on it in the doc if needed (board doc save %s ...). A reply here reaches %s.',
                   me, d.slug, web, d.slug, c.id, c.version, left(q, 600), btrim(doc_comment.body), d.slug, me),
            rcpt, 'doc-comment');
        UPDATE doc_comment x SET message_id = (msg->>'id')::bigint WHERE x.id = c.id;
    END IF;
    RETURN json_build_object('id', c.id, 'notified', rcpt, 'message_id', (msg->>'id')::bigint);
END $$;

-- ---------------------------------------------------------------- API: code reviews
-- Code reviews (guy, 11-13): an agent commits its pending work to a branch (one per feature, or an ongoing
-- 'dev'), pushes it, and submits the diff here (`board review submit`). Each push of the branch is a new
-- revision. guy reads and comments on the diff in the web UI (select -> comment, as on docs); every comment
-- and the decision go to the agent as a board message. Approve -> the agent merges into the base branch and
-- pushes, then `board review merged ID`. Changes requested -> the agent fixes, pushes, and re-submits.
CREATE TABLE IF NOT EXISTS board.review (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent         text NOT NULL REFERENCES board.agent,
    repo          text NOT NULL CHECK (length(repo) BETWEEN 1 AND 200),
    branch        text NOT NULL CHECK (length(branch) BETWEEN 1 AND 200),
    base          text NOT NULL DEFAULT 'master' CHECK (length(base) BETWEEN 1 AND 200),
    title         text NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
    description   text NOT NULL DEFAULT '' CHECK (length(description) <= 20000),
    compare_url   text,
    task_id       bigint REFERENCES board.task ON DELETE SET NULL,
    status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'approved', 'changes', 'merged', 'closed')),
    decided_by    text REFERENCES board.agent,
    decided_at    timestamptz,
    decision_note text,
    merged_sha    text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE board.review ADD COLUMN IF NOT EXISTS remote text;  -- origin's URL (no credentials), for the repo name + git UI link
CREATE UNIQUE INDEX IF NOT EXISTS review_live ON board.review (agent, repo, branch) WHERE status IN ('open', 'approved', 'changes');
CREATE TABLE IF NOT EXISTS board.review_rev (
    review_id  bigint NOT NULL REFERENCES board.review ON DELETE CASCADE,
    rev        integer NOT NULL,
    head_sha   text,
    base_sha   text,
    diff       text NOT NULL CHECK (length(diff) <= 5000000),
    files      integer NOT NULL DEFAULT 0,
    adds       integer NOT NULL DEFAULT 0,
    dels       integer NOT NULL DEFAULT 0,
    note       text,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (review_id, rev)
);
CREATE TABLE IF NOT EXISTS board.review_comment (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    review_id   bigint NOT NULL REFERENCES board.review ON DELETE CASCADE,
    rev         integer NOT NULL,
    path        text NOT NULL DEFAULT '',
    side        text NOT NULL DEFAULT 'new' CHECK (side IN ('old', 'new')),
    line        integer,
    quote       text NOT NULL DEFAULT '' CHECK (length(quote) <= 4000),
    body        text NOT NULL CHECK (length(body) BETWEEN 1 AND 8000),
    author      text NOT NULL REFERENCES board.agent,
    created_at  timestamptz NOT NULL DEFAULT now(),
    message_id  bigint REFERENCES board.message ON DELETE SET NULL,
    resolved_at timestamptz,
    resolved_by text REFERENCES board.agent
);
-- (11-13: a whole-file diff column was tried and dropped: guy wants whole files and full comparisons from the git UI)
DROP VIEW IF EXISTS api.reviews;
DROP VIEW IF EXISTS api.review_revs;
ALTER TABLE board.review_rev DROP COLUMN IF EXISTS diff_full;
CREATE INDEX IF NOT EXISTS review_comment_review ON board.review_comment (review_id, created_at);

-- remote URL -> (host kind, repo path). git@gma8...:NAME / git@git.webgma.co.il:NAME / ssh://git@host/NAME -> gitolite;
-- github.com / gitlab.com -> owner/repo. Credentials in https URLs are dropped.
CREATE OR REPLACE FUNCTION board.remote_clean(u text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(regexp_replace(btrim(coalesce(u, '')), '^(https?://)[^/@]+@', '\1'), '')
$$;
CREATE OR REPLACE FUNCTION board.remote_repo(u text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(regexp_replace(regexp_replace(regexp_replace(board.remote_clean(u), '^(?:[a-z+]+://)?(?:[^@/]+@)?[^:/]+(?::\d+)?[:/]', ''), '\.git/?$', ''), '^/+', ''), '')
$$;
CREATE OR REPLACE FUNCTION board.compare_url(u text, base text, branch text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN u ~* 'github\.com' THEN 'https://github.com/' || board.remote_repo(u) || '/compare/' || base || '...' || branch
        WHEN u ~* 'gitlab\.com' THEN 'https://gitlab.com/' || board.remote_repo(u) || '/-/compare/' || base || '...' || branch
        WHEN u ~* '(gma8|git\.webgma\.co\.il)' THEN 'https://git.webgma.co.il/' || board.remote_repo(u) || '/compare/' || base || '...' || branch
    END
$$;

DROP VIEW IF EXISTS api.reviews;
CREATE OR REPLACE VIEW api.reviews AS
SELECT r.id, r.agent, r.repo, r.branch, r.base, r.title, r.description, r.compare_url, r.task_id, t.path AS task_path,
       r.remote, coalesce(board.remote_repo(r.remote), r.repo) AS repo_name,
       r.status, r.decided_by, r.decided_at, r.decision_note, r.merged_sha, r.created_at, r.updated_at,
       v.rev, v.head_sha, v.files, v.adds, v.dels, v.created_at AS rev_at,
       (SELECT count(*) FROM board.review_comment c WHERE c.review_id = r.id AND c.resolved_at IS NULL) AS open_comments
FROM board.review r
LEFT JOIN board.task t ON t.id = r.task_id
LEFT JOIN LATERAL (SELECT * FROM board.review_rev x WHERE x.review_id = r.id ORDER BY x.rev DESC LIMIT 1) v ON true;
DROP VIEW IF EXISTS api.review_revs;
CREATE OR REPLACE VIEW api.review_revs AS
SELECT review_id, rev, head_sha, base_sha, diff, files, adds, dels, note, created_at FROM board.review_rev;
CREATE OR REPLACE VIEW api.review_comments AS
SELECT id, review_id, rev, path, side, line, quote, body, author, created_at, message_id, resolved_at, resolved_by
FROM board.review_comment;

CREATE OR REPLACE FUNCTION board.review_url(id bigint) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT coalesce(nullif(current_setting('board.web_url', true), ''), 'https://board.webgma.co.il') || '/reviews/' || id
$$;

DROP FUNCTION IF EXISTS api.review_submit(text, text, text, text, text, text, text, text, text, text, text);
DROP FUNCTION IF EXISTS api.review_submit(text, text, text, text, text, text, text, text, text, text, text, text, text);
-- Submit (or re-submit) a branch for review. diff: `git diff --no-color BASE...BRANCH`. Re-submitting the same
-- repo+branch while its review is live adds a revision and re-opens it. Returns the review URL.
CREATE OR REPLACE FUNCTION api.review_submit(repo text, branch text, diff text, title text DEFAULT NULL,
    base text DEFAULT 'master', description text DEFAULT NULL, head_sha text DEFAULT NULL, base_sha text DEFAULT NULL,
    compare_url text DEFAULT NULL, task text DEFAULT NULL, note text DEFAULT NULL, remote text DEFAULT NULL)
RETURNS api."text/plain" LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); r board.review; n integer; tid bigint;
        f integer; a integer; d integer; fresh boolean := false; rem text := board.remote_clean(review_submit.remote);
        cmp text; last board.review_rev;
BEGIN
    IF coalesce(btrim(review_submit.diff), '') = '' THEN
        RAISE EXCEPTION 'empty diff: nothing differs between % and % (commit and push first)', coalesce(review_submit.base, 'master'), review_submit.branch;
    END IF;
    IF review_submit.task IS NOT NULL AND btrim(review_submit.task) <> '' THEN tid := api.task_id(review_submit.task); END IF;
    SELECT count(*) FILTER (WHERE l ~ '^diff --git '), count(*) FILTER (WHERE l ~ '^\+' AND l !~ '^\+\+\+ '),
           count(*) FILTER (WHERE l ~ '^-' AND l !~ '^--- ')
      INTO f, a, d FROM regexp_split_to_table(review_submit.diff, E'\n') l;
    SELECT * INTO r FROM review x WHERE x.agent = me AND x.repo = btrim(review_submit.repo) AND x.branch = btrim(review_submit.branch)
       AND x.status IN ('open', 'approved', 'changes') FOR UPDATE;
    cmp := coalesce(nullif(btrim(review_submit.compare_url), ''),
                    board.compare_url(rem, coalesce(nullif(btrim(review_submit.base), ''), 'master'), btrim(review_submit.branch)));
    IF NOT FOUND THEN
        INSERT INTO review (agent, repo, branch, base, title, description, compare_url, task_id, remote)
        VALUES (me, btrim(review_submit.repo), btrim(review_submit.branch), coalesce(nullif(btrim(review_submit.base), ''), 'master'),
                left(coalesce(nullif(btrim(review_submit.title), ''), btrim(review_submit.repo) || ': ' || btrim(review_submit.branch)), 300),
                coalesce(review_submit.description, ''), cmp, tid, rem)
        RETURNING * INTO r;
        fresh := true;
    ELSE
        UPDATE review x SET status = 'open', updated_at = now(), decided_by = NULL, decided_at = NULL, decision_note = NULL,
               title = coalesce(nullif(btrim(review_submit.title), ''), x.title),
               description = coalesce(review_submit.description, x.description),
               compare_url = coalesce(cmp, x.compare_url),
               remote = coalesce(rem, x.remote),
               task_id = coalesce(tid, x.task_id)
        WHERE x.id = r.id RETURNING * INTO r;
        -- same head commit as the latest revision: metadata refresh only (e.g. the remote), no new revision
        SELECT * INTO last FROM review_rev v WHERE v.review_id = r.id ORDER BY v.rev DESC LIMIT 1;
        IF last.head_sha IS NOT NULL AND last.head_sha = nullif(btrim(review_submit.head_sha), '') THEN
            -- same commit but a different base (e.g. the submitter's local base branch was stale): the stored
            -- diff was wrong, so correct this revision in place rather than add one
            IF nullif(btrim(review_submit.base_sha), '') IS DISTINCT FROM last.base_sha THEN
                UPDATE review_rev x SET base_sha = nullif(btrim(review_submit.base_sha), ''), diff = review_submit.diff,
                       files = f, adds = a, dels = d
                WHERE x.review_id = r.id AND x.rev = last.rev;
                RETURN format('review #%s rev %s re-based (base %s, %s files, +%s -%s) -- %s', r.id, last.rev,
                              left(review_submit.base_sha, 12), f, a, d, board.review_url(r.id));
            END IF;
            RETURN format('review #%s refreshed (rev %s unchanged; remote %s) -- %s', r.id, last.rev, coalesce(rem, '?'), board.review_url(r.id));
        END IF;
    END IF;
    SELECT coalesce(max(v.rev), 0) + 1 INTO n FROM review_rev v WHERE v.review_id = r.id;
    INSERT INTO review_rev (review_id, rev, head_sha, base_sha, diff, files, adds, dels, note)
    VALUES (r.id, n, nullif(btrim(review_submit.head_sha), ''), nullif(btrim(review_submit.base_sha), ''), review_submit.diff, f, a, d,
            nullif(btrim(review_submit.note), ''));
    RETURN format('review #%s %s (rev %s: %s files, +%s -%s) -- %s', r.id, CASE WHEN fresh THEN 'created' ELSE 'updated' END,
                  n, f, a, d, board.review_url(r.id));
END $$;

-- Comment on a line (path/side/line) or a selected passage (quote) of a revision. Notifies the review's agent,
-- or, when the agent itself comments, whoever decided (nobody before a decision).
CREATE OR REPLACE FUNCTION api.review_comment(id bigint, body text, rev integer DEFAULT NULL, path text DEFAULT '',
    side text DEFAULT 'new', line integer DEFAULT NULL, quote text DEFAULT '')
RETURNS json LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); r board.review; c board.review_comment; rcpt text; msg json; q text;
BEGIN
    IF coalesce(btrim(review_comment.body), '') = '' THEN RAISE EXCEPTION 'comment text is required'; END IF;
    SELECT * INTO r FROM review x WHERE x.id = review_comment.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'no review #%', review_comment.id; END IF;
    q := left(btrim(coalesce(review_comment.quote, '')), 4000);
    INSERT INTO review_comment (review_id, rev, path, side, line, quote, body, author)
    VALUES (r.id, coalesce(review_comment.rev, (SELECT max(v.rev) FROM review_rev v WHERE v.review_id = r.id)),
            coalesce(review_comment.path, ''), coalesce(nullif(review_comment.side, ''), 'new'), review_comment.line, q,
            btrim(review_comment.body), me)
    RETURNING * INTO c;
    IF me <> r.agent THEN rcpt := r.agent;
    ELSE rcpt := r.decided_by;  -- the agent's own replies reach a decider only; guy sees the rest in the UI/digest
    END IF;
    IF rcpt IS NOT NULL THEN
        msg := api.post(format('Review #%s comment from %s: %s', r.id, me, left(r.title, 120)),
            format(E'%s commented on [review #%s](%s#c%s) (%s %s, rev %s)%s:\n\n%s%s\n\n%s',
                   me, r.id, board.review_url(r.id), c.id, r.repo, r.branch, c.rev,
                   CASE WHEN c.path <> '' THEN format(' at `%s`%s', c.path, coalesce(format(' %s line %s', c.side, c.line), '')) ELSE '' END,
                   CASE WHEN q <> '' THEN '> ' || replace(left(q, 800), E'\n', E'\n> ') || E'\n\n' ELSE '' END,
                   btrim(review_comment.body),
                   CASE WHEN me <> r.agent THEN 'Address it on the branch, push, and re-submit (board review submit ...). A reply here reaches ' || me || '.' ELSE '' END),
            rcpt, 'review');
        UPDATE review_comment x SET message_id = (msg->>'id')::bigint WHERE x.id = c.id;
    END IF;
    UPDATE review x SET updated_at = now() WHERE x.id = r.id;
    RETURN json_build_object('id', c.id, 'notified', rcpt);
END $$;

CREATE OR REPLACE FUNCTION api.review_comment_resolve(id bigint, resolved boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); c board.review_comment; r board.review;
BEGIN
    SELECT * INTO c FROM review_comment x WHERE x.id = review_comment_resolve.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'no review comment #%', review_comment_resolve.id; END IF;
    SELECT * INTO r FROM review x WHERE x.id = c.review_id;
    IF me NOT IN (c.author, r.agent) AND NOT board.is_admin() THEN
        RAISE EXCEPTION 'only the commenter, the review''s agent or an admin can resolve comment #%', c.id USING ERRCODE = '42501';
    END IF;
    UPDATE review_comment x SET resolved_at = CASE WHEN resolved THEN now() END, resolved_by = CASE WHEN resolved THEN me END
    WHERE x.id = c.id;
END $$;

-- guy's decision: approve -> the agent merges + pushes; changes -> the agent fixes and re-submits. Admins only.
CREATE OR REPLACE FUNCTION api.review_decide(id bigint, decision text, note text DEFAULT NULL)
RETURNS json LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); r board.review; dec text := lower(btrim(review_decide.decision)); open_c bigint; msg json;
        v board.review_rev;
BEGIN
    IF NOT board.is_admin() THEN RAISE EXCEPTION 'only an admin decides a review' USING ERRCODE = '42501'; END IF;
    IF dec NOT IN ('approve', 'changes') THEN RAISE EXCEPTION 'decision must be approve or changes, not "%"', review_decide.decision; END IF;
    IF dec = 'changes' AND coalesce(btrim(review_decide.note), '') = ''
       AND NOT EXISTS (SELECT 1 FROM review_comment c WHERE c.review_id = review_decide.id AND c.resolved_at IS NULL) THEN
        RAISE EXCEPTION 'say what to change: add a reason or a comment';
    END IF;
    SELECT * INTO r FROM review x WHERE x.id = review_decide.id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'no review #%', review_decide.id; END IF;
    IF r.status IN ('merged', 'closed') THEN RAISE EXCEPTION 'review #% is already %', r.id, r.status; END IF;
    UPDATE review x SET status = CASE WHEN dec = 'approve' THEN 'approved' ELSE 'changes' END, decided_by = me, decided_at = now(),
           decision_note = nullif(btrim(review_decide.note), ''), updated_at = now()
    WHERE x.id = r.id RETURNING * INTO r;
    SELECT count(*) INTO open_c FROM review_comment c WHERE c.review_id = r.id AND c.resolved_at IS NULL;
    SELECT * INTO v FROM review_rev x WHERE x.review_id = r.id ORDER BY x.rev DESC LIMIT 1;
    msg := api.post(
        format('Review #%s %s: %s', r.id, CASE WHEN dec = 'approve' THEN 'APPROVED' ELSE 'changes requested' END, left(r.title, 120)),
        CASE WHEN dec = 'approve' THEN
            format(E'%s approved [review #%s](%s) (%s, branch %s -> %s), revision %s = commit %s.%s\n\nMerge EXACTLY the reviewed commit, not the branch tip: `git merge %s` into %s, push %s, then run: board review merged %s --sha <merge commit>. If %s has commits after %s, they were not reviewed: leave them out, or re-submit first (a new revision needs a new approval).%s',
                   me, r.id, board.review_url(r.id), r.repo, r.branch, r.base, v.rev, coalesce(left(v.head_sha, 12), '?'),
                   coalesce(E'\n\n' || nullif(btrim(review_decide.note), ''), ''),
                   coalesce(v.head_sha, r.branch), r.base, r.base, r.id, r.branch, coalesce(left(v.head_sha, 12), 'the reviewed commit'),
                   CASE WHEN open_c > 0 THEN format(E'\n(%s open comment(s) on it: read them first; apply small ones before merging.)', open_c) ELSE '' END)
        ELSE
            format(E'%s requested changes on [review #%s](%s) (%s, branch %s).%s\n\n%s open comment(s): see them with board review %s. Fix on the branch, push, and re-submit: board review submit ... (same branch = a new revision of this review).',
                   me, r.id, board.review_url(r.id), r.repo, r.branch,
                   coalesce(E'\n\nReason: ' || nullif(btrim(review_decide.note), ''), ''), open_c, r.id)
        END,
        r.agent, 'review');
    RETURN json_build_object('id', r.id, 'status', r.status, 'message_id', msg->>'id');
END $$;

-- the agent reports the merge (after an approval), or closes a review it abandons
CREATE OR REPLACE FUNCTION api.review_done(id bigint, status text DEFAULT 'merged', sha text DEFAULT NULL, note text DEFAULT NULL)
RETURNS api."text/plain" LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); r board.review; st text := lower(btrim(review_done.status));
BEGIN
    SELECT * INTO r FROM review x WHERE x.id = review_done.id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'no review #%', review_done.id; END IF;
    IF me <> r.agent AND NOT board.is_admin() THEN RAISE EXCEPTION 'review #% is %''s', r.id, r.agent USING ERRCODE = '42501'; END IF;
    IF st NOT IN ('merged', 'closed') THEN RAISE EXCEPTION 'status must be merged or closed'; END IF;
    IF st = 'merged' AND r.status <> 'approved' THEN
        RAISE EXCEPTION 'review #% is %, not approved: merge only after guy approves it', r.id, r.status;
    END IF;
    UPDATE review x SET status = st, merged_sha = coalesce(nullif(btrim(review_done.sha), ''), x.merged_sha), updated_at = now(),
           decision_note = coalesce(x.decision_note || E'\n', '') || coalesce(nullif(btrim(review_done.note), ''), '')
    WHERE x.id = r.id;
    -- guy's "Needs you" must not keep reviews that are done (11-13): a task flagged only with review links clears
    -- once every review it names is merged or closed (and no other review on that task is still live)
    UPDATE task t SET needs_human = false, updated_at = now()
     WHERE t.needs_human AND t.human_reason ~ '/reviews/[0-9]+'
       AND t.human_reason ~ ('/reviews/' || r.id || '([^0-9]|$)')
       AND NOT EXISTS (SELECT 1 FROM regexp_matches(t.human_reason, '/reviews/([0-9]+)', 'g') mm
                       JOIN review o ON o.id = mm[1]::bigint WHERE o.status NOT IN ('merged', 'closed'))
       AND NOT EXISTS (SELECT 1 FROM review o WHERE o.task_id = t.id AND o.status IN ('open', 'approved', 'changes'));
    RETURN format('review #%s %s -- %s', r.id, st, board.review_url(r.id));
END $$;

-- text for agents: one review (status, decision, open comments), or the list of yours
CREATE OR REPLACE FUNCTION api.review_text(id bigint DEFAULT NULL, mine boolean DEFAULT true, include_closed boolean DEFAULT false)
RETURNS api."text/plain" LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); r api.reviews; out text;
BEGIN
    IF review_text.id IS NULL THEN
        RETURN coalesce((SELECT string_agg(format('#%s [%s] %s  %s:%s -> %s  rev %s (+%s -%s), %s open comment(s)  %s',
                        x.id, x.status, x.agent, x.repo, x.branch, x.base, x.rev, x.adds, x.dels, x.open_comments, board.review_url(x.id)),
                        E'\n' ORDER BY x.updated_at DESC)
            FROM api.reviews x WHERE (NOT mine OR x.agent = me) AND (include_closed OR x.status NOT IN ('merged', 'closed'))),
            '(no reviews)');
    END IF;
    SELECT * INTO r FROM api.reviews x WHERE x.id = review_text.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'no review #%', review_text.id; END IF;
    out := format(E'== review #%s [%s] "%s" by %s\n%s branch %s -> %s, rev %s (%s, +%s -%s) -- %s%s%s',
                  r.id, r.status, r.title, r.agent, r.repo, r.branch, r.base, r.rev, coalesce(left(r.head_sha, 12), '?'), r.adds, r.dels,
                  board.review_url(r.id),
                  CASE WHEN r.decided_at IS NOT NULL THEN format(E'\ndecision: %s by %s %s', r.status, r.decided_by, board.fmt_ts(r.decided_at)) ELSE '' END,
                  coalesce(E'\nnote: ' || r.decision_note, ''));
    RETURN out || coalesce(E'\n\n== open comments\n' || (
        SELECT string_agg(format(E'#%s %s %s (rev %s)%s%s:\n    %s', c.id, c.author, board.fmt_ts(c.created_at), c.rev,
                                 CASE WHEN c.path <> '' THEN ' ' || c.path || coalesce(format(' %s:%s', c.side, c.line), '') ELSE '' END,
                                 CASE WHEN c.quote <> '' THEN format(' on "%s"', left(replace(c.quote, E'\n', ' '), 160)) ELSE '' END,
                                 replace(c.body, E'\n', E'\n    ')), E'\n' ORDER BY c.created_at)
        FROM review_comment c WHERE c.review_id = r.id AND c.resolved_at IS NULL), '');
END $$;

CREATE OR REPLACE FUNCTION api.doc_comment_resolve(id bigint, resolved boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); c board.doc_comment;
BEGIN
    SELECT * INTO c FROM doc_comment x WHERE x.id = doc_comment_resolve.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'no comment #%', doc_comment_resolve.id; END IF;
    IF me <> c.author AND me <> (SELECT d.created_by FROM doc d WHERE d.id = c.doc_id)
       AND NOT (me = (SELECT pm FROM policy) OR (SELECT is_admin FROM agent WHERE handle = me)) THEN
        RAISE EXCEPTION 'only the commenter, the doc author or an admin can resolve comment #%', c.id USING ERRCODE = '42501';
    END IF;
    UPDATE doc_comment x SET resolved_at = CASE WHEN resolved THEN now() END, resolved_by = CASE WHEN resolved THEN me END
    WHERE x.id = c.id;
END $$;

CREATE OR REPLACE FUNCTION board.expire_logins() RETURNS void LANGUAGE sql VOLATILE AS $$
    UPDATE board.login_request SET state = 'expired', code = NULL, updated_at = now(),
           message = coalesce(message || ' -- ', '') || 'expired: no progress for 20 minutes'
    WHERE state IN ('requested', 'started', 'url_ready', 'code_submitted', 'code_entered', 'code_rejected')
      AND updated_at < now() - interval '20 minutes'
$$;

-- The watcher's health report + task fetch (every poll). Returns plain text: empty, or one line
--   login<TAB>ID<TAB>STATE<TAB>CODE
-- for this agent's active login request (CODE only while state = code_submitted).
-- model / claude_version: the session's Claude model and Claude Code version (watcher v13+; NULL = unchanged).
DROP FUNCTION IF EXISTS api.watch_sync(text, text, integer);
CREATE OR REPLACE FUNCTION api.watch_sync(session_state text DEFAULT NULL, session_detail text DEFAULT NULL,
                                          version integer DEFAULT NULL, model text DEFAULT NULL,
                                          claude_version text DEFAULT NULL)
RETURNS api."text/plain" LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); l board.login_request;
BEGIN
    IF watch_sync.session_state NOT IN ('ok', 'logged_out', 'needs_input', 'no_claude') THEN
        RAISE EXCEPTION 'session_state must be ok, logged_out, needs_input or no_claude';
    END IF;
    UPDATE board.agent a SET
        session_changed_at = CASE WHEN a.session_state IS DISTINCT FROM watch_sync.session_state
                                  THEN now() ELSE a.session_changed_at END,
        session_state = coalesce(watch_sync.session_state, a.session_state),
        session_detail = CASE WHEN watch_sync.session_state IS NOT NULL THEN left(watch_sync.session_detail, 1000)
                              ELSE a.session_detail END,
        session_checked_at = CASE WHEN watch_sync.session_state IS NOT NULL THEN now() ELSE a.session_checked_at END,
        watcher_version = coalesce(version, a.watcher_version), last_seen_at = now(),
        claude_model = coalesce(left(nullif(model, ''), 100), a.claude_model),
        claude_version = coalesce(left(nullif(watch_sync.claude_version, ''), 40), a.claude_version),
        claude_info_at = CASE WHEN nullif(model, '') IS NOT NULL OR nullif(watch_sync.claude_version, '') IS NOT NULL
                              THEN now() ELSE a.claude_info_at END
    WHERE a.handle = me;
    PERFORM board.expire_logins();
    SELECT * INTO l FROM board.login_request x
    WHERE x.handle = me AND x.state IN ('requested', 'started', 'url_ready', 'code_submitted', 'code_entered', 'code_rejected')
    ORDER BY x.id DESC LIMIT 1;
    IF NOT FOUND THEN RETURN ''; END IF;
    RETURN format(E'login\t%s\t%s\t%s', l.id, l.state, CASE WHEN l.state = 'code_submitted' THEN l.code ELSE '' END);
END $$;

-- The watcher reports login progress. Moving to code_entered/succeeded/failed/... wipes the code.
CREATE OR REPLACE FUNCTION api.login_progress(id bigint, state text, url text DEFAULT NULL,
                                              message text DEFAULT NULL, pane_tail text DEFAULT NULL)
RETURNS api."text/plain" LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); cur board.login_request; keep boolean;
BEGIN
    SELECT * INTO cur FROM board.login_request x WHERE x.id = login_progress.id AND x.handle = me FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'login request #% not found for %', login_progress.id, me; END IF;
    IF cur.state IN ('succeeded', 'failed', 'expired', 'cancelled') THEN
        RETURN 'closed:' || cur.state;     -- e.g. cancelled by the human meanwhile: the watcher stops
    END IF;
    IF login_progress.state NOT IN ('started', 'url_ready', 'code_entered', 'code_rejected', 'succeeded', 'failed', 'expired') THEN
        RAISE EXCEPTION 'bad state %', login_progress.state;
    END IF;
    keep := cur.state = 'code_submitted' AND login_progress.state IN ('started', 'url_ready');
    UPDATE board.login_request x SET
        -- a late URL report must not undo a code the human has just submitted
        state = CASE WHEN keep THEN x.state ELSE login_progress.state END,
        code = CASE WHEN keep THEN x.code END,
        url = coalesce(login_progress.url, x.url),
        message = CASE WHEN keep THEN x.message ELSE coalesce(left(login_progress.message, 500), x.message) END,
        pane_tail = coalesce(left(login_progress.pane_tail, 4000), x.pane_tail),
        updated_at = now()
    WHERE x.id = cur.id;
    IF login_progress.state = 'succeeded' THEN
        UPDATE board.agent SET session_state = 'ok', session_detail = 'logged in via the board', session_changed_at = now()
        WHERE handle = me;
    END IF;
    RETURN 'ok';
END $$;

-- admin: ask the agent's watcher to run /login in its Claude session (supersedes an open request)
CREATE OR REPLACE FUNCTION api.request_login(handle text) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_admin(); a board.agent; new_id bigint;
BEGIN
    SELECT * INTO a FROM board.agent x WHERE x.handle = request_login.handle;
    IF NOT FOUND OR a.kind <> 'agent' THEN RAISE EXCEPTION 'no agent "%"', request_login.handle; END IF;
    IF coalesce(a.watcher_version, 0) < 2 THEN
        RAISE EXCEPTION '%''s watcher is too old for remote login', a.handle
            USING HINT = 'update it on that host: re-run the install one-liner (curl -fsSL <board URL>/install.sh | bash), then board watch-start';
    END IF;
    -- the watcher TYPES /login: into an open dialog it would answer the dialog, into a bare shell it would run it
    IF a.session_state IN ('needs_input', 'no_claude') THEN
        RAISE EXCEPTION '%''s Claude session can''t take /login right now (%)', a.handle, a.session_state
            USING HINT = 'clear the dialog in its tmux pane first, or start Claude there';
    END IF;
    PERFORM board.expire_logins();
    UPDATE board.login_request x SET state = 'cancelled', code = NULL, updated_at = now(),
           message = 'superseded by a new request'
    WHERE x.handle = a.handle AND x.state IN ('requested', 'started', 'url_ready', 'code_submitted', 'code_entered', 'code_rejected');
    INSERT INTO board.login_request (handle, requested_by, message)
    VALUES (a.handle, me, 'waiting for the watcher to pick it up (it checks every few seconds)')
    RETURNING id INTO new_id;
    RETURN json_build_object('id', new_id);
END $$;

-- admin: paste the code shown by claude.ai after authorizing ("xxxx#yyyy")
CREATE OR REPLACE FUNCTION api.submit_login_code(id bigint, code text) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE c text := regexp_replace(coalesce(code, ''), '\s', '', 'g'); st text;
BEGIN
    PERFORM board.require_admin();
    SELECT x.state INTO st FROM board.login_request x WHERE x.id = submit_login_code.id FOR UPDATE;
    IF st IS NULL THEN RAISE EXCEPTION 'login request #% not found', submit_login_code.id; END IF;
    IF st NOT IN ('url_ready', 'code_rejected') THEN
        RAISE EXCEPTION 'this login is %, not waiting for a code', replace(st, '_', ' ');
    END IF;
    IF c !~ '^[A-Za-z0-9_-]+#[A-Za-z0-9_-]+$' THEN
        RAISE EXCEPTION 'that does not look like a login code'
            USING HINT = 'copy the whole code from the claude.ai page; it has the form xxxx#yyyy';
    END IF;
    UPDATE board.login_request x SET state = 'code_submitted', code = c, updated_at = now(),
           message = 'code received; the watcher will type it in'
    WHERE x.id = submit_login_code.id;
    RETURN json_build_object('id', submit_login_code.id, 'state', 'code_submitted');
END $$;

CREATE OR REPLACE FUNCTION api.cancel_login(id bigint) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
BEGIN
    PERFORM board.require_admin();
    UPDATE board.login_request x SET state = 'cancelled', code = NULL, updated_at = now(), message = 'cancelled from the board'
    WHERE x.id = cancel_login.id AND x.state IN ('requested', 'started', 'url_ready', 'code_submitted', 'code_entered', 'code_rejected');
    RETURN json_build_object('id', cancel_login.id);
END $$;

-- ---------------------------------------------------------------- API: browser push
-- Everything that is waiting for a human right now. `key` changes when the item is new again (a new
-- session problem, a new login URL, a reworded escalation), `tag` stays the same so the browser
-- replaces the older notification. audience NULL = every admin.
CREATE OR REPLACE VIEW board.attention AS
SELECT format('session:%s:%s:%s', a.handle, a.session_state, extract(epoch FROM a.session_changed_at)::bigint) AS key,
       'session:' || a.handle AS tag, NULL::text AS audience, a.session_changed_at AS at,
       format('%s %s', a.handle, CASE a.session_state WHEN 'logged_out' THEN 'is logged out'
                                                      WHEN 'needs_input' THEN 'is waiting at a dialog'
                                                      ELSE 'has no Claude running' END) AS title,
       coalesce(left(a.session_detail, 240), '') AS body, '/agents' AS url
FROM board.agent a
WHERE a.kind = 'agent' AND a.active AND a.session_state IN ('logged_out', 'needs_input', 'no_claude')
UNION ALL
-- watchers silent 10 min, one item per host (a host that goes down takes all its agents with it)
SELECT format('silent:%s:%s', w.host, md5(string_agg(w.handle || extract(epoch FROM w.seen)::bigint, ',' ORDER BY w.handle))),
       'silent:' || w.host, NULL, max(w.seen) + interval '10 minutes',
       format('%s: %s not answering', w.host, CASE WHEN count(*) = 1 THEN min(w.handle) || '''s watcher'
                                                   ELSE count(*) || ' agents'' watchers' END),
       format('Silent since %s UTC: %s. They get no board notifications until their tmux sessions run again.',
              to_char(min(w.seen) AT TIME ZONE 'UTC', 'MM-DD HH24:MI'), string_agg(w.handle, ', ' ORDER BY w.handle)),
       '/agents'
FROM (SELECT a.handle, coalesce(a.host, '?') AS host, coalesce(a.last_seen_at, a.created_at) AS seen
      FROM board.agent a
      WHERE a.kind = 'agent' AND a.active AND NOT a.offline_ok
        AND coalesce(a.last_seen_at, '-infinity') < now() - interval '10 minutes') w
GROUP BY w.host
UNION ALL
SELECT format('login:%s:%s:%s', l.id, l.state, md5(coalesce(l.url, ''))), 'login:' || l.handle, l.requested_by, l.updated_at,
       format('%s: login link %s', l.handle, CASE l.state WHEN 'url_ready' THEN 'ready' ELSE 'rejected the code, new link ready' END),
       'Open the link, authorize, and paste the code', '/agents'
FROM board.login_request l
WHERE l.state IN ('url_ready', 'code_rejected')
UNION ALL
SELECT format('thread:%s:%s', s.thread_id, md5(coalesce(s.human_reason, ''))), 'thread:' || s.thread_id, NULL, s.summarized_at,
       format('Needs you: %s', m.subject), coalesce(left(s.human_reason, 240), ''), '/m/' || s.thread_id
FROM board.thread_summary s JOIN board.message m ON m.id = s.thread_id
WHERE s.needs_human AND s.status IS DISTINCT FROM 'closed'
UNION ALL
SELECT format('task:%s:%s', t.id, md5(coalesce(t.human_reason, ''))), 'task:' || t.id, NULL, t.updated_at,
       format('Task %s needs you: %s', board.task_ref(t.id), t.title), coalesce(left(t.human_reason, 240), ''), '/tasks/' || t.path
FROM board.task t
WHERE t.needs_human AND t.status NOT IN ('done', 'cancelled')
UNION ALL
SELECT 'msg:' || m.id, 'msg:' || m.id, r.handle, m.created_at,
       format('%s: %s', m.sender, m.subject), left(regexp_replace(m.body, '\s+', ' ', 'g'), 240), '/m/' || m.id
FROM board.recipient r
JOIN board.message m ON m.id = r.message_id
JOIN board.agent h ON h.handle = r.handle AND h.kind = 'human'
WHERE r.read_at IS NULL AND m.sender <> r.handle AND m.created_at > now() - interval '1 day'
  -- addressed to the human alone; a copy among others reaches them as a summarizer escalation if it needs them
  AND NOT EXISTS (SELECT 1 FROM board.recipient o WHERE o.message_id = m.id AND o.handle <> r.handle);

-- for the push worker: one row per (item, human) not pushed yet, with that human's subscriptions that
-- existed when the item arose (so enabling notifications doesn't replay the backlog), plus test pushes
CREATE OR REPLACE FUNCTION board.push_due() RETURNS TABLE (key text, handle text, tag text, title text, body text,
                                                         url text, subs json)
LANGUAGE sql STABLE AS $$
    SELECT a.key, h.handle, a.tag, a.title, a.body, a.url,
           json_agg(json_build_object('endpoint', s.endpoint, 'keys', json_build_object('p256dh', s.p256dh, 'auth', s.auth)))
    FROM board.attention a
    JOIN board.agent h ON h.kind = 'human' AND h.active AND (h.handle = a.audience OR (a.audience IS NULL AND h.is_admin))
    JOIN board.push_subscription s ON s.handle = h.handle AND s.created_at < a.at
    WHERE NOT EXISTS (SELECT 1 FROM board.push_sent p WHERE p.key = a.key AND p.handle = h.handle)
    GROUP BY a.key, h.handle, a.tag, a.title, a.body, a.url
    UNION ALL
    SELECT 'test:' || s.endpoint || ':' || extract(epoch FROM s.test_requested_at), s.handle, 'test', 'board notifications are on',
           'This browser will be told when an agent or a decision needs you.', '/',
           json_build_array(json_build_object('endpoint', s.endpoint, 'keys', json_build_object('p256dh', s.p256dh, 'auth', s.auth)))
    FROM board.push_subscription s
    WHERE s.test_requested_at IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION api.push_key() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT vapid_public FROM board.push_config
$$;

-- this browser's push subscription (PushSubscription.toJSON()), for the logged-in human; sends a test push
CREATE OR REPLACE FUNCTION api.push_subscribe(endpoint text, p256dh text, auth text, user_agent text DEFAULT NULL)
RETURNS json LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me();
BEGIN
    IF (SELECT kind FROM board.agent WHERE handle = me) <> 'human' THEN
        RAISE EXCEPTION 'browser notifications are for humans' USING ERRCODE = '42501';
    END IF;
    IF push_subscribe.endpoint !~ '^https://' THEN RAISE EXCEPTION 'endpoint must be an https URL'; END IF;
    INSERT INTO board.push_subscription AS s (endpoint, handle, p256dh, auth, user_agent, test_requested_at)
    VALUES (push_subscribe.endpoint, me, push_subscribe.p256dh, push_subscribe.auth, left(push_subscribe.user_agent, 300), now())
    ON CONFLICT ON CONSTRAINT push_subscription_pkey DO UPDATE SET handle = me, p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth,
        user_agent = EXCLUDED.user_agent, test_requested_at = now(), last_error = NULL;
    RETURN json_build_object('subscribed', true, 'worker', EXISTS (SELECT 1 FROM board.push_config));
END $$;

CREATE OR REPLACE FUNCTION api.push_unsubscribe(endpoint text) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me();
BEGIN
    DELETE FROM board.push_subscription s WHERE s.endpoint = push_unsubscribe.endpoint AND s.handle = me;
    RETURN json_build_object('subscribed', false);
END $$;

-- ---------------------------------------------------------------- API: admin
CREATE OR REPLACE FUNCTION api.create_invite(note text DEFAULT NULL, max_uses integer DEFAULT 1,
                                             valid_days integer DEFAULT 7) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE i board.invite;
BEGIN
    INSERT INTO board.invite (note, created_by, max_uses, expires_at)
    VALUES (create_invite.note, board.require_admin(), create_invite.max_uses,
            CASE WHEN valid_days > 0 THEN now() + make_interval(days => valid_days) END)
    RETURNING * INTO i;
    RETURN row_to_json(i);
END $$;

CREATE OR REPLACE FUNCTION api.set_active(handle text, active boolean) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
BEGIN
    PERFORM board.require_admin();
    UPDATE board.agent a SET active = set_active.active, updated_at = now() WHERE a.handle = set_active.handle;
    RETURN (SELECT row_to_json(x) FROM api.agents x WHERE x.handle = set_active.handle);
END $$;

-- an agent that is fine to be offline: its silent watcher raises no warning, push or sweep line
CREATE OR REPLACE FUNCTION api.set_offline_ok(handle text, offline_ok boolean) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
BEGIN
    PERFORM board.require_admin();
    UPDATE board.agent a SET offline_ok = set_offline_ok.offline_ok, updated_at = now() WHERE a.handle = set_offline_ok.handle;
    RETURN (SELECT row_to_json(x) FROM api.agents x WHERE x.handle = set_offline_ok.handle);
END $$;

-- the catalog of systems, projects and clients is kept by an admin or the PM agent (board.policy.pm)
CREATE OR REPLACE FUNCTION board.require_curator() RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE h text := board.require_me();
BEGIN
    IF NOT (board.is_admin() OR h = (SELECT pm FROM board.policy)) THEN
        RAISE EXCEPTION 'admins and the PM agent only' USING ERRCODE = '42501';
    END IF;
    RETURN h;
END $$;

-- a task's kind/slug/url/system; NULL leaves a field as is, '' clears it
CREATE OR REPLACE FUNCTION api.task_classify(id bigint, kind text DEFAULT NULL, slug text DEFAULT NULL,
                                             url text DEFAULT NULL, system text DEFAULT NULL) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
BEGIN
    PERFORM board.require_curator();
    UPDATE board.task t SET kind = coalesce(nullif(task_classify.kind, ''), t.kind),
                            slug = CASE WHEN task_classify.slug IS NULL THEN t.slug ELSE nullif(task_classify.slug, '') END,
                            url = CASE WHEN task_classify.url IS NULL THEN t.url ELSE nullif(task_classify.url, '') END,
                            system = CASE WHEN task_classify.system IS NULL THEN t.system ELSE nullif(task_classify.system, '') END,
                            updated_at = now()
    WHERE t.id = task_classify.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'no task %', task_classify.id; END IF;
    RETURN (SELECT row_to_json(x) FROM api.tasks x WHERE x.id = task_classify.id);
END $$;

CREATE OR REPLACE FUNCTION api.system_save(slug text, name text, kind text DEFAULT 'service', owner text DEFAULT NULL,
                                           repo text DEFAULT NULL, description text DEFAULT NULL) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
BEGIN
    PERFORM board.require_curator();
    INSERT INTO board.system AS s (slug, name, kind, owner, repo, description)
    VALUES (system_save.slug, system_save.name, system_save.kind, system_save.owner, system_save.repo, system_save.description)
    ON CONFLICT ON CONSTRAINT system_pkey DO UPDATE SET name = EXCLUDED.name, kind = EXCLUDED.kind, owner = EXCLUDED.owner,
        repo = EXCLUDED.repo, description = EXCLUDED.description;
    RETURN (SELECT row_to_json(x) FROM api.system_catalog x WHERE x.slug = system_save.slug);
END $$;

-- link (or with remove, unlink) a system to the agent running an instance of it
CREATE OR REPLACE FUNCTION api.system_instance(system text, agent text, label text DEFAULT NULL, remove boolean DEFAULT false)
RETURNS json LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
BEGIN
    PERFORM board.require_curator();
    IF remove THEN
        DELETE FROM board.system_instance i WHERE i.system = system_instance.system AND i.agent = system_instance.agent;
    ELSE
        INSERT INTO board.system_instance AS i (system, agent, label) VALUES (system_instance.system, system_instance.agent, system_instance.label)
        ON CONFLICT ON CONSTRAINT system_instance_pkey DO UPDATE SET label = EXCLUDED.label;
    END IF;
    RETURN (SELECT row_to_json(x) FROM api.system_catalog x WHERE x.slug = system_instance.system);
END $$;

CREATE OR REPLACE FUNCTION api.project_system(project_id bigint, system text, role text DEFAULT 'uses', remove boolean DEFAULT false)
RETURNS json LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
BEGIN
    PERFORM board.require_curator();
    IF remove THEN
        DELETE FROM board.project_system ps WHERE ps.project_id = project_system.project_id AND ps.system = project_system.system;
    ELSE
        INSERT INTO board.project_system AS ps (project_id, system, role) VALUES (project_system.project_id, project_system.system, project_system.role)
        ON CONFLICT ON CONSTRAINT project_system_pkey DO UPDATE SET role = EXCLUDED.role;
    END IF;
    RETURN (SELECT row_to_json(x) FROM api.projects x WHERE x.id = project_system.project_id);
END $$;

CREATE OR REPLACE FUNCTION api.client_save(slug text, name text, kind text DEFAULT 'organisation', notes text DEFAULT NULL)
RETURNS json LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
BEGIN
    PERFORM board.require_curator();
    INSERT INTO board.client AS c (slug, name, kind, notes) VALUES (client_save.slug, client_save.name, client_save.kind, client_save.notes)
    ON CONFLICT ON CONSTRAINT client_pkey DO UPDATE SET name = EXCLUDED.name, kind = EXCLUDED.kind, notes = EXCLUDED.notes;
    RETURN (SELECT row_to_json(x) FROM api.clients x WHERE x.slug = client_save.slug);
END $$;

CREATE OR REPLACE FUNCTION api.project_client(project_id bigint, client text, for_client text DEFAULT NULL, remove boolean DEFAULT false)
RETURNS json LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
BEGIN
    PERFORM board.require_curator();
    IF remove THEN
        DELETE FROM board.project_client pc WHERE pc.project_id = project_client.project_id AND pc.client = project_client.client;
    ELSE
        INSERT INTO board.project_client AS pc (project_id, client, for_client)
        VALUES (project_client.project_id, project_client.client, nullif(project_client.for_client, ''))
        ON CONFLICT ON CONSTRAINT project_client_pkey DO UPDATE SET for_client = EXCLUDED.for_client;
    END IF;
    RETURN (SELECT row_to_json(x) FROM api.projects x WHERE x.id = project_client.project_id);
END $$;

-- revokes every outstanding token of `handle` and returns a fresh one
CREATE OR REPLACE FUNCTION api.reissue_token(handle text) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
BEGIN
    PERFORM board.require_admin();
    UPDATE board.agent a SET token_version = a.token_version + 1, updated_at = now()
    WHERE a.handle = reissue_token.handle AND a.kind = 'agent';
    IF NOT FOUND THEN RAISE EXCEPTION 'no agent "%"', reissue_token.handle; END IF;
    UPDATE board.agent_token t SET revoked_at = now() WHERE t.handle = reissue_token.handle AND t.revoked_at IS NULL;
    RETURN json_build_object('handle', reissue_token.handle,
                             'token', board.token_for(reissue_token.handle, 'reissue', board.me()));
END $$;

-- an agent revokes all of its own tokens and gets a fresh one (doc:service-credentials, #308/8): the new token goes
-- straight back to the caller over HTTPS, so no secret moves through anyone else
CREATE OR REPLACE FUNCTION api.rotate_my_token() RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE h text := board.require_me();
BEGIN
    UPDATE board.agent a SET token_version = a.token_version + 1, updated_at = now()
    WHERE a.handle = h AND a.kind = 'agent';
    IF NOT FOUND THEN RAISE EXCEPTION 'only agents rotate their token'; END IF;
    UPDATE board.agent_token t SET revoked_at = now() WHERE t.handle = h AND t.revoked_at IS NULL;
    RETURN json_build_object('handle', h, 'token', board.token_for(h, 'rotate', h));
END $$;

-- daily self-refresh (#308/8): a valid token swaps for a fresh 7-day one with the same token_version, so the old one
-- keeps working until its own exp (the watcher's fallback if writing the new one fails). Text: the bare token.
CREATE OR REPLACE FUNCTION api.refresh_my_token() RETURNS api."text/plain"
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE h text := board.require_me();
BEGIN
    IF NOT EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = h AND a.kind = 'agent' AND a.active) THEN
        RAISE EXCEPTION 'only active agents refresh their token';
    END IF;
    RETURN board.token_for(h, 'refresh', h);
END $$;

-- the register, for the admin (/agents): no token values, only who/why/when/until
CREATE OR REPLACE VIEW api.agent_tokens AS
SELECT t.jti, t.handle, t.tv, t.reason, t.issued_by, t.issued_at, t.expires_at, t.revoked_at,
       (t.revoked_at IS NULL AND t.expires_at > now()
        AND t.tv = (SELECT a.token_version FROM board.agent a WHERE a.handle = t.handle)) AS live
FROM board.agent_token t WHERE board.is_admin();

-- ---------------------------------------------------------------- Needs you: urgency levels
-- a task that starts needing the human again starts at "soon" unless its level was set in the same statement
CREATE OR REPLACE FUNCTION board.task_level_reset() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.needs_human AND NOT OLD.needs_human AND NEW.human_level IS NOT DISTINCT FROM OLD.human_level THEN
        NEW.human_level := 2;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS task_level_reset ON board.task;
CREATE TRIGGER task_level_reset BEFORE UPDATE OF needs_human ON board.task
    FOR EACH ROW EXECUTE FUNCTION board.task_level_reset();

-- rate a "needs you": level urgent|soon|whenever (or 1-3), with an optional why for the log. The human, the PM
-- (board.policy.pm) and the task's assignee may.
CREATE OR REPLACE FUNCTION api.task_urgency(id bigint, level text, why text DEFAULT NULL) RETURNS api."text/plain"
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); t board.task; l smallint;
BEGIN
    l := CASE lower(btrim(level)) WHEN 'urgent' THEN 1 WHEN '1' THEN 1 WHEN 'soon' THEN 2 WHEN '2' THEN 2
                                  WHEN 'whenever' THEN 3 WHEN '3' THEN 3 END;
    IF l IS NULL THEN RAISE EXCEPTION 'level must be urgent, soon or whenever'; END IF;
    SELECT * INTO t FROM board.task x WHERE x.id = task_urgency.id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'task % not found', task_urgency.id; END IF;
    IF NOT (board.is_admin() OR me = t.assignee OR me = (SELECT p.pm FROM board.policy p LIMIT 1)) THEN
        RAISE EXCEPTION 'only the human, the PM or the assignee rates a task''s urgency';
    END IF;
    IF t.human_level <> l THEN
        UPDATE board.task x SET human_level = l WHERE x.id = t.id;
        INSERT INTO board.task_note (task_id, author, body, change)
        VALUES (t.id, me, '', format('urgency: %s -> %s%s', (ARRAY['urgent','soon','whenever'])[t.human_level],
                                     (ARRAY['urgent','soon','whenever'])[l], coalesce(' (' || left(nullif(why, ''), 300) || ')', '')));
    END IF;
    RETURN format('task %s: %s', board.task_ref(t.id), (ARRAY['urgent','soon','whenever'])[l]);
END $$;

-- ---------------------------------------------------------------- Claude activity (watcher v16+, guy 2026-11-10)
-- Each watcher reads its Claude session transcripts (~/.claude/projects/**/*.jsonl) incrementally, about hourly,
-- and pushes one line per ACTIVE MINUTE: when the session wrote to its transcript, or was busy between two
-- entries (a running tool, a model call; short gaps are filled on the agent's side). With each minute go the
-- board objects the agent mentioned in it (refs), as written: t:<task id> ("board task note 191", "--task 191"),
-- p:<task path> ("#119/3", ".../tasks/162/5"), m:<message id> ("/m/1797", "board read 1797"), n:<bare #N>,
-- and who drove it: u:<name> for a "[from <name>]" prompt (a human via claude-ui), u:board for a watcher line (miko's tip).
-- A period ("session") of activity = a run of consecutive active minutes; each new prompt in it (u: ref) starts a
-- segment. Each minute is painted with the targets mentioned last before it in its segment (the first ones, for
-- the minutes before them; none mentioned: '' = untagged), split
-- evenly when there are several: that is the load per task. targets: 't<task id>', or 'h<thread id>' for a
-- thread filed under no task (a thread under tasks counts for its most specific one).
CREATE TABLE IF NOT EXISTS board.activity_minute (
    handle    text NOT NULL REFERENCES board.agent (handle) ON UPDATE CASCADE ON DELETE CASCADE,
    minute    timestamptz NOT NULL,
    lines     integer NOT NULL DEFAULT 0,          -- transcript entries written in that minute (0: busy, filled)
    refs      text[] NOT NULL DEFAULT '{}',
    targets   text[] NOT NULL DEFAULT '{}',
    pushed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (handle, minute)
);
CREATE INDEX IF NOT EXISTS activity_minute_minute_idx ON board.activity_minute (minute);

-- one ref -> its target ('t<id>' / 'h<thread id>'), NULL if it names nothing. A bare "#N" is a message, unless
-- that message is older than two weeks (or missing) and a top-level task #N/ exists: agents write tasks as "#20" too.
CREATE OR REPLACE FUNCTION board.activity_target(ref text, at timestamptz) RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE k text := split_part(ref, ':', 1); v text := split_part(ref, ':', 2); n bigint; th bigint; tk bigint;
BEGIN
    IF k = 't' AND v ~ '^\d{1,9}$' THEN
        RETURN (SELECT 't' || t.id FROM board.task t WHERE t.id = v::bigint);
    ELSIF k = 'p' AND v ~ '^\d{1,9}(/\d{1,9})*$' THEN
        RETURN 't' || board.task_resolve(v);
    ELSIF k IN ('m', 'n') AND v ~ '^\d{1,9}$' THEN
        n := v::bigint;
        IF k = 'n' AND n < 10 THEN RETURN NULL; END IF;      -- "#1", "#2": list items, not board objects
        SELECT coalesce(m.thread_id, m.id) INTO th FROM board.message m
        WHERE m.id = n AND (k = 'm' OR m.created_at > at - interval '14 days');
        IF th IS NULL THEN
            RETURN CASE WHEN k = 'n' THEN (SELECT 't' || t.id FROM board.task t WHERE t.path = v) END;
        END IF;
        SELECT x.task_id INTO tk FROM board.task_thread x JOIN board.task t ON t.id = x.task_id
        WHERE x.thread_id = th ORDER BY length(t.path) DESC, x.linked_at DESC LIMIT 1;
        RETURN coalesce('t' || tk, 'h' || th);
    END IF;
    RETURN NULL;
END $$;

-- the watcher's upload: lines "<unix minute start>\t<entries>\t<refs, space-separated>". Pushes are incremental
-- (the watcher remembers how far it read each transcript), so a minute that shows up again adds up.
CREATE OR REPLACE FUNCTION api.activity_push(data text) RETURNS api."text/plain"
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE me text := board.require_me(); n integer;
BEGIN
    -- v16 read every transcript of the unix user: agents sharing one (caladan) reported each other's work. v17 reads
    -- only its own session's directory, from scratch (a new state file); v16's pushes are dropped.
    IF coalesce((SELECT a.watcher_version FROM board.agent a WHERE a.handle = me), 0) < 17 THEN
        RETURN 'ok 0 minutes (watcher older than v17: ignored)';
    END IF;
    WITH l AS (
        SELECT split_part(x, E'\t', 1) AS e, split_part(x, E'\t', 2) AS c, split_part(x, E'\t', 3) AS r
        FROM regexp_split_to_table(coalesce(data, ''), E'\n') x
    ), p AS (
        SELECT date_trunc('minute', to_timestamp(e::bigint)) AS minute,
               CASE WHEN c ~ '^\d{1,6}$' THEN c::integer ELSE 0 END AS c,
               ARRAY(SELECT DISTINCT left(t, 40) FROM regexp_split_to_table(r, ' ') t
                     WHERE t ~ '^([tpmn]:\d[\d/]*|u:[A-Za-z0-9_.-]{1,30})$' LIMIT 40) AS refs
        FROM l WHERE e ~ '^\d{9,11}$'
    ), f AS (
        SELECT p.minute, r FROM p, unnest(p.refs) r
    ), g AS (
        SELECT p.minute, sum(p.c)::integer AS c,
               coalesce((SELECT array_agg(DISTINCT f.r) FROM f WHERE f.minute = p.minute), '{}') AS refs
        FROM p GROUP BY p.minute
    ), ins AS (
        INSERT INTO board.activity_minute AS a (handle, minute, lines, refs, targets)
        SELECT me, g.minute, g.c, g.refs,
               ARRAY(SELECT DISTINCT x FROM unnest(g.refs) r, board.activity_target(r, g.minute) x WHERE x IS NOT NULL)
        FROM g WHERE g.minute > now() - interval '400 days' AND g.minute < now() + interval '10 minutes'
        ON CONFLICT (handle, minute) DO UPDATE SET
            lines = a.lines + EXCLUDED.lines,
            refs = ARRAY(SELECT DISTINCT u FROM unnest(a.refs || EXCLUDED.refs) u),
            targets = ARRAY(SELECT DISTINCT u FROM unnest(a.targets || EXCLUDED.targets) u),
            pushed_at = now()
        RETURNING 1
    )
    SELECT count(*) INTO n FROM ins;
    RETURN format('ok %s minutes', n);
END $$;

-- each active minute in [since, until) of one agent (or all), with its period and the targets it is painted with
CREATE OR REPLACE FUNCTION board.activity_painted(since timestamptz, until timestamptz, who text DEFAULT NULL)
RETURNS TABLE (handle text, period timestamptz, minute timestamptz, lines integer, target text, weight numeric)
LANGUAGE sql STABLE AS $$
    WITH m AS (
        SELECT a.handle, a.minute, a.lines, a.targets,
               EXISTS (SELECT 1 FROM unnest(a.refs) r WHERE r LIKE 'u:%') AS prompt
        FROM board.activity_minute a
        WHERE a.minute >= since AND a.minute < until AND (who IS NULL OR a.handle = who)
    ), isl AS (   -- consecutive minutes share grp (gaps and islands)
        SELECT m.*, m.minute - (row_number() OVER (PARTITION BY m.handle ORDER BY m.minute)) * interval '1 minute' AS grp FROM m
    ), sg AS (    -- a new prompt (a human's "[from X]" or a watcher line) starts a new segment of the period
        SELECT isl.*, count(*) FILTER (WHERE isl.prompt) OVER (PARTITION BY isl.handle, isl.grp ORDER BY isl.minute) AS seg FROM isl
    ), mk AS (    -- c: how many mentioning minutes so far in the segment
        SELECT sg.*, count(*) FILTER (WHERE cardinality(sg.targets) > 0)
                     OVER (PARTITION BY sg.handle, sg.grp, sg.seg ORDER BY sg.minute) AS c FROM sg
    ), tg AS (
        SELECT mk.handle, mk.grp, mk.seg, mk.c, mk.targets FROM mk WHERE cardinality(mk.targets) > 0
    ), att AS (
        SELECT mk.handle, mk.grp, mk.minute, mk.lines, coalesce(tg.targets, '{}') AS targets
        FROM mk LEFT JOIN tg ON tg.handle = mk.handle AND tg.grp = mk.grp AND tg.seg = mk.seg AND tg.c = greatest(mk.c, 1)
    )
    SELECT att.handle, min(att.minute) OVER (PARTITION BY att.handle, att.grp), att.minute, att.lines, t,
           round(1.0 / greatest(cardinality(att.targets), 1), 4)
    FROM att, unnest(CASE WHEN cardinality(att.targets) = 0 THEN '{""}'::text[] ELSE att.targets END) t
$$;

-- load per agent and target (minutes; '' = no board object mentioned), per day in time zone tz, or in total
-- (bucket 'total': day is NULL). periods = distinct periods touching that bucket.
CREATE OR REPLACE FUNCTION api.activity_load(since timestamptz, until timestamptz DEFAULT now(), bucket text DEFAULT 'day',
                                             tz text DEFAULT 'UTC')
RETURNS TABLE (handle text, day date, target text, minutes numeric, periods integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT p.handle, CASE WHEN bucket = 'total' THEN NULL ELSE (p.minute AT TIME ZONE tz)::date END,
           p.target, round(sum(p.weight), 1), count(DISTINCT p.period)::integer
    FROM board.activity_painted(since, until) p
    WHERE board.require_me() IS NOT NULL
    GROUP BY 1, 2, 3
$$;

-- the periods of activity themselves: start, end, active minutes, transcript entries, the targets with their minutes,
-- and who drove the period (the u: refs: 'board' = watcher lines, else the human named in a "[from X]" prompt)
CREATE OR REPLACE FUNCTION api.activity_periods(since timestamptz, until timestamptz DEFAULT now(), who text DEFAULT NULL)
RETURNS TABLE (handle text, started timestamptz, ended timestamptz, minutes integer, lines integer, targets jsonb, drivers text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    WITH p AS (SELECT * FROM board.activity_painted(since, until, nullif(who, '')) WHERE board.require_me() IS NOT NULL),
    per AS (
        SELECT p.handle, p.period, max(p.minute) + interval '1 minute' AS ended,
               count(DISTINCT p.minute)::integer AS minutes
        FROM p GROUP BY 1, 2
    ), ln AS (
        SELECT x.handle, x.period, sum(x.lines)::integer AS lines
        FROM (SELECT DISTINCT p.handle, p.period, p.minute, p.lines FROM p) x GROUP BY 1, 2
    ), tg AS (
        SELECT p.handle, p.period, jsonb_agg(jsonb_build_object('target', p.target, 'minutes', round(p.m, 1)) ORDER BY p.m DESC) AS targets
        FROM (SELECT p.handle, p.period, p.target, sum(p.weight) AS m FROM p GROUP BY 1, 2, 3) p GROUP BY 1, 2
    )
    SELECT per.handle, per.period, per.ended, per.minutes, ln.lines, tg.targets,
           ARRAY(SELECT DISTINCT substr(r, 3) FROM board.activity_minute a, unnest(a.refs) r
                 WHERE a.handle = per.handle AND a.minute >= per.period AND a.minute < per.ended AND r LIKE 'u:%') AS drivers
    FROM per JOIN ln USING (handle, period) JOIN tg USING (handle, period)
    ORDER BY per.period DESC
$$;

-- ---------------------------------------------------------------- grants
GRANT USAGE ON SCHEMA api TO board_anon, board_agent, board_admin;
REVOKE ALL ON ALL TABLES IN SCHEMA api FROM board_anon, board_agent, board_admin;
GRANT SELECT ON api.agents, api.messages, api.threads, api.tags, api.systems,
                api.tasks, api.task_notes, api.task_threads, api.task_escalations, api.message_stats, api.thread_links, api.docs, api.doc_versions, api.doc_comments, api.reviews, api.review_revs, api.review_comments,
                api.thread_summary_versions, api.projects, api.system_catalog, api.clients
      TO board_agent, board_admin;
GRANT SELECT ON api.invites, api.login_requests TO board_admin;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA api FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA board FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.pre_request() TO board_anon, board_agent, board_admin;
-- helpers used inside api views (a view checks EXECUTE as the caller)
GRANT EXECUTE ON FUNCTION board.remote_clean(text), board.remote_repo(text), board.compare_url(text, text, text) TO board_agent, board_admin;
GRANT EXECUTE ON FUNCTION api.register(text, text, text, text, text, text, text, text, text) TO board_anon;
GRANT EXECUTE ON FUNCTION api.update_profile(text, text, text, text, text, text, text, text),
                          api.post(text, text, text, text, text, bigint, bigint), api.thread_link(bigint, bigint, text, boolean), api.thread_lock(bigint, text, boolean),
                          api.poll(integer), api.read(bigint), api.mark_read(bigint[]),
                          api.thread(bigint), api.inbox(boolean, integer),
                          api.summarize(bigint, text, text, boolean, text, bigint), api.summaries(boolean, integer),
                          api.search(text, text, text, text, text, timestamptz, timestamptz, integer),
                          api.directory(), api.whoami(),
                          api.watch_sync(text, text, integer, text, text), api.login_progress(bigint, text, text, text, text),
                          api.task_create(text, text, text, bigint, text, text, text), api.task_id(text),
                          api.task_update(bigint, text, text, text, text, text, bigint, text, text, boolean, text, double precision),
                          api.task_link(bigint, bigint, boolean), api.task(bigint), api.task_list(boolean, text, boolean),
                          api.push_key(), api.push_subscribe(text, text, text, text), api.push_unsubscribe(text),
                          api.doc_save(text, text, text, text), api.doc(text, integer), api.doc_list(),
                          api.doc_comment(text, text, text, integer, text, text), api.doc_comment_resolve(bigint, boolean),
                          api.review_submit(text, text, text, text, text, text, text, text, text, text, text, text), api.review_comment(bigint, text, integer, text, text, integer, text),
                          api.review_comment_resolve(bigint, boolean), api.review_decide(bigint, text, text), api.review_done(bigint, text, text, text),
                          api.review_text(bigint, boolean, boolean),
                          api.task_classify(bigint, text, text, text, text), api.system_save(text, text, text, text, text, text),
                          api.system_instance(text, text, text, boolean), api.project_system(bigint, text, text, boolean),
                          api.client_save(text, text, text, text), api.project_client(bigint, text, text, boolean)
      TO board_agent, board_admin;
GRANT SELECT ON api.agent_tokens TO board_admin;
GRANT EXECUTE ON FUNCTION api.rotate_my_token(), api.refresh_my_token(), api.task_urgency(bigint, text, text), api.activity_push(text), api.activity_load(timestamptz, timestamptz, text, text),
                          api.activity_periods(timestamptz, timestamptz, text)
      TO board_agent, board_admin;
GRANT EXECUTE ON FUNCTION api.create_invite(text, integer, integer), api.set_active(text, boolean), api.set_offline_ok(text, boolean),
                          api.reissue_token(text),
                          api.request_login(text), api.submit_login_code(bigint, text), api.cancel_login(bigint)
      TO board_admin;
-- api.messages evaluates board.me() for my_read_at/to_me; function EXECUTE is checked against the
-- caller, so the API roles need it (it only reads the JWT claims; no table privileges come with this)
GRANT USAGE ON SCHEMA board TO board_anon, board_agent, board_admin;
GRANT EXECUTE ON FUNCTION board.me(), board.require_me(), board.is_admin(), board.via_auth(), board.auth_handle(json) TO board_anon, board_agent, board_admin;
GRANT EXECUTE ON FUNCTION board.task_project(bigint) TO board_agent, board_admin;  -- used by api.tasks / api.projects

NOTIFY pgrst, 'reload schema';

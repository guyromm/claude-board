-- Agent message board: schema `board` (data, never exposed) + schema `api` (PostgREST surface).
-- Applied as the owner (unix user board, peer auth):  psql postgresql:///board -f sql/bootstrap.sql
-- Re-runnable: tables are IF NOT EXISTS, functions/views CREATE OR REPLACE. After changing the live
-- DB, run ./pg_schema_dump.py to refresh the per-object dump in sql/schema/.
--
-- AUTH MODEL. PostgREST verifies HS256 JWTs signed with PGRST_JWT_SECRET; board.secret holds the same
-- secret (synced from .env by `./tmux.sh apply`) so register()/login() can mint tokens in SQL.
--   claims: {role: board_agent|board_admin, handle, tv}   (+ exp for password logins)
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
    password_hash    text,                       -- humans only (crypt/bf); agents use tokens
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

-- handle of the caller, from the verified JWT (NULL for anonymous)
CREATE OR REPLACE FUNCTION board.me() RETURNS text LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('request.jwt.claims', true), '')::json ->> 'handle'
$$;

CREATE OR REPLACE FUNCTION board.require_me() RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE h text := board.me();
BEGIN
    IF h IS NULL THEN RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000'; END IF;
    RETURN h;
END $$;

CREATE OR REPLACE FUNCTION board.require_admin() RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE h text := board.require_me();
BEGIN
    IF NOT EXISTS (SELECT 1 FROM agent WHERE handle = h AND is_admin AND active) THEN
        RAISE EXCEPTION 'admin only' USING ERRCODE = '42501';
    END IF;
    RETURN h;
END $$;

-- the caller is an active admin (non-raising); also claude-ui's default admin predicate (/claude)
CREATE OR REPLACE FUNCTION board.is_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT EXISTS (SELECT 1 FROM agent WHERE handle = board.me() AND is_admin AND active)
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

CREATE OR REPLACE FUNCTION board.token_for(h text, ttl interval DEFAULT NULL) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT board.sign_jwt(json_strip_nulls(json_build_object(
        'role', CASE WHEN a.is_admin THEN 'board_admin' ELSE 'board_agent' END,
        'handle', a.handle, 'tv', a.token_version,
        'exp', CASE WHEN ttl IS NOT NULL THEN extract(epoch FROM now() + ttl)::bigint END)))
    FROM board.agent a WHERE a.handle = h
$$;
REVOKE ALL ON FUNCTION board.token_for(text, interval) FROM PUBLIC;

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
    IF c IS NULL OR c ->> 'handle' IS NULL THEN RETURN; END IF;   -- anonymous
    IF NOT EXISTS (SELECT 1 FROM agent a WHERE a.handle = c ->> 'handle' AND a.active
                   AND a.token_version = (c ->> 'tv')::int) THEN
        RAISE EXCEPTION 'token revoked or agent inactive' USING ERRCODE = '28000',
            HINT = 'ask the board admin to reissue your token';
    END IF;
END $$;

-- ---------------------------------------------------------------- API: views (JSON, for the web UI)
CREATE OR REPLACE VIEW api.agents AS
SELECT a.handle, a.kind, a.display_name, a.host, a.tmux_target, a.system, a.description,
       a.responsibilities, a.goals, a.is_admin, a.active, a.created_at, a.updated_at, a.last_seen_at,
       (SELECT count(*) FROM board.message m WHERE m.sender = a.handle) AS sent_count,
       (SELECT count(*) FROM board.recipient r WHERE r.handle = a.handle) AS received_count,
       a.session_state, a.session_detail, a.session_checked_at, a.session_changed_at, a.watcher_version,
       a.claude_ui_url
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
    RETURN json_build_object('handle', h, 'token', board.token_for(h), 'intro_message_id', mid);
END $$;

CREATE OR REPLACE FUNCTION api.login(handle text, password text) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE a board.agent;
BEGIN
    SELECT * INTO a FROM board.agent x WHERE x.handle = lower(btrim(login.handle)) AND x.active;
    IF NOT FOUND OR a.password_hash IS NULL OR a.password_hash <> crypt(login.password, a.password_hash) THEN
        PERFORM pg_sleep(0.5);
        RAISE EXCEPTION 'invalid handle or password' USING ERRCODE = '28P01';
    END IF;
    UPDATE board.agent x SET last_seen_at = now() WHERE x.handle = a.handle;
    RETURN json_build_object('handle', a.handle, 'is_admin', a.is_admin,
                             'token', board.token_for(a.handle, interval '30 days'));
END $$;

-- humans (password logins) change their own password
CREATE OR REPLACE FUNCTION api.set_password(old_password text, new_password text) RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
DECLARE h text := board.require_me();
BEGIN
    IF length(new_password) < 10 THEN RAISE EXCEPTION 'password must be at least 10 characters'; END IF;
    UPDATE board.agent a SET password_hash = crypt(new_password, gen_salt('bf')), updated_at = now()
    WHERE a.handle = h AND a.password_hash IS NOT NULL AND a.password_hash = crypt(old_password, a.password_hash);
    IF NOT FOUND THEN RAISE EXCEPTION 'current password is wrong' USING ERRCODE = '28P01'; END IF;
    RETURN true;
END $$;

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
        tn integer; tlines text; cn integer; clines text; pn integer; plines text; swline text;
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
    SELECT count(*), string_agg(format('[board] task #%s "%s" was assigned to you by %s -- see it with: board task %s',
                                       t.id, t.title, coalesce(w.author, t.created_by), t.id), E'\n' ORDER BY t.id)
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
                   '[board] task #%s "%s" [%s, @%s]: %s -- check in: board task %s, then nudge the assignee, re-assign/split it, or escalate (board task update %s --human "WHY")',
                   t.id, t.title, t.status, coalesce(t.assignee, 'unassigned'),
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
                          count(*), string_agg(format('#%s %s @%s %s%s', t.id, t.status, coalesce(t.assignee, '-'),
                                                      board.fmt_age(now() - t.activity_at),
                                                      CASE WHEN t.needs_human THEN ' (HUMAN ANSWERED: act on it, then clear --no-human)' ELSE '' END),
                                               ', ' ORDER BY t.needs_human DESC, t.activity_at))
            INTO swline
            FROM board.task t WHERE t.status NOT IN ('done', 'cancelled') AND t.check_every <= interval '1 day'
              AND (NOT t.needs_human OR board.task_human_answered(t.id));
            plines := concat_ws(E'\n', plines, swline);
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

CREATE OR REPLACE FUNCTION api.whoami() RETURNS json
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT row_to_json(x) FROM api.agents x WHERE x.handle = board.require_me()
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
CREATE OR REPLACE VIEW api.tasks AS
SELECT t.id, t.parent_id, t.title, t.description, t.status, t.assignee, t.created_by, t.check_every::text AS check_every,
       t.due_at, t.needs_human, t.human_reason, t.position, t.created_at, t.updated_at, t.status_changed_at, t.activity_at,
       t.pm_prompted_at,
       (t.status NOT IN ('done', 'cancelled') AND t.activity_at < now() - t.check_every) AS overdue_checkin,
       (SELECT count(*) FROM board.task c WHERE c.parent_id = t.id AND c.status <> 'cancelled') AS subtasks,
       (SELECT count(*) FROM board.task c WHERE c.parent_id = t.id AND c.status = 'done') AS subtasks_done,
       coalesce((SELECT array_agg(x.thread_id ORDER BY x.thread_id) FROM board.task_thread x WHERE x.task_id = t.id), '{}') AS threads,
       (SELECT count(*) FROM board.task_note n WHERE n.task_id = t.id) AS notes,
       (SELECT n.body FROM board.task_note n WHERE n.task_id = t.id AND n.body <> '' ORDER BY n.id DESC LIMIT 1) AS last_note
FROM board.task t;

CREATE OR REPLACE VIEW api.task_notes AS
SELECT n.id, n.task_id, n.author, n.body, n.change, n.created_at FROM board.task_note n;

CREATE OR REPLACE VIEW api.task_threads AS
SELECT x.task_id, x.thread_id, x.linked_by, x.linked_at, r.subject, t.last_at, t.size, t.status, t.needs_human, t.summary
FROM board.task_thread x JOIN board.message r ON r.id = x.thread_id
JOIN api.threads t ON t.thread_id = x.thread_id;

-- one line per task: #12 [doing] title  @pethelp  2/5 subtasks  last activity 3h  !needs human
CREATE OR REPLACE FUNCTION board.fmt_task(t board.task, indent integer DEFAULT 0) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT format('%s#%s [%s] %s  @%s%s  activity %s ago%s%s',
        repeat('  ', indent), t.id, t.status, t.title, coalesce(t.assignee, 'unassigned'),
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
    RETURN format('task #%s created: %s', t.id, board.fmt_task(t));
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
        n.needs_human := task_update.needs_human;
        n.human_reason := CASE WHEN task_update.needs_human THEN btrim(task_update.human_reason) END;
    END IF;
    IF task_update."position" IS NOT NULL THEN n.position := task_update."position"; END IF;
    -- closing a task settles its escalation
    IF n.status IN ('done', 'cancelled') AND n.status IS DISTINCT FROM o.status AND n.needs_human
       AND task_update.needs_human IS NULL THEN
        n.needs_human := false; n.human_reason := NULL;
    END IF;

    IF n.status IS DISTINCT FROM o.status THEN changes := changes || format('status: %s -> %s', o.status, n.status); END IF;
    IF n.assignee IS DISTINCT FROM o.assignee THEN
        changes := changes || format('assignee: %s -> %s', coalesce(o.assignee, '-'), coalesce(n.assignee, '-'));
    END IF;
    IF n.title IS DISTINCT FROM o.title THEN changes := changes || format('title: "%s"', n.title); END IF;
    IF n.description IS DISTINCT FROM o.description THEN changes := changes || 'description edited'::text; END IF;
    IF n.parent_id IS DISTINCT FROM o.parent_id THEN changes := changes || format('parent: %s', coalesce('#' || n.parent_id, '-')); END IF;
    IF n.check_every IS DISTINCT FROM o.check_every THEN changes := changes || format('check-in every %s', n.check_every); END IF;
    IF n.due_at IS DISTINCT FROM o.due_at THEN changes := changes || format('due: %s', coalesce(board.fmt_ts(n.due_at), '-')); END IF;
    IF n.needs_human IS DISTINCT FROM o.needs_human OR n.human_reason IS DISTINCT FROM o.human_reason THEN
        changes := changes || CASE WHEN n.needs_human THEN 'escalated to the human: ' || n.human_reason ELSE 'escalation cleared' END;
    END IF;
    IF cardinality(changes) = 0 AND nullif(btrim(task_update.note), '') IS NULL THEN
        IF n.position IS DISTINCT FROM o.position THEN
            UPDATE board.task x SET position = n.position WHERE x.id = o.id;
            RETURN format('task #%s moved', o.id);
        END IF;
        RETURN format('task #%s: nothing changed', o.id);
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
        SELECT DISTINCT ON (r.handle) o.id, r.handle, format('[board] task #%s "%s" moved %s -> %s by %s%s%s -- see it with: board task %s',
               o.id, n.title, o.status, n.status, me,
               CASE WHEN r.why = 'parent' THEN format(' (subtask of #%s "%s")', p.id, p.title) ELSE '' END,
               CASE WHEN nullif(btrim(task_update.note), '') IS NOT NULL
                    THEN ': "' || left(regexp_replace(btrim(task_update.note), '\s+', ' ', 'g'), 150)
                         || CASE WHEN length(btrim(task_update.note)) > 150 THEN '…' ELSE '' END || '"' ELSE '' END,
               o.id)
        FROM (SELECT 1) one
        LEFT JOIN board.task p ON p.id = n.parent_id
        CROSS JOIN LATERAL (VALUES (n.assignee, 'task'), (n.created_by, 'task'),
                                   (CASE WHEN n.status IN ('done', 'cancelled') THEN p.assignee END, 'parent'),
                                   (CASE WHEN n.status IN ('done', 'cancelled') THEN p.created_by END, 'parent'),
                                   (CASE WHEN n.status IN ('done', 'cancelled') THEN (SELECT pm FROM board.policy) END, 'task')) r(handle, why)
        JOIN board.agent a ON a.handle = r.handle AND a.kind = 'agent'
        WHERE r.handle <> me
          AND NOT (r.handle = n.assignee AND n.assignee IS DISTINCT FROM o.assignee)
          AND NOT (r.handle = (SELECT pm FROM board.policy) AND n.status IN ('blocked', 'review'))
        ORDER BY r.handle, r.why;  -- 'parent' first: one line per person, with the subtask context
    ELSIF (SELECT kind FROM board.agent WHERE handle = me) = 'human' THEN
        -- a human's note or edit (an approval, an answer, a correction) must reach the agents who own the
        -- task; agents' own notes stay silent (progress reports)
        INSERT INTO board.task_notice (task_id, handle, line)
        SELECT DISTINCT o.id, r.handle, format('[board] task #%s "%s": %s %s%s -- see it with: board task %s',
               o.id, n.title, me,
               CASE WHEN nullif(btrim(task_update.note), '') IS NOT NULL
                    THEN 'noted "' || left(regexp_replace(btrim(task_update.note), '\s+', ' ', 'g'), 200)
                         || CASE WHEN length(btrim(task_update.note)) > 200 THEN '…' ELSE '' END || '"' ELSE 'edited it' END,
               CASE WHEN cardinality(changes) > 0 THEN ' (' || array_to_string(changes, '; ') || ')' ELSE '' END,
               o.id)
        FROM (VALUES (n.assignee), (n.created_by)) r(handle)
        JOIN board.agent a ON a.handle = r.handle AND a.kind = 'agent'
        WHERE NOT (r.handle = n.assignee AND n.assignee IS DISTINCT FROM o.assignee);
    END IF;
    RETURN format('task #%s updated%s', o.id, CASE WHEN cardinality(changes) > 0 THEN ' (' || array_to_string(changes, '; ') || ')' ELSE ': note added' END);
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
        RETURN format('thread #%s unlinked from task #%s', th, task_link.id);
    END IF;
    INSERT INTO board.task_thread (task_id, thread_id, linked_by) VALUES (task_link.id, th, me) ON CONFLICT DO NOTHING;
    RETURN format('thread #%s linked to task #%s', th, task_link.id);
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
    SELECT string_agg(format('#%s %s', up.id, up.title), ' > ' ORDER BY up.d DESC) INTO path FROM up;
    SELECT string_agg(board.fmt_task(c, 1), E'\n' ORDER BY c.status = 'done', c.position, c.id) INTO subs
    FROM board.task c WHERE c.parent_id = t.id AND c.status <> 'cancelled';
    SELECT string_agg(format('  #%s "%s"  %s%s', x.thread_id, x.subject, upper(coalesce(x.status, 'unsummarized')),
                             coalesce(': ' || replace(left(x.summary, 200), E'\n', ' '), '')), E'\n' ORDER BY x.thread_id) INTO ths
    FROM api.task_threads x WHERE x.task_id = t.id;
    SELECT string_agg(format('  %s %s: %s', board.fmt_ts(n.created_at), n.author,
                             concat_ws(' | ', '[' || n.change || ']', nullif(n.body, ''))), E'\n' ORDER BY n.id) INTO log
    FROM (SELECT * FROM board.task_note n WHERE n.task_id = t.id ORDER BY n.id DESC LIMIT 15) n;
    RETURN concat_ws(E'\n',
        board.fmt_task(t),
        CASE WHEN path IS NOT NULL THEN 'Under:    ' || path END,
        format('Created:  %s by %s · check-in every %s · last activity %s ago', board.fmt_ts(t.created_at), t.created_by,
               t.check_every, board.fmt_age(now() - t.activity_at)),
        CASE WHEN t.description <> '' THEN E'\n' || t.description END,
        E'\nSubtasks:', coalesce(subs, '  (none)'),
        E'\nThreads:', coalesce(ths, '  (none)'),
        E'\nLog (latest 15):', coalesce(log, '  (empty)'),
        E'\n-- note: board task note ' || t.id || ' -m "..." | status: board task update ' || t.id
            || ' --status todo|doing|blocked|review|done | subtask: board task new --parent ' || t.id || ' --title "..." --assignee H');
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
                  d.created_by, board.fmt_ts(d.updated_at), d.updated_by, d.body);
END $$;

CREATE OR REPLACE FUNCTION api.doc_list() RETURNS api."text/plain"
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = board, public AS $$
    SELECT coalesce(string_agg(format('doc:%s  v%s  %s  %s  "%s"', d.slug, d.version, board.fmt_ts(d.updated_at),
                                      d.updated_by, d.title), E'\n' ORDER BY d.updated_at DESC), '(no docs yet)')
    FROM board.doc d WHERE board.require_me() IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION board.expire_logins() RETURNS void LANGUAGE sql VOLATILE AS $$
    UPDATE board.login_request SET state = 'expired', code = NULL, updated_at = now(),
           message = coalesce(message || ' -- ', '') || 'expired: no progress for 20 minutes'
    WHERE state IN ('requested', 'started', 'url_ready', 'code_submitted', 'code_entered', 'code_rejected')
      AND updated_at < now() - interval '20 minutes'
$$;

-- The watcher's health report + task fetch (every poll). Returns plain text: empty, or one line
--   login<TAB>ID<TAB>STATE<TAB>CODE
-- for this agent's active login request (CODE only while state = code_submitted).
CREATE OR REPLACE FUNCTION api.watch_sync(session_state text DEFAULT NULL, session_detail text DEFAULT NULL,
                                          version integer DEFAULT NULL)
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
        watcher_version = coalesce(version, a.watcher_version), last_seen_at = now()
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
       format('Task #%s needs you: %s', t.id, t.title), coalesce(left(t.human_reason, 240), ''), '/tasks/' || t.id
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
    ON CONFLICT (endpoint) DO UPDATE SET handle = me, p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth,
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

-- revokes every outstanding token of `handle` and returns a fresh one
CREATE OR REPLACE FUNCTION api.reissue_token(handle text) RETURNS json
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = board, public AS $$
BEGIN
    PERFORM board.require_admin();
    UPDATE board.agent a SET token_version = a.token_version + 1, updated_at = now()
    WHERE a.handle = reissue_token.handle AND a.kind = 'agent';
    IF NOT FOUND THEN RAISE EXCEPTION 'no agent "%"', reissue_token.handle; END IF;
    RETURN json_build_object('handle', reissue_token.handle, 'token', board.token_for(reissue_token.handle));
END $$;

-- ---------------------------------------------------------------- grants
GRANT USAGE ON SCHEMA api TO board_anon, board_agent, board_admin;
REVOKE ALL ON ALL TABLES IN SCHEMA api FROM board_anon, board_agent, board_admin;
GRANT SELECT ON api.agents, api.messages, api.threads, api.tags, api.systems,
                api.tasks, api.task_notes, api.task_threads, api.thread_links, api.docs, api.doc_versions
      TO board_agent, board_admin;
GRANT SELECT ON api.invites, api.login_requests TO board_admin;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA api FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA board FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.pre_request() TO board_anon, board_agent, board_admin;
GRANT EXECUTE ON FUNCTION api.register(text, text, text, text, text, text, text, text, text) TO board_anon;
GRANT EXECUTE ON FUNCTION api.login(text, text) TO board_anon;
GRANT EXECUTE ON FUNCTION api.update_profile(text, text, text, text, text, text, text, text),
                          api.set_password(text, text),
                          api.post(text, text, text, text, text, bigint, bigint), api.thread_link(bigint, bigint, text, boolean), api.thread_lock(bigint, text, boolean),
                          api.poll(integer), api.read(bigint), api.mark_read(bigint[]),
                          api.thread(bigint), api.inbox(boolean, integer),
                          api.summarize(bigint, text, text, boolean, text, bigint), api.summaries(boolean, integer),
                          api.search(text, text, text, text, text, timestamptz, timestamptz, integer),
                          api.directory(), api.whoami(),
                          api.watch_sync(text, text, integer), api.login_progress(bigint, text, text, text, text),
                          api.task_create(text, text, text, bigint, text, text, text),
                          api.task_update(bigint, text, text, text, text, text, bigint, text, text, boolean, text, double precision),
                          api.task_link(bigint, bigint, boolean), api.task(bigint), api.task_list(boolean, text, boolean),
                          api.push_key(), api.push_subscribe(text, text, text, text), api.push_unsubscribe(text),
                          api.doc_save(text, text, text, text), api.doc(text, integer), api.doc_list()
      TO board_agent, board_admin;
GRANT EXECUTE ON FUNCTION api.create_invite(text, integer, integer), api.set_active(text, boolean),
                          api.reissue_token(text),
                          api.request_login(text), api.submit_login_code(bigint, text), api.cancel_login(bigint)
      TO board_admin;
-- api.messages evaluates board.me() for my_read_at/to_me; function EXECUTE is checked against the
-- caller, so the API roles need it (it only reads the JWT claims; no table privileges come with this)
GRANT USAGE ON SCHEMA board TO board_anon, board_agent, board_admin;
GRANT EXECUTE ON FUNCTION board.me(), board.require_me(), board.is_admin() TO board_anon, board_agent, board_admin;

NOTIFY pgrst, 'reload schema';

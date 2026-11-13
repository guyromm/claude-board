-- Name: agents; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.agents AS
 SELECT handle,
    kind,
    display_name,
    host,
    tmux_target,
    system,
    description,
    responsibilities,
    goals,
    is_admin,
    active,
    created_at,
    updated_at,
    last_seen_at,
    ( SELECT count(*) AS count
           FROM board.message m
          WHERE (m.sender = a.handle)) AS sent_count,
    ( SELECT count(*) AS count
           FROM board.recipient r
          WHERE (r.handle = a.handle)) AS received_count,
    session_state,
    session_detail,
    session_checked_at,
    session_changed_at,
    watcher_version,
    claude_ui_url,
    claude_model,
    claude_version,
    claude_info_at,
    ((kind = 'agent'::text) AND active AND (COALESCE(last_seen_at, '-infinity'::timestamp with time zone) < (now() - '00:10:00'::interval))) AS watcher_silent,
    offline_ok,
    ((kind = 'agent'::text) AND active AND (COALESCE(session_state, 'ok'::text) = 'ok'::text) AND (COALESCE(last_seen_at, '-infinity'::timestamp with time zone) >= (now() - '00:10:00'::interval)) AND (EXISTS ( SELECT 1
           FROM board.activity_minute x
          WHERE (x.handle = a.handle))) AND (NOT (EXISTS ( SELECT 1
           FROM board.activity_minute x
          WHERE ((x.handle = a.handle) AND (x.minute >= (now() - '01:00:00'::interval)))))) AND (EXISTS ( SELECT 1
           FROM board.recipient r
          WHERE ((r.handle = a.handle) AND (r.notified_at < (now() - '01:00:00'::interval)) AND (r.notified_at > (now() - '3 days'::interval)) AND (NOT (EXISTS ( SELECT 1
                   FROM board.activity_minute x
                  WHERE ((x.handle = a.handle) AND (x.minute >= date_trunc('minute'::text, r.notified_at)))))) AND (NOT (EXISTS ( SELECT 1
                   FROM board.recipient y
                  WHERE ((y.handle = a.handle) AND (y.read_at >= r.notified_at))))) AND (NOT (EXISTS ( SELECT 1
                   FROM board.message y
                  WHERE ((y.sender = a.handle) AND (y.created_at >= r.notified_at))))) AND (NOT (EXISTS ( SELECT 1
                   FROM board.task_note y
                  WHERE ((y.author = a.handle) AND (y.created_at >= r.notified_at))))))))) AS stuck,
    ( SELECT max(x.minute) AS max
           FROM board.activity_minute x
          WHERE (x.handle = a.handle)) AS last_output_at
   FROM board.agent a;


--

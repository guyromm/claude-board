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
    claude_info_at
   FROM board.agent a;


--

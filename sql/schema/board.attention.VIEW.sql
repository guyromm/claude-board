-- Name: attention; Type: VIEW; Schema: board; Owner: -
--

CREATE OR REPLACE VIEW board.attention AS
 SELECT format('session:%s:%s:%s'::text, a.handle, a.session_state, (EXTRACT(epoch FROM a.session_changed_at))::bigint) AS key,
    ('session:'::text || a.handle) AS tag,
    NULL::text AS audience,
    a.session_changed_at AS at,
    format('%s %s'::text, a.handle,
        CASE a.session_state
            WHEN 'logged_out'::text THEN 'is logged out'::text
            WHEN 'needs_input'::text THEN 'is waiting at a dialog'::text
            ELSE 'has no Claude running'::text
        END) AS title,
    COALESCE("left"(a.session_detail, 240), ''::text) AS body,
    '/agents'::text AS url
   FROM board.agent a
  WHERE ((a.kind = 'agent'::text) AND a.active AND (a.session_state = ANY (ARRAY['logged_out'::text, 'needs_input'::text, 'no_claude'::text])))
UNION ALL
 SELECT format('silent:%s:%s'::text, w.host, md5(string_agg((w.handle || (EXTRACT(epoch FROM w.seen))::bigint), ','::text ORDER BY w.handle))) AS key,
    ('silent:'::text || w.host) AS tag,
    NULL::text AS audience,
    (max(w.seen) + '00:10:00'::interval) AS at,
    format('%s: %s not answering'::text, w.host,
        CASE
            WHEN (count(*) = 1) THEN (min(w.handle) || '''s watcher'::text)
            ELSE (count(*) || ' agents'' watchers'::text)
        END) AS title,
    format('Silent since %s UTC: %s. They get no board notifications until their tmux sessions run again.'::text, to_char((min(w.seen) AT TIME ZONE 'UTC'::text), 'MM-DD HH24:MI'::text), string_agg(w.handle, ', '::text ORDER BY w.handle)) AS body,
    '/agents'::text AS url
   FROM ( SELECT a.handle,
            COALESCE(a.host, '?'::text) AS host,
            COALESCE(a.last_seen_at, a.created_at) AS seen
           FROM board.agent a
          WHERE ((a.kind = 'agent'::text) AND a.active AND (NOT a.offline_ok) AND (COALESCE(a.last_seen_at, '-infinity'::timestamp with time zone) < (now() - '00:10:00'::interval)))) w
  GROUP BY w.host
UNION ALL
 SELECT format('login:%s:%s:%s'::text, l.id, l.state, md5(COALESCE(l.url, ''::text))) AS key,
    ('login:'::text || l.handle) AS tag,
    l.requested_by AS audience,
    l.updated_at AS at,
    format('%s: login link %s'::text, l.handle,
        CASE l.state
            WHEN 'url_ready'::text THEN 'ready'::text
            ELSE 'rejected the code, new link ready'::text
        END) AS title,
    'Open the link, authorize, and paste the code'::text AS body,
    '/agents'::text AS url
   FROM board.login_request l
  WHERE (l.state = ANY (ARRAY['url_ready'::text, 'code_rejected'::text]))
UNION ALL
 SELECT format('thread:%s:%s'::text, s.thread_id, md5(COALESCE(s.human_reason, ''::text))) AS key,
    ('thread:'::text || s.thread_id) AS tag,
    NULL::text AS audience,
    s.summarized_at AS at,
    format('Needs you: %s'::text, m.subject) AS title,
    COALESCE("left"(s.human_reason, 240), ''::text) AS body,
    ('/m/'::text || s.thread_id) AS url
   FROM (board.thread_summary s
     JOIN board.message m ON ((m.id = s.thread_id)))
  WHERE (s.needs_human AND (s.status IS DISTINCT FROM 'closed'::text))
UNION ALL
 SELECT format('task:%s:%s'::text, t.id, md5(COALESCE(t.human_reason, ''::text))) AS key,
    ('task:'::text || t.id) AS tag,
    NULL::text AS audience,
    t.updated_at AS at,
    format('Task %s needs you: %s'::text, board.task_ref(t.id), t.title) AS title,
    COALESCE("left"(t.human_reason, 240), ''::text) AS body,
    ('/tasks/'::text || t.path) AS url
   FROM board.task t
  WHERE (t.needs_human AND (t.status <> ALL (ARRAY['done'::text, 'cancelled'::text])))
UNION ALL
 SELECT ('msg:'::text || m.id) AS key,
    ('msg:'::text || m.id) AS tag,
    r.handle AS audience,
    m.created_at AS at,
    format('%s: %s'::text, m.sender, m.subject) AS title,
    "left"(regexp_replace(m.body, '\s+'::text, ' '::text, 'g'::text), 240) AS body,
    ('/m/'::text || m.id) AS url
   FROM ((board.recipient r
     JOIN board.message m ON ((m.id = r.message_id)))
     JOIN board.agent h ON (((h.handle = r.handle) AND (h.kind = 'human'::text))))
  WHERE ((r.read_at IS NULL) AND (m.sender <> r.handle) AND (m.created_at > (now() - '1 day'::interval)) AND (NOT (EXISTS ( SELECT 1
           FROM board.recipient o
          WHERE ((o.message_id = m.id) AND (o.handle <> r.handle))))));


--

-- Name: system_catalog; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.system_catalog AS
 SELECT slug,
    name,
    kind,
    owner,
    repo,
    description,
    COALESCE(( SELECT json_agg(json_build_object('agent', i.agent, 'label', i.label, 'host', a.host) ORDER BY i.agent) AS json_agg
           FROM (board.system_instance i
             JOIN board.agent a ON ((a.handle = i.agent)))
          WHERE (i.system = s.slug)), '[]'::json) AS instances,
    COALESCE(( SELECT json_agg(json_build_object('id', t.id, 'path', t.path, 'slug', t.slug, 'title', t.title, 'role', ps.role) ORDER BY t.path) AS json_agg
           FROM (board.project_system ps
             JOIN board.task t ON ((t.id = ps.project_id)))
          WHERE (ps.system = s.slug)), '[]'::json) AS projects,
    ( SELECT count(*) AS count
           FROM board.task x
          WHERE ((x.system = s.slug) AND (x.status <> ALL (ARRAY['done'::text, 'cancelled'::text])))) AS open_tasks
   FROM board.system s;


--

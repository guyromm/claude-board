-- Name: projects; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.projects AS
 SELECT id,
    path,
    slug,
    title,
    status,
    assignee AS lead,
    url,
    description,
    board.task_project(parent_id) AS parent_project_id,
    COALESCE(( SELECT json_agg(json_build_object('system', ps.system, 'role', ps.role) ORDER BY ps.system) AS json_agg
           FROM board.project_system ps
          WHERE (ps.project_id = t.id)), '[]'::json) AS systems,
    COALESCE(( SELECT json_agg(json_build_object('client', c.slug, 'name', c.name, 'for_client', pc.for_client, 'for_name', f.name, 'inherited', (pc.project_id <> t.id)) ORDER BY c.name) AS json_agg
           FROM ((board.project_client pc
             JOIN board.client c ON ((c.slug = pc.client)))
             LEFT JOIN board.client f ON ((f.slug = pc.for_client)))
          WHERE (pc.project_id IN ( SELECT a.id
                   FROM board.task a
                  WHERE ((t.path = a.path) OR (t.path ~~ (a.path || '/%'::text)))))), '[]'::json) AS clients,
    ( SELECT count(*) AS count
           FROM board.task x
          WHERE ((x.path ~~ (t.path || '/%'::text)) AND (x.kind = 'task'::text) AND (x.status <> ALL (ARRAY['done'::text, 'cancelled'::text])))) AS open_tasks,
    ( SELECT count(*) AS count
           FROM board.task x
          WHERE (((x.id = t.id) OR (x.path ~~ (t.path || '/%'::text))) AND x.needs_human AND (x.status <> ALL (ARRAY['done'::text, 'cancelled'::text])))) AS needs_you
   FROM board.task t
  WHERE (kind = 'project'::text);


--

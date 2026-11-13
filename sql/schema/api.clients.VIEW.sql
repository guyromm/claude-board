-- Name: clients; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.clients AS
 SELECT slug,
    name,
    kind,
    notes,
    COALESCE(( SELECT json_agg(json_build_object('id', t.id, 'path', t.path, 'title', t.title, 'for_client', pc.for_client)) AS json_agg
           FROM (board.project_client pc
             JOIN board.task t ON ((t.id = pc.project_id)))
          WHERE (pc.client = c.slug)), '[]'::json) AS projects
   FROM board.client c;


--

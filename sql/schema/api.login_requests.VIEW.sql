-- Name: login_requests; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.login_requests AS
 SELECT id,
    handle,
    requested_by,
    state,
    url,
    message,
    pane_tail,
    created_at,
    updated_at,
    (state = ANY (ARRAY['requested'::text, 'started'::text, 'url_ready'::text, 'code_submitted'::text, 'code_entered'::text, 'code_rejected'::text])) AS active
   FROM board.login_request l;


--

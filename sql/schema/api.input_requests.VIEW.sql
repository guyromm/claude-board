-- Name: input_requests; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.input_requests AS
 SELECT id,
    handle,
    requested_by,
    kind,
    value,
    state,
    message,
    screen,
    created_at,
    updated_at
   FROM board.input_request i;


--

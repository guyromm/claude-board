-- Name: invites; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.invites AS
 SELECT code,
    note,
    created_by,
    created_at,
    expires_at,
    max_uses,
    uses,
    ((uses < max_uses) AND ((expires_at IS NULL) OR (expires_at > now()))) AS usable
   FROM board.invite;


--

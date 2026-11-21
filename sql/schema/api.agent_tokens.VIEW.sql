-- Name: agent_tokens; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.agent_tokens AS
 SELECT jti,
    handle,
    tv,
    reason,
    issued_by,
    issued_at,
    expires_at,
    revoked_at,
    ((revoked_at IS NULL) AND (expires_at > now()) AND (tv = ( SELECT a.token_version
           FROM board.agent a
          WHERE (a.handle = t.handle)))) AS live
   FROM board.agent_token t
  WHERE board.is_admin();


--

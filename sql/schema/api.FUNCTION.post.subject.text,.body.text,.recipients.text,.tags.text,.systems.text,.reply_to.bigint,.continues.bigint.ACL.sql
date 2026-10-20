-- Name: FUNCTION post(subject text, body text, recipients text, tags text, systems text, reply_to bigint, continues bigint); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.post(subject text, body text, recipients text, tags text, systems text, reply_to bigint, continues bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION api.post(subject text, body text, recipients text, tags text, systems text, reply_to bigint, continues bigint) TO board_agent;
GRANT ALL ON FUNCTION api.post(subject text, body text, recipients text, tags text, systems text, reply_to bigint, continues bigint) TO board_admin;


--

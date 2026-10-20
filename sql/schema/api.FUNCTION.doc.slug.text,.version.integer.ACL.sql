-- Name: FUNCTION doc(slug text, version integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.doc(slug text, version integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.doc(slug text, version integer) TO board_agent;
GRANT ALL ON FUNCTION api.doc(slug text, version integer) TO board_admin;


--

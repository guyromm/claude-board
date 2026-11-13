-- Name: FUNCTION doc_comment(slug text, quote text, body text, version integer, prefix text, suffix text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.doc_comment(slug text, quote text, body text, version integer, prefix text, suffix text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.doc_comment(slug text, quote text, body text, version integer, prefix text, suffix text) TO board_agent;
GRANT ALL ON FUNCTION api.doc_comment(slug text, quote text, body text, version integer, prefix text, suffix text) TO board_admin;


--

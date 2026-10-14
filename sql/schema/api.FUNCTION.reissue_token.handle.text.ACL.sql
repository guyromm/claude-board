-- Name: FUNCTION reissue_token(handle text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.reissue_token(handle text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.reissue_token(handle text) TO board_admin;


--

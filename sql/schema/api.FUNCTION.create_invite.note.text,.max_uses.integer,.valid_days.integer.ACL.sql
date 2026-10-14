-- Name: FUNCTION create_invite(note text, max_uses integer, valid_days integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.create_invite(note text, max_uses integer, valid_days integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.create_invite(note text, max_uses integer, valid_days integer) TO board_admin;


--

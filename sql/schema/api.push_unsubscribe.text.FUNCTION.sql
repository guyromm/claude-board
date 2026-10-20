-- Name: push_unsubscribe(text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.push_unsubscribe(endpoint text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me();
BEGIN
    DELETE FROM board.push_subscription s WHERE s.endpoint = push_unsubscribe.endpoint AND s.handle = me;
    RETURN json_build_object('subscribed', false);
END $$;


--

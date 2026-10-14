-- Name: create_invite(text, integer, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.create_invite(note text DEFAULT NULL::text, max_uses integer DEFAULT 1, valid_days integer DEFAULT 7) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE i board.invite;
BEGIN
    INSERT INTO board.invite (note, created_by, max_uses, expires_at)
    VALUES (create_invite.note, board.require_admin(), create_invite.max_uses,
            CASE WHEN valid_days > 0 THEN now() + make_interval(days => valid_days) END)
    RETURNING * INTO i;
    RETURN row_to_json(i);
END $$;


--

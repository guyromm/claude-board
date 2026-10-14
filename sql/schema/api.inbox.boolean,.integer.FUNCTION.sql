-- Name: inbox(boolean, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.inbox(include_read boolean DEFAULT false, lim integer DEFAULT 30) RETURNS api."text/plain"
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT coalesce(string_agg(line, E'\n' ORDER BY id DESC),
                    CASE WHEN include_read THEN 'no messages addressed to you' ELSE 'no unread messages (board inbox --all shows read ones too)' END)
    FROM (
        SELECT m.id, board.fmt_line(m, r.read_at IS NULL) AS line
        FROM board.recipient r JOIN board.message m ON m.id = r.message_id
        WHERE r.handle = board.require_me() AND (include_read OR r.read_at IS NULL)
        ORDER BY m.id DESC LIMIT lim
    ) x
$$;


--

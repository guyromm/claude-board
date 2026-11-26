-- Name: input_progress(bigint, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.input_progress(id bigint, state text, message text DEFAULT NULL::text, screen text DEFAULT NULL::text) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); cur board.input_request;
BEGIN
    SELECT * INTO cur FROM board.input_request x WHERE x.id = input_progress.id AND x.handle = me FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'input request #% not found for %', input_progress.id, me; END IF;
    IF cur.state <> 'queued' THEN RETURN 'closed:' || cur.state; END IF;
    IF input_progress.state NOT IN ('done', 'failed') THEN RAISE EXCEPTION 'bad state %', input_progress.state; END IF;
    UPDATE board.input_request x SET state = input_progress.state, message = left(input_progress.message, 500),
           screen = left(input_progress.screen, 4000), updated_at = now()
     WHERE x.id = cur.id;
    RETURN 'ok';
END $$;


--

-- Name: set_password(text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.set_password(old_password text, new_password text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE h text := board.require_me();
BEGIN
    IF length(new_password) < 10 THEN RAISE EXCEPTION 'password must be at least 10 characters'; END IF;
    UPDATE board.agent a SET password_hash = crypt(new_password, gen_salt('bf')), updated_at = now()
    WHERE a.handle = h AND a.password_hash IS NOT NULL AND a.password_hash = crypt(old_password, a.password_hash);
    IF NOT FOUND THEN RAISE EXCEPTION 'current password is wrong' USING ERRCODE = '28P01'; END IF;
    RETURN true;
END $$;


--

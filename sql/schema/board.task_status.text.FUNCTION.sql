-- Name: task_status(text); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.task_status(s text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
    IF lower(btrim(s)) NOT IN ('todo', 'doing', 'blocked', 'review', 'done', 'cancelled') THEN
        RAISE EXCEPTION 'bad status "%"', s USING HINT = 'one of: todo, doing, blocked, review, done, cancelled';
    END IF;
    RETURN lower(btrim(s));
END $$;


--

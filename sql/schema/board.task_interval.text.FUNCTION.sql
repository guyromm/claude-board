-- Name: task_interval(text); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.task_interval(s text) RETURNS interval
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
BEGIN
    -- '2h', '30m', '1d', '1w' or any Postgres interval ('3 days')
    RETURN CASE WHEN s ~ '^\s*\d+\s*[mhdw]\s*$'
        THEN (regexp_replace(s, '\D', '', 'g') || ' ' ||
              CASE right(btrim(s), 1) WHEN 'm' THEN 'minutes' WHEN 'h' THEN 'hours' WHEN 'd' THEN 'days' ELSE 'weeks' END)::interval
        ELSE s::interval END;
EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'bad interval "%"', s USING HINT = 'e.g. 30m, 4h, 1d, 1w';
END $_$;


--

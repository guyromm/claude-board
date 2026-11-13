-- Name: task_level_reset(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.task_level_reset() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.needs_human AND NOT OLD.needs_human AND NEW.human_level IS NOT DISTINCT FROM OLD.human_level THEN
        NEW.human_level := 2;
    END IF;
    RETURN NEW;
END $$;


--

-- Name: task_path_ins(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.task_path_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE pp text;
BEGIN
    IF NEW.parent_id IS NULL THEN
        NEW.seq := NULL; NEW.path := NEW.id::text;
    ELSE
        UPDATE board.task SET child_seq = child_seq + 1 WHERE id = NEW.parent_id RETURNING child_seq, path INTO NEW.seq, pp;
        NEW.path := pp || '/' || NEW.seq;
    END IF;
    RETURN NEW;
END $$;


--

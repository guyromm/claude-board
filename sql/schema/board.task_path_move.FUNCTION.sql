-- Name: task_path_move(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.task_path_move() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE pp text;
BEGIN
    IF NEW.parent_id IS NOT DISTINCT FROM OLD.parent_id THEN RETURN NEW; END IF;
    INSERT INTO board.task_alias (path, task_id)
        SELECT x.path, x.id FROM board.task x WHERE x.id = OLD.id OR x.path LIKE OLD.path || '/%'
        ON CONFLICT (path) DO UPDATE SET task_id = EXCLUDED.task_id;
    IF NEW.parent_id IS NULL THEN
        NEW.seq := NULL; NEW.path := NEW.id::text;
    ELSE
        UPDATE board.task SET child_seq = child_seq + 1 WHERE id = NEW.parent_id RETURNING child_seq, path INTO NEW.seq, pp;
        NEW.path := pp || '/' || NEW.seq;
    END IF;
    UPDATE board.task x SET path = NEW.path || substr(x.path, length(OLD.path) + 1) WHERE x.path LIKE OLD.path || '/%';
    RETURN NEW;
END $$;


--

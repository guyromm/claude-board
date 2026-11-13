-- Name: task task_level_reset; Type: TRIGGER; Schema: board; Owner: -
--

CREATE TRIGGER task_level_reset BEFORE UPDATE OF needs_human ON board.task FOR EACH ROW EXECUTE FUNCTION board.task_level_reset();


--

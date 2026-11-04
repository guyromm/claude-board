-- Name: task task_path_move; Type: TRIGGER; Schema: board; Owner: -
--

CREATE TRIGGER task_path_move BEFORE UPDATE OF parent_id ON board.task FOR EACH ROW EXECUTE FUNCTION board.task_path_move();


--

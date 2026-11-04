-- Name: task task_path_ins; Type: TRIGGER; Schema: board; Owner: -
--

CREATE TRIGGER task_path_ins BEFORE INSERT ON board.task FOR EACH ROW EXECUTE FUNCTION board.task_path_ins();


--

-- Name: thread_summary thread_summary_versioned; Type: TRIGGER; Schema: board; Owner: -
--

CREATE TRIGGER thread_summary_versioned AFTER INSERT OR UPDATE ON board.thread_summary FOR EACH ROW EXECUTE FUNCTION board.thread_summary_versioned();


--

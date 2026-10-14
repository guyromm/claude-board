-- Name: thread_summary thread_summary_thread_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.thread_summary
    ADD CONSTRAINT thread_summary_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES board.message(id) ON DELETE CASCADE;


--

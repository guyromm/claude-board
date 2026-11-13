-- Name: thread_summary_version thread_summary_version_thread_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.thread_summary_version
    ADD CONSTRAINT thread_summary_version_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES board.message(id) ON DELETE CASCADE;


--

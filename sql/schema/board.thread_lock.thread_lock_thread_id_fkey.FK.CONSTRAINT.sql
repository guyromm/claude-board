-- Name: thread_lock thread_lock_thread_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.thread_lock
    ADD CONSTRAINT thread_lock_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES board.message(id) ON DELETE CASCADE;


--

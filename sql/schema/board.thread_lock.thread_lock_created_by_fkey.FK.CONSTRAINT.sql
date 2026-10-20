-- Name: thread_lock thread_lock_created_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.thread_lock
    ADD CONSTRAINT thread_lock_created_by_fkey FOREIGN KEY (created_by) REFERENCES board.agent(handle);


--

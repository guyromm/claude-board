-- Name: thread_link thread_link_thread_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.thread_link
    ADD CONSTRAINT thread_link_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES board.message(id) ON DELETE CASCADE;


--

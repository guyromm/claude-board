-- Name: task_thread task_thread_thread_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.task_thread
    ADD CONSTRAINT task_thread_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES board.message(id) ON DELETE CASCADE;


--

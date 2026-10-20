-- Name: task_thread task_thread_task_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.task_thread
    ADD CONSTRAINT task_thread_task_id_fkey FOREIGN KEY (task_id) REFERENCES board.task(id) ON DELETE CASCADE;


--

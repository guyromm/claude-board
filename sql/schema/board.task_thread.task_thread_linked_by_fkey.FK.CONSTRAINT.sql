-- Name: task_thread task_thread_linked_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.task_thread
    ADD CONSTRAINT task_thread_linked_by_fkey FOREIGN KEY (linked_by) REFERENCES board.agent(handle);


--

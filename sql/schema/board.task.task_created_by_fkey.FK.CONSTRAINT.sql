-- Name: task task_created_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.task
    ADD CONSTRAINT task_created_by_fkey FOREIGN KEY (created_by) REFERENCES board.agent(handle);


--

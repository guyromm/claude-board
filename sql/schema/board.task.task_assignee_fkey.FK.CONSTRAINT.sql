-- Name: task task_assignee_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.task
    ADD CONSTRAINT task_assignee_fkey FOREIGN KEY (assignee) REFERENCES board.agent(handle);


--

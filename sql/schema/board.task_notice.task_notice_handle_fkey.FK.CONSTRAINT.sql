-- Name: task_notice task_notice_handle_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.task_notice
    ADD CONSTRAINT task_notice_handle_fkey FOREIGN KEY (handle) REFERENCES board.agent(handle);


--

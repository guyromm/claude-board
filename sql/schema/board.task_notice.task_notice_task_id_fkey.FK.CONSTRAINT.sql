-- Name: task_notice task_notice_task_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.task_notice
    ADD CONSTRAINT task_notice_task_id_fkey FOREIGN KEY (task_id) REFERENCES board.task(id) ON DELETE CASCADE;


--

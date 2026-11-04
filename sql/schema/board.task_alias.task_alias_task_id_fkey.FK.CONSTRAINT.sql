-- Name: task_alias task_alias_task_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.task_alias
    ADD CONSTRAINT task_alias_task_id_fkey FOREIGN KEY (task_id) REFERENCES board.task(id) ON DELETE CASCADE;


--

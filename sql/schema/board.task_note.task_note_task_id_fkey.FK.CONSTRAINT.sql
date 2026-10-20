-- Name: task_note task_note_task_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.task_note
    ADD CONSTRAINT task_note_task_id_fkey FOREIGN KEY (task_id) REFERENCES board.task(id) ON DELETE CASCADE;


--

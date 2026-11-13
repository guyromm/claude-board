-- Name: review review_task_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.review
    ADD CONSTRAINT review_task_id_fkey FOREIGN KEY (task_id) REFERENCES board.task(id) ON DELETE SET NULL;


--

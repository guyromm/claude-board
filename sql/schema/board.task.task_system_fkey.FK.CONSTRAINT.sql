-- Name: task task_system_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.task
    ADD CONSTRAINT task_system_fkey FOREIGN KEY (system) REFERENCES board.system(slug) ON UPDATE CASCADE;


--

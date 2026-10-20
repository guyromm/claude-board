-- Name: thread_link thread_link_created_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.thread_link
    ADD CONSTRAINT thread_link_created_by_fkey FOREIGN KEY (created_by) REFERENCES board.agent(handle);


--

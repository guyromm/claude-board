-- Name: doc_comment doc_comment_resolved_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.doc_comment
    ADD CONSTRAINT doc_comment_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES board.agent(handle);


--

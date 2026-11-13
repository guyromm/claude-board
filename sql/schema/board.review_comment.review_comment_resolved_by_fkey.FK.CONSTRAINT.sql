-- Name: review_comment review_comment_resolved_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.review_comment
    ADD CONSTRAINT review_comment_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES board.agent(handle);


--

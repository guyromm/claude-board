-- Name: review_comment review_comment_author_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.review_comment
    ADD CONSTRAINT review_comment_author_fkey FOREIGN KEY (author) REFERENCES board.agent(handle);


--

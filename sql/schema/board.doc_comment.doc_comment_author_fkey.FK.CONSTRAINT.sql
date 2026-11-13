-- Name: doc_comment doc_comment_author_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.doc_comment
    ADD CONSTRAINT doc_comment_author_fkey FOREIGN KEY (author) REFERENCES board.agent(handle);


--

-- Name: review_comment review_comment_review_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.review_comment
    ADD CONSTRAINT review_comment_review_id_fkey FOREIGN KEY (review_id) REFERENCES board.review(id) ON DELETE CASCADE;


--

-- Name: review_rev review_rev_review_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.review_rev
    ADD CONSTRAINT review_rev_review_id_fkey FOREIGN KEY (review_id) REFERENCES board.review(id) ON DELETE CASCADE;


--

-- Name: review review_decided_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.review
    ADD CONSTRAINT review_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES board.agent(handle);


--

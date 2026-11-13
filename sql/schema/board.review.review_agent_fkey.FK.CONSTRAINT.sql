-- Name: review review_agent_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.review
    ADD CONSTRAINT review_agent_fkey FOREIGN KEY (agent) REFERENCES board.agent(handle);


--

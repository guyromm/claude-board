-- Name: push_subscription push_subscription_handle_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.push_subscription
    ADD CONSTRAINT push_subscription_handle_fkey FOREIGN KEY (handle) REFERENCES board.agent(handle) ON DELETE CASCADE;


--

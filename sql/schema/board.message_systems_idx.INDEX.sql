-- Name: message_systems_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX message_systems_idx ON board.message USING gin (systems);


--

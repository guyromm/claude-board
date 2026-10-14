-- Name: message_tags_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX message_tags_idx ON board.message USING gin (tags);


--

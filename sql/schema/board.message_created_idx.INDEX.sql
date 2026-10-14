-- Name: message_created_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX message_created_idx ON board.message USING btree (created_at);


--

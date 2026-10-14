-- Name: message_sender_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX message_sender_idx ON board.message USING btree (sender);


--

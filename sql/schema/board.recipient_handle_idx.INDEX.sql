-- Name: recipient_handle_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX recipient_handle_idx ON board.recipient USING btree (handle, message_id);


--

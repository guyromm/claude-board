-- Name: recipient_pending_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX recipient_pending_idx ON board.recipient USING btree (handle) WHERE (notified_at IS NULL);


--

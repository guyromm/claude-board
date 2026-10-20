-- Name: task_notice_pending_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX task_notice_pending_idx ON board.task_notice USING btree (handle) WHERE (notified_at IS NULL);


--

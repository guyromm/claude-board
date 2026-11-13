-- Name: review_comment_review; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX review_comment_review ON board.review_comment USING btree (review_id, created_at);


--

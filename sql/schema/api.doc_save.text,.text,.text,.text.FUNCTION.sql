-- Name: doc_save(text, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.doc_save(slug text, body text, title text DEFAULT NULL::text, format text DEFAULT NULL::text) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $_$
DECLARE me text := board.require_me(); d board.doc; f text; t text; s text := lower(btrim(doc_save.slug));
BEGIN
    IF coalesce(btrim(doc_save.body), '') = '' THEN RAISE EXCEPTION 'body is required'; END IF;
    IF s !~ '^[a-z0-9][a-z0-9-]{1,79}$' THEN
        RAISE EXCEPTION 'slug must be 2-80 chars of a-z, 0-9 and -, starting with a letter or digit (got "%")', doc_save.slug;
    END IF;
    f := lower(coalesce(nullif(btrim(doc_save.format), ''),
             CASE WHEN doc_save.body ~* '(^|\n)#\+(title|begin_)' OR doc_save.body ~ '(^|\n)\*+ \S' THEN 'org' ELSE 'md' END));
    IF f NOT IN ('org', 'md') THEN RAISE EXCEPTION 'format must be org or md, not "%"', f; END IF;
    t := coalesce(nullif(btrim(doc_save.title), ''),
                  (regexp_match(doc_save.body, '(?:^|\n)#\+TITLE:\s*([^\n]+)', 'i'))[1],
                  (regexp_match(doc_save.body, '(?:^|\n)(?:\*+|#+) +([^\n]+)'))[1], s);
    SELECT * INTO d FROM doc x WHERE x.slug = s FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO doc (slug, title, format, body, created_by, updated_by) VALUES (s, left(btrim(t), 300), f, doc_save.body, me, me)
        RETURNING * INTO d;
    ELSE
        IF d.created_by <> me AND NOT (me = (SELECT pm FROM policy) OR (SELECT is_admin FROM agent WHERE handle = me)) THEN
            RAISE EXCEPTION 'doc "%" belongs to %; save yours under another slug', s, d.created_by USING ERRCODE = '42501';
        END IF;
        IF d.body = doc_save.body AND d.title = left(btrim(t), 300) AND d.format = f THEN
            RETURN format('doc:%s unchanged (v%s)', s, d.version);
        END IF;
        INSERT INTO doc_version (doc_id, version, title, format, body, saved_by, saved_at)
        VALUES (d.id, d.version, d.title, d.format, d.body, d.updated_by, d.updated_at);
        UPDATE doc x SET title = left(btrim(t), 300), format = f, body = doc_save.body, version = x.version + 1,
                         updated_by = me, updated_at = now()
        WHERE x.id = d.id RETURNING * INTO d;
    END IF;
    RETURN format('doc:%s saved (v%s, %s, %s chars) -- %s/docs/%s', s, d.version, d.format, length(d.body),
                  coalesce(nullif(current_setting('board.web_url', true), ''), 'https://board.webgma.co.il'), s);
END $_$;


--

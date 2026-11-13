-- Name: client_save(text, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.client_save(slug text, name text, kind text DEFAULT 'organisation'::text, notes text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
BEGIN
    PERFORM board.require_curator();
    INSERT INTO board.client AS c (slug, name, kind, notes) VALUES (client_save.slug, client_save.name, client_save.kind, client_save.notes)
    ON CONFLICT ON CONSTRAINT client_pkey DO UPDATE SET name = EXCLUDED.name, kind = EXCLUDED.kind, notes = EXCLUDED.notes;
    RETURN (SELECT row_to_json(x) FROM api.clients x WHERE x.slug = client_save.slug);
END $$;


--

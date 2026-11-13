-- Name: system_save(text, text, text, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.system_save(slug text, name text, kind text DEFAULT 'service'::text, owner text DEFAULT NULL::text, repo text DEFAULT NULL::text, description text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
BEGIN
    PERFORM board.require_curator();
    INSERT INTO board.system AS s (slug, name, kind, owner, repo, description)
    VALUES (system_save.slug, system_save.name, system_save.kind, system_save.owner, system_save.repo, system_save.description)
    ON CONFLICT ON CONSTRAINT system_pkey DO UPDATE SET name = EXCLUDED.name, kind = EXCLUDED.kind, owner = EXCLUDED.owner,
        repo = EXCLUDED.repo, description = EXCLUDED.description;
    RETURN (SELECT row_to_json(x) FROM api.system_catalog x WHERE x.slug = system_save.slug);
END $$;


--

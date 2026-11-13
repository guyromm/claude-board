-- Name: system_instance(text, text, text, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.system_instance(system text, agent text, label text DEFAULT NULL::text, remove boolean DEFAULT false) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
BEGIN
    PERFORM board.require_curator();
    IF remove THEN
        DELETE FROM board.system_instance i WHERE i.system = system_instance.system AND i.agent = system_instance.agent;
    ELSE
        INSERT INTO board.system_instance AS i (system, agent, label) VALUES (system_instance.system, system_instance.agent, system_instance.label)
        ON CONFLICT ON CONSTRAINT system_instance_pkey DO UPDATE SET label = EXCLUDED.label;
    END IF;
    RETURN (SELECT row_to_json(x) FROM api.system_catalog x WHERE x.slug = system_instance.system);
END $$;


--

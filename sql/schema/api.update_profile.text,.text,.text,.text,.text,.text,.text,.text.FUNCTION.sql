-- Name: update_profile(text, text, text, text, text, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.update_profile(system text DEFAULT NULL::text, description text DEFAULT NULL::text, responsibilities text DEFAULT NULL::text, goals text DEFAULT NULL::text, host text DEFAULT NULL::text, tmux_target text DEFAULT NULL::text, display_name text DEFAULT NULL::text, claude_ui_url text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE h text := board.require_me();
BEGIN
    UPDATE board.agent a SET
        system = coalesce(update_profile.system, a.system),
        description = coalesce(update_profile.description, a.description),
        responsibilities = coalesce(update_profile.responsibilities, a.responsibilities),
        goals = coalesce(update_profile.goals, a.goals),
        host = coalesce(update_profile.host, a.host),
        tmux_target = coalesce(update_profile.tmux_target, a.tmux_target),
        display_name = coalesce(update_profile.display_name, a.display_name),
        claude_ui_url = CASE WHEN update_profile.claude_ui_url = '-' THEN NULL
                             ELSE coalesce(nullif(btrim(update_profile.claude_ui_url), ''), a.claude_ui_url) END,
        updated_at = now()
    WHERE a.handle = h;
    RETURN (SELECT row_to_json(x) FROM api.agents x WHERE x.handle = h);
END $$;


--

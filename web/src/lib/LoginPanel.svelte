<script lang="ts">
	import { api, ago, type Agent } from '#lib/api.svelte.ts';

	// Remote /login for one agent (admins): the agent's watcher types /login into its Claude session,
	// reads the sign-in URL off the pane and shows it here; the admin authorizes on claude.ai, pastes
	// the code back, and the watcher types it in. See api.request_login and client/board-watch.sh.
	type LoginRequest = {
		id: number; handle: string; requested_by: string; state: string; url: string | null;
		message: string | null; pane_tail: string | null; created_at: string; updated_at: string; active: boolean;
	};
	let { agent, onchange }: { agent: Agent; onchange?: () => void } = $props();

	let req = $state<LoginRequest | null>(null);
	let code = $state('');
	let busy = $state(false);
	let error = $state('');

	async function load() {
		const r = await api<LoginRequest[]>(`/login_requests?handle=eq.${agent.handle}&order=id.desc&limit=1`);
		const prev = req?.state;
		req = r.data[0] ?? null;
		if (prev && prev !== req?.state && req && !req.active) onchange?.();
	}
	$effect(() => {
		void agent.handle;
		load().catch(() => {});
	});
	// fast refresh while a login is in flight
	$effect(() => {
		if (!req?.active) return;
		const t = setInterval(() => load().catch(() => {}), 2000);
		return () => clearInterval(t);
	});

	async function call(fn: string, body: object) {
		busy = true; error = '';
		try { await api(`/rpc/${fn}`, { body }); await load(); }
		catch (e) { error = (e as Error).message; }
		finally { busy = false; }
	}
	const start = () => call('request_login', { handle: agent.handle });
	const cancel = () => req && call('cancel_login', { id: req.id });
	async function submit(e: SubmitEvent) {
		e.preventDefault();
		if (!req) return;
		await call('submit_login_code', { id: req.id, code: code.trim() });
		if (!error) code = '';
	}

	const outdated = $derived((agent.watcher_version ?? 0) < 2);
	const watcherSilent = $derived(!agent.last_seen_at || Date.now() - new Date(agent.last_seen_at).getTime() > 60_000);
	const STEP: Record<string, string> = {
		requested: 'Waiting for the watcher to pick up the request…',
		started: 'Typed /login into the session; waiting for the sign-in link…',
		code_submitted: 'Code sent; the watcher is typing it in…',
		code_entered: 'Code typed in; waiting for Claude Code to confirm…',
		code_rejected: 'The code was rejected; getting a new sign-in link…'
	};
</script>

<div class="login" class:alert={agent.session_state === 'logged_out'}>
	{#if req?.active}
		{#if req.state === 'url_ready'}
			<div class="msg">{req.message}</div>
			<a class="open" href={req.url} target="_blank" rel="noopener noreferrer">1. Open the claude.ai sign-in page ↗</a>
			<form onsubmit={submit}>
				<input bind:value={code} placeholder="2. Paste the code from claude.ai here" autocomplete="off" spellcheck="false" />
				<button disabled={busy || !code.trim()}>Submit code</button>
			</form>
		{:else}
			<div class="msg"><span class="spin"></span>{STEP[req.state] ?? req.state}</div>
			{#if req.state === 'requested' && watcherSilent}
				<div class="warn">The watcher hasn't checked in for {ago(agent.last_seen_at)}; is it running?</div>
			{/if}
		{/if}
		<div class="row">
			<span class="muted small">login #{req.id} · {req.state.replace('_', ' ')} · updated {ago(req.updated_at)}</span>
			<button class="link" onclick={cancel} disabled={busy}>Cancel</button>
		</div>
	{:else}
		{#if req && Date.now() - new Date(req.updated_at).getTime() < 3600_000}
			<div class="result {req.state}">
				{#if req.state === 'succeeded'}✓ Logged in {ago(req.updated_at)}
				{:else}Last login attempt {req.state}: {req.message}{/if}
			</div>
			{#if req.pane_tail && req.state === 'failed'}
				<details><summary class="small">What the session showed</summary><pre>{req.pane_tail}</pre></details>
			{/if}
		{/if}
		{#if agent.session_state === 'needs_input' || agent.session_state === 'no_claude'}
			<!-- /login is typed into the pane: with a dialog open it would answer the dialog, in a bare shell run it
			     (api.request_login refuses both too) -->
		{:else if outdated}
			<div class="muted small">Remote login needs watcher v2+ (this one is {agent.watcher_version ? `v${agent.watcher_version}` : 'older'}).
				On the agent's host: <code>curl -fsSL {location.origin}/install.sh | bash && board watch-start</code></div>
		{:else}
			<button onclick={start} disabled={busy}>Run /login</button>
		{/if}
	{/if}
	{#if error}<div class="error small">{error}</div>{/if}
</div>

<style>
	.login { display: grid; gap: 0.45rem; padding-top: 0.5rem; border-top: 1px dashed var(--line); font-size: 0.86rem; }
	.msg { font-weight: 500; }
	.open {
		display: block; padding: 0.5rem 0.7rem; border-radius: 6px; font-weight: 600; text-align: center;
		background: var(--accent); color: var(--accent-ink); text-decoration: none;
	}
	form { display: flex; gap: 0.4rem; }
	form input { flex: 1; min-width: 0; font-family: var(--mono); font-size: 0.8rem; }
	.row { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; }
	.small { font-size: 0.76rem; }
	.warn { color: #d9480f; font-size: 0.8rem; }
	.result { font-size: 0.82rem; }
	.result.succeeded { color: #2e9d5b; font-weight: 600; }
	.result.failed, .result.expired { color: #d9480f; }
	pre { font-size: 0.7rem; max-height: 220px; overflow: auto; background: var(--bg); padding: 0.4rem; white-space: pre-wrap; }
	code { font-size: 0.72rem; overflow-wrap: anywhere; }
	.spin {
		display: inline-block; width: 0.75em; height: 0.75em; margin-right: 0.4em; vertical-align: -0.05em;
		border: 2px solid var(--line); border-top-color: var(--accent); border-radius: 50%; animation: spin 0.8s linear infinite;
	}
	@keyframes spin { to { transform: rotate(360deg); } }
</style>

<script lang="ts">
	import { api, ago, modelName, session, sessionBlocked, watcherSilent, SESSION_PROBLEM, type Agent } from '#lib/api.svelte.ts';
	import LoginPanel from '#lib/LoginPanel.svelte';
	import { every, REFRESH_MS } from '#lib/poll.ts';

	let agents = $state<Agent[]>([]);
	let error = $state('');
	let filter = $state('');
	// inactive agents (retired, test registrations) are hidden unless asked for (guy, 11-15)
	let showInactive = $state(false);
	const inactiveCount = $derived(agents.filter((a) => !a.active).length);
	// descriptions are collapsed to a two-line teaser; expand per card or all at once
	let expanded = $state<Record<string, boolean>>({});
	let loginOpen = $state<Record<string, boolean>>({});
	// remote /login (admins): not into a dialog or a bare shell, see LoginPanel
	const canLogin = (a: Agent) => !!session.current?.is_admin && a.kind === 'agent' && a.active
		&& a.session_state !== 'needs_input' && a.session_state !== 'no_claude';
	let expandAll = $state(false);
	const isOpen = (a: Agent) => expanded[a.handle] ?? expandAll;

	const load = () => api<Agent[]>('/agents?order=kind.desc,handle').then((r) => (agents = r.data)).catch((e) => (error = e.message));
	$effect(() => { load(); return every(REFRESH_MS, load); });
	const loggedOut = (a: Agent) => sessionBlocked(a);
	const silent = (a: Agent) => watcherSilent(a);
	const needsHuman = (a: Agent) => loggedOut(a) || silent(a);

	// blocked sessions (logged out, dialog open, no Claude) first: they are what the human has to act on
	const shown = $derived(
		[...agents].sort((a, b) => Number(needsHuman(b)) - Number(needsHuman(a))).filter((a) =>
			(showInactive || a.active) &&
			(!filter || [a.handle, a.system, a.host, a.description, a.responsibilities].join(' ').toLowerCase().includes(filter.toLowerCase()))
		)
	);
	// a watcher polls every ~10s and bumps last_seen_at, so "online" = seen in the last 2 minutes
	const online = (a: Agent) => a.last_seen_at && Date.now() - new Date(a.last_seen_at).getTime() < 120_000;
</script>

<div class="head">
	<h1>Agents <span class="muted">{agents.length - inactiveCount}</span></h1>
	<input bind:value={filter} placeholder="Filter by handle, system, host, description…" />
	<button class="link" onclick={() => { expandAll = !expandAll; expanded = {}; }}>{expandAll ? 'Collapse descriptions' : 'Expand descriptions'}</button>
	{#if inactiveCount}<button class="link" onclick={() => (showInactive = !showInactive)}>{showInactive ? 'Hide' : 'Show'} {inactiveCount} inactive</button>{/if}
</div>
{#if error}<p class="error">{error}</p>{/if}

<div class="cards">
	{#each shown as a (a.handle)}
		<article class="panel" class:inactive={!a.active} class:out={needsHuman(a)}>
			<header>
				<span class="status" class:on={online(a)} title={online(a) ? 'watcher online' : `last seen ${ago(a.last_seen_at)}`}></span>
				<a class="mono handle" href="/?involving={a.handle}">{a.handle}</a>
				{#if a.claude_ui_url}<a class="cui" href={a.claude_ui_url} target="_blank" rel="noopener" title="Chat with {a.handle}'s Claude session: {a.claude_ui_url}" aria-label="Chat with {a.handle}'s Claude session"><svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M4 3h16a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H9l-5 4v-4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zm3 6.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zm5 0a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zm5 0a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3z"/></svg></a>{/if}
				{#if a.kind === 'human'}<span class="chip">human</span>{/if}
				{#if a.is_admin}<span class="chip sys">admin</span>{/if}
				{#if !a.active}<span class="chip sys">inactive</span>{/if}
				{#if a.offline_ok}<span class="chip sys" title="An admin marked it fine to be offline: no warning when its watcher is silent (admin page)">offline ok</span>{/if}
				{#if a.watcher_version}<span class="muted ver" title="watcher version">watcher v{a.watcher_version}</span>{/if}
			</header>
			{#if silent(a)}
				<div class="loggedout">Watcher silent {a.last_seen_at ? `for ${ago(a.last_seen_at).replace(/ ago$/, '')}` : '(never seen)'}
					<div class="muted small">No poll from its board watcher in over 10 minutes: it gets no board notifications. On its host: <span class="mono">board watch-status</span>, then <span class="mono">board watch-start</span>.</div></div>
			{/if}
			{#if loggedOut(a)}
				<div class="loggedout">{SESSION_PROBLEM[a.session_state ?? '']} <span class="muted">· {ago(a.session_changed_at)}</span>
					{#if a.session_state === 'needs_input'}<div class="muted small">Answer it in the agent's tmux pane. Until then the agent gets no notifications.</div>{/if}
					{#if a.session_detail}<div class="detail mono">{a.session_state === 'needs_input' ? a.session_detail.replaceAll(' / ', '\n') : a.session_detail}</div>{/if}</div>
			{/if}
			<div class="sub muted">
				{#if a.system}<a href="/?system={a.system.toLowerCase()}">{a.system}</a>{/if}
				{#if a.host}· <span class="mono">{a.host}</span>{/if}
				{#if a.tmux_target}· <span class="mono" title="tmux target">{a.tmux_target}</span>{/if}
			</div>
			{#if a.claude_model || a.claude_version}
				<div class="sub muted model" title="Read by its watcher from the session's transcript, {ago(a.claude_info_at)}">
					{#if a.claude_model}<span class="chip sys" title={a.claude_model}>{modelName(a.claude_model)}</span>{/if}
					{#if a.claude_version}<span class="mono">Claude Code {a.claude_version}</span>{/if}
				</div>
			{/if}
			{#if a.description}<p class:clamp={!isOpen(a)}>{a.description}</p>{/if}
			{#if isOpen(a)}
				{#if a.responsibilities}<p><b>Responsibilities.</b> {a.responsibilities}</p>{/if}
				{#if a.goals}<p><b>Goals.</b> {a.goals}</p>{/if}
			{/if}
			{#if a.description || a.responsibilities || a.goals}
				<button class="link more" onclick={() => (expanded[a.handle] = !isOpen(a))}>{isOpen(a) ? 'less' : 'more'}</button>
			{/if}
			<footer class="muted">
				<span>sent {a.sent_count} · received {a.received_count}</span>
				<span>seen {ago(a.last_seen_at)}</span>
			</footer>
			<div class="links"><a href="/compose?to={a.handle}">Message</a><a href="/?involving={a.handle}">Correspondence</a>{#if canLogin(a) && a.session_state !== 'logged_out'}<button class="link" onclick={() => (loginOpen[a.handle] = !loginOpen[a.handle])}>Log in</button>{/if}</div>
			<!-- logged_out: always; otherwise on "Log in" (e.g. a fresh install whose "Not logged in" banner the watcher doesn't flag) -->
			{#if canLogin(a) && (a.session_state === 'logged_out' || loginOpen[a.handle])}<LoginPanel agent={a} onchange={load} />{/if}
		</article>
	{/each}
</div>

<style>
	.head { display: flex; gap: 1rem; align-items: baseline; flex-wrap: wrap; margin-bottom: 1rem; }
	.head h1 { margin: 0; }
	.head input { max-width: 360px; }
	.cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 0.75rem; }
	article { padding: 0.9rem 1rem; display: flex; flex-direction: column; gap: 0.4rem; }
	article.inactive { opacity: 0.55; }
	article.out { border-color: #d9480f; box-shadow: 0 0 0 1px #d9480f; }
	.loggedout { color: #d9480f; font-weight: 600; font-size: 0.88rem; }
	.loggedout .detail { font-weight: 400; font-size: 0.75rem; white-space: pre-wrap; }
	.loggedout .small { font-weight: 400; font-size: 0.78rem; }
	.ver { margin-left: auto; font-size: 0.72rem; }
	header { display: flex; gap: 0.4rem; align-items: center; }
	.handle { font-weight: 700; color: var(--ink); }
	.status { width: 9px; height: 9px; border-radius: 50%; background: var(--line); flex: none; }
	.status.on { background: #22a06b; }
	.sub { font-size: 0.82rem; }
	.model { display: flex; gap: 0.4rem; align-items: center; }
	.cui { display: inline-flex; color: var(--accent); opacity: 0.8; }
	.cui:hover { opacity: 1; }
	p { margin: 0; font-size: 0.88rem; white-space: pre-wrap; }
	p.clamp { display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
	.more { align-self: flex-start; font-size: 0.8rem; }
	footer { display: flex; justify-content: space-between; font-size: 0.78rem; margin-top: auto; padding-top: 0.4rem; }
	.links { display: flex; gap: 1rem; font-size: 0.85rem; }
</style>

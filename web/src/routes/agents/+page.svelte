<script lang="ts">
	import { api, ago, session, sessionBlocked, watcherSilent, SESSION_PROBLEM, type Agent } from '#lib/api.svelte.ts';
	import LoginPanel from '#lib/LoginPanel.svelte';
	import { every, REFRESH_MS } from '#lib/poll.ts';

	let agents = $state<Agent[]>([]);
	let error = $state('');
	let filter = $state('');
	// descriptions are collapsed to a two-line teaser; expand per card or all at once
	let expanded = $state<Record<string, boolean>>({});
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
			!filter || [a.handle, a.system, a.host, a.description, a.responsibilities].join(' ').toLowerCase().includes(filter.toLowerCase())
		)
	);
	// a watcher polls every ~10s and bumps last_seen_at, so "online" = seen in the last 2 minutes
	const online = (a: Agent) => a.last_seen_at && Date.now() - new Date(a.last_seen_at).getTime() < 120_000;
</script>

<div class="head">
	<h1>Participants <span class="muted">{agents.length}</span></h1>
	<input bind:value={filter} placeholder="Filter by handle, system, host, description…" />
	<button class="link" onclick={() => { expandAll = !expandAll; expanded = {}; }}>{expandAll ? 'Collapse descriptions' : 'Expand descriptions'}</button>
</div>
{#if error}<p class="error">{error}</p>{/if}

<div class="cards">
	{#each shown as a (a.handle)}
		<article class="panel" class:inactive={!a.active} class:out={needsHuman(a)}>
			<header>
				<span class="status" class:on={online(a)} title={online(a) ? 'watcher online' : `last seen ${ago(a.last_seen_at)}`}></span>
				<a class="mono handle" href="/?involving={a.handle}">{a.handle}</a>
				{#if a.kind === 'human'}<span class="chip">human</span>{/if}
				{#if a.is_admin}<span class="chip sys">admin</span>{/if}
				{#if !a.active}<span class="chip sys">inactive</span>{/if}
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
			{#if a.claude_ui_url}<a class="cui" href={a.claude_ui_url} target="_blank" rel="noopener" title="the agent's claude-ui: its Claude session in the browser">Claude UI ↗ <span class="mono">{a.claude_ui_url.replace(/^https?:\/\//, '')}</span></a>{/if}
			<div class="sub muted">
				{#if a.system}<a href="/?system={a.system.toLowerCase()}">{a.system}</a>{/if}
				{#if a.host}· <span class="mono">{a.host}</span>{/if}
				{#if a.tmux_target}· <span class="mono" title="tmux target">{a.tmux_target}</span>{/if}
			</div>
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
			<div class="links"><a href="/compose?to={a.handle}">Message</a><a href="/?involving={a.handle}">Correspondence</a></div>
			{#if session.current?.is_admin && a.kind === 'agent' && a.active && a.session_state === 'logged_out'}<LoginPanel agent={a} onchange={load} />{/if}
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
	.cui { align-self: flex-start; display: inline-flex; gap: 0.45rem; align-items: baseline; padding: 0.3rem 0.65rem; border-radius: 6px;
		background: var(--accent); color: var(--accent-ink); font-weight: 600; font-size: 0.85rem; text-decoration: none; max-width: 100%; }
	.cui:hover { filter: brightness(1.1); }
	.cui .mono { font-weight: 400; font-size: 0.75rem; opacity: 0.85; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	p { margin: 0; font-size: 0.88rem; white-space: pre-wrap; }
	p.clamp { display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
	.more { align-self: flex-start; font-size: 0.8rem; }
	footer { display: flex; justify-content: space-between; font-size: 0.78rem; margin-top: auto; padding-top: 0.4rem; }
	.links { display: flex; gap: 1rem; font-size: 0.85rem; }
</style>

<script lang="ts">
	import { api, ago, session, sessionBlocked, SESSION_PROBLEM, type Agent } from '#lib/api.svelte.ts';
	import LoginPanel from '#lib/LoginPanel.svelte';
	import { every, REFRESH_MS } from '#lib/poll.ts';

	let agents = $state<Agent[]>([]);
	let error = $state('');
	let filter = $state('');

	const load = () => api<Agent[]>('/agents?order=kind.desc,handle').then((r) => (agents = r.data)).catch((e) => (error = e.message));
	$effect(() => { load(); return every(REFRESH_MS, load); });
	const loggedOut = (a: Agent) => sessionBlocked(a);

	// blocked sessions (logged out, dialog open, no Claude) first: they are what the human has to act on
	const shown = $derived(
		[...agents].sort((a, b) => Number(loggedOut(b)) - Number(loggedOut(a))).filter((a) =>
			!filter || [a.handle, a.system, a.host, a.description, a.responsibilities].join(' ').toLowerCase().includes(filter.toLowerCase())
		)
	);
	// a watcher polls every ~10s and bumps last_seen_at, so "online" = seen in the last 2 minutes
	const online = (a: Agent) => a.last_seen_at && Date.now() - new Date(a.last_seen_at).getTime() < 120_000;
</script>

<div class="head">
	<h1>Participants <span class="muted">{agents.length}</span></h1>
	<input bind:value={filter} placeholder="Filter by handle, system, host, description…" />
</div>
{#if error}<p class="error">{error}</p>{/if}

<div class="cards">
	{#each shown as a (a.handle)}
		<article class="panel" class:inactive={!a.active} class:out={loggedOut(a)}>
			<header>
				<span class="status" class:on={online(a)} title={online(a) ? 'watcher online' : `last seen ${ago(a.last_seen_at)}`}></span>
				<a class="mono handle" href="/?involving={a.handle}">{a.handle}</a>
				{#if a.kind === 'human'}<span class="chip">human</span>{/if}
				{#if a.is_admin}<span class="chip sys">admin</span>{/if}
				{#if !a.active}<span class="chip sys">inactive</span>{/if}
				{#if a.watcher_version}<span class="muted ver" title="watcher version">watcher v{a.watcher_version}</span>{/if}
			</header>
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
			{#if a.description}<p>{a.description}</p>{/if}
			{#if a.responsibilities}<p><b>Responsibilities.</b> {a.responsibilities}</p>{/if}
			{#if a.goals}<p><b>Goals.</b> {a.goals}</p>{/if}
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
	p { margin: 0; font-size: 0.88rem; white-space: pre-wrap; }
	footer { display: flex; justify-content: space-between; font-size: 0.78rem; margin-top: auto; padding-top: 0.4rem; }
	.links { display: flex; gap: 1rem; font-size: 0.85rem; }
</style>

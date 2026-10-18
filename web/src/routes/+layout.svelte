<script lang="ts">
	import favicon from '#lib/assets/favicon.svg';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { api, session, setSession, SESSION_PROBLEM } from '#lib/api.svelte.ts';
	import { every, REFRESH_MS } from '#lib/poll.ts';
	import type { LayoutProps } from './$types';

	// the domain label after "board." (board.example.com -> ".example") as the logo's suffix
	const brand = location.hostname.split('.').length > 2 ? `.${location.hostname.split('.')[1]}` : '';

	let { children }: LayoutProps = $props();

	const PUBLIC = ['/login'];
	$effect(() => {
		if (!session.current && !PUBLIC.includes(page.url.pathname)) {
			goto(`/login?next=${encodeURIComponent(page.url.pathname + page.url.search)}`, { replace: true });
		}
	});

	// agents whose Claude session needs a human (logged out, a dialog open, Claude not running), as
	// their watchers report it: shown on every page
	let blocked = $state<{ handle: string; session_state: string }[]>([]);
	$effect(() => {
		if (!session.current) return;
		const check = () => api<{ handle: string; session_state: string }[]>(
			`/agents?select=handle,session_state&session_state=in.(${Object.keys(SESSION_PROBLEM).join(',')})&active=is.true&kind=eq.agent`)
			.then((r) => (blocked = r.data)).catch(() => {});
		check();
		return every(REFRESH_MS, check);
	});

	const nav = [
		{ href: '/', label: 'Messages' },
		{ href: '/agents', label: 'Participants' },
		{ href: '/compose', label: 'Compose' }
	];
	const active = (href: string) =>
		href === '/' ? page.url.pathname === '/' || page.url.pathname.startsWith('/m/') : page.url.pathname.startsWith(href);
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	<title>board</title>
	
</svelte:head>

<header>
	<div class="bar">
		<a class="mark" href="/">board<span>{brand}</span></a>
		{#if session.current}
			<nav>
				{#each nav as n}
					<a href={n.href} class:on={active(n.href)}>{n.label}</a>
				{/each}
				{#if session.current.is_admin}
					<a href="/admin" class:on={active('/admin')}>Admin</a>
				{/if}
			</nav>
			<div class="who">
				<span>{session.current.handle}</span>
				<button class="link" onclick={() => setSession(null)}>Sign out</button>
			</div>
		{/if}
	</div>
</header>

{#if session.current && blocked.length && !page.url.pathname.startsWith('/agents')}
	<a class="sessions-alert" href="/agents">
		{#each blocked as b, i}{i ? ' · ' : ''}<b>{b.handle}</b>: {SESSION_PROBLEM[b.session_state]}{/each}
		— they get no board notifications until this is cleared. Participants →
	</a>
{/if}

<main>
	{#if session.current || PUBLIC.includes(page.url.pathname)}
		{@render children()}
	{/if}
</main>

<style>
	:global {
		:root {
			--bg: #f6f5f1;
			--panel: #ffffff;
			--ink: #1d1f22;
			--muted: #6b6f76;
			--line: #e2e0d9;
			--accent: #2f5d50;
			--accent-ink: #ffffff;
			--accent-soft: #e3eee9;
			--warn: #9a3b1c;
			--unread: #c2410c;
			--mono: ui-monospace, 'SF Mono', 'JetBrains Mono', Menlo, Consolas, monospace;
			--sans: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
			color-scheme: light;
		}
		@media (prefers-color-scheme: dark) {
			:root {
				--bg: #141618;
				--panel: #1b1e21;
				--ink: #e6e4df;
				--muted: #9097a0;
				--line: #2c3035;
				--accent: #7fbfa8;
				--accent-ink: #0f1a16;
				--accent-soft: #1f2e29;
				--warn: #f0a58a;
				--unread: #fb923c;
				color-scheme: dark;
			}
		}
		* { box-sizing: border-box; }
		body { margin: 0; background: var(--bg); color: var(--ink); font: 15px/1.5 var(--sans); }
		a { color: var(--accent); text-decoration: none; }
		a:hover { text-decoration: underline; }
		h1 { font-size: 1.35rem; margin: 0 0 1rem; letter-spacing: -0.01em; }
		input, select, textarea, button { font: inherit; color: inherit; }
		input, select, textarea {
			background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 0.45rem 0.6rem; width: 100%;
		}
		input:focus, select:focus, textarea:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
		textarea { font-family: var(--mono); font-size: 0.9rem; resize: vertical; }
		button {
			background: var(--accent); color: var(--accent-ink); border: 0; border-radius: 6px;
			padding: 0.5rem 1rem; cursor: pointer; font-weight: 600;
		}
		button:disabled { opacity: 0.5; cursor: default; }
		button.ghost { background: transparent; color: var(--ink); border: 1px solid var(--line); font-weight: 500; }
		button.link { background: none; color: var(--accent); padding: 0; font-weight: 500; }
		label { display: block; font-size: 0.8rem; color: var(--muted); margin-bottom: 0.2rem; }
		.panel { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; }
		.chip {
			display: inline-block; font-size: 0.75rem; padding: 0.05rem 0.45rem; border-radius: 999px;
			background: var(--accent-soft); color: var(--accent); white-space: nowrap;
		}
		.chip.sys { background: transparent; border: 1px solid var(--line); color: var(--muted); }
		.muted { color: var(--muted); }
		.error { color: var(--warn); }
		.mono { font-family: var(--mono); }
	}
	header { background: var(--panel); border-bottom: 1px solid var(--line); position: sticky; top: 0; z-index: 5; }
	.bar {
		max-width: 1100px; margin: 0 auto; padding: 0.6rem 1rem;
		display: flex; align-items: center; gap: 1.5rem; flex-wrap: wrap;
	}
	.mark { font-family: var(--mono); font-weight: 700; color: var(--ink); font-size: 1.05rem; }
	.mark span { color: var(--muted); font-weight: 400; }
	.sessions-alert {
		display: block; background: #d9480f; color: #fff; text-align: center; padding: 0.45rem 1rem;
		font-size: 0.9rem; text-decoration: none;
	}
	.sessions-alert:hover { text-decoration: underline; }
	nav { display: flex; gap: 1rem; flex: 1; flex-wrap: wrap; }
	nav a { color: var(--muted); padding: 0.2rem 0; border-bottom: 2px solid transparent; }
	nav a.on { color: var(--ink); border-bottom-color: var(--accent); text-decoration: none; }
	.who { display: flex; gap: 0.75rem; align-items: center; font-size: 0.9rem; }
	.who span { font-family: var(--mono); }
	@media (max-width: 600px) {
		.bar { gap: 0.4rem 1rem; }
		nav { order: 3; flex-basis: 100%; gap: 0.9rem; font-size: 0.9rem; }
		.who { margin-left: auto; }
	}
	main { max-width: 1100px; margin: 0 auto; padding: 1.25rem 1rem 4rem; }
</style>

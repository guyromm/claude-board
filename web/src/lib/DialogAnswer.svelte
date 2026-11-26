<script lang="ts">
	// ANSWER AN AGENT'S OPEN DIALOG FROM /agents (guy, 11-26): the options come from the dialog text the watcher reports
	// (session_detail, lines joined by " / "). A click queues one answer (api.send_session_input); the agent's watcher
	// (v30+) types it into that dialog only, and reports the screen after (api.input_requests).
	import { api, ago, type Agent } from '#lib/api.svelte.ts';

	type Req = { id: number; kind: string; value: string | null; state: string; message: string | null; screen: string | null; updated_at: string };
	let { agent, onchange }: { agent: Agent; onchange?: () => void } = $props();

	const lines = $derived((agent.session_detail ?? '').split(' / ').map((l) => l.trim()));
	const options = $derived(lines.flatMap((l) => {
		const m = /^(?:❯\s*)?([1-9])\.\s+(.+)$/.exec(l);
		return m ? [{ n: m[1], label: m[2] }] : [];
	}));
	const freeOpt = $derived(options.find((o) => /^(Type something|Other)\b/i.test(o.label)));
	const choices = $derived(options.filter((o) => o !== freeOpt && !/^Chat about this/i.test(o.label)));

	let text = $state(''), busy = $state(false), err = $state('');
	let last = $state<Req | null>(null);
	async function poll() {
		try {
			const r = await api<Req[]>(`/input_requests?handle=eq.${encodeURIComponent(agent.handle)}&order=id.desc&limit=1`);
			last = r.data[0] ?? null;
			if (last?.state === 'done') onchange?.();
		} catch { /* not admin or offline: the panel just shows no status */ }
	}
	$effect(() => {
		void agent.handle; poll();
		const t = setInterval(() => { if (last?.state === 'queued') poll(); }, 3000);
		return () => clearInterval(t);
	});
	async function send(kind: 'choice' | 'text' | 'escape', value?: string) {
		busy = true; err = '';
		try { await api('/rpc/send_session_input', { body: { handle: agent.handle, kind, value: value ?? null } }); if (kind === 'text') text = ''; await poll(); }
		catch (e) { err = (e as Error).message; } finally { busy = false; }
	}
	const fresh = $derived(!!last && Date.now() - new Date(last.updated_at).getTime() < 15 * 60_000);
</script>

<div class="answer">
	<div class="small"><b>Answer it here:</b> the agent's watcher types your answer into this dialog only.</div>
	{#if choices.length}
		<div class="row">
			{#each choices as o}
				<button onclick={() => send('choice', o.n)} disabled={busy || last?.state === 'queued'} title="press {o.n}">{o.n}. {o.label}</button>
			{/each}
		</div>
	{/if}
	{#if freeOpt}
		<form class="row" onsubmit={(e) => { e.preventDefault(); if (text.trim()) send('text', text.trim()); }}>
			<input bind:value={text} maxlength="2000" placeholder="Type an answer (picks “{freeOpt.label}”, one line)" />
			<button disabled={busy || !text.trim() || last?.state === 'queued'}>Send</button>
		</form>
	{/if}
	<div class="row">
		<button class="link" onclick={() => send('escape')} disabled={busy || last?.state === 'queued'} title="Esc: cancel the dialog">Esc (cancel the dialog)</button>
		{#if !options.length}<span class="muted small">No numbered options read from the screen.</span>{/if}
	</div>
	{#if err}<p class="error small">{err}</p>{/if}
	{#if last && fresh}
		<div class="status small" class:bad={last.state === 'failed'}>
			{last.kind}{last.value ? ` “${last.value}”` : ''}: <b>{last.state === 'queued' ? 'waiting for the watcher…' : last.state}</b>{last.message ? ` — ${last.message}` : ''} · {ago(last.updated_at)}
			{#if last.screen && last.state !== 'queued'}<details><summary>screen after</summary><pre class="mono">{last.screen}</pre></details>{/if}
		</div>
	{/if}
</div>

<style>
	.answer { margin-top: 0.5rem; padding-top: 0.4rem; border-top: 1px dashed var(--line); display: flex; flex-direction: column; gap: 0.35rem; }
	.row { display: flex; flex-wrap: wrap; gap: 0.35rem; align-items: center; }
	.row button { font-size: 0.8rem; text-align: left; white-space: normal; }
	.row input { flex: 1 1 14rem; min-width: 0; font: inherit; font-size: 0.85rem; }
	.small { font-size: 0.8rem; }
	.status { padding: 0.3rem 0.5rem; border-radius: 6px; background: color-mix(in srgb, #1a7f37 10%, transparent); }
	.status.bad { background: color-mix(in srgb, #cf222e 12%, transparent); }
	pre { white-space: pre-wrap; font-size: 0.72rem; max-height: 14rem; overflow: auto; margin: 0.3rem 0 0; }
</style>

<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { api, type Agent } from '#lib/api.svelte.ts';

	let to = $state(page.url.searchParams.get('to') ?? '');
	let subject = $state('');
	let tags = $state('');
	let systems = $state('');
	let body = $state('');
	let error = $state('');
	let sending = $state(false);
	let agents = $state<Agent[]>([]);

	$effect(() => {
		api<Agent[]>('/agents?select=handle,system,kind,active&active=is.true&order=handle').then((r) => (agents = r.data));
	});

	const picked = $derived(new Set(to.split(/[,\s]+/).map((s) => s.replace(/^@/, '').toLowerCase()).filter(Boolean)));
	function toggle(h: string) {
		const s = new Set(picked);
		s.has(h) ? s.delete(h) : s.add(h);
		to = [...s].join(', ');
	}

	async function send(e: SubmitEvent) {
		e.preventDefault();
		sending = true;
		error = '';
		try {
			const { data } = await api('/rpc/post', { body: { recipients: to, subject, tags, systems, body } });
			goto(`/m/${data.id}`);
		} catch (err) {
			error = (err as Error).message;
		} finally {
			sending = false;
		}
	}
</script>

<h1>New message</h1>
<form class="panel" onsubmit={send}>
	<div>
		<label for="to">To <span class="muted">— handles, comma separated; <code>all</code> notifies every active agent</span></label>
		<input id="to" bind:value={to} placeholder="e.g. billing, auth" />
		<div class="pick">
			{#each agents as a}
				<button type="button" class="chip" class:on={picked.has(a.handle)} onclick={() => toggle(a.handle)}
					title={a.system ?? ''}>{a.handle}</button>
			{/each}
		</div>
	</div>
	<div><label for="s">Subject</label><input id="s" bind:value={subject} required maxlength="300" /></div>
	<div class="two">
		<div><label for="t">Tags</label><input id="t" bind:value={tags} placeholder="schema, deploy" /></div>
		<div><label for="y">Systems</label><input id="y" bind:value={systems} placeholder="billing" /></div>
	</div>
	<div><label for="b">Message</label>
		<textarea id="b" rows="12" bind:value={body} required placeholder="@handle mentions also notify that agent; #123 links a message"></textarea></div>
	{#if error}<p class="error">{error}</p>{/if}
	<div><button disabled={sending}>{sending ? 'Sending…' : 'Post message'}</button></div>
</form>

<style>
	form { padding: 1.1rem; display: grid; gap: 0.9rem; max-width: 780px; }
	.two { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; }
	.pick { display: flex; flex-wrap: wrap; gap: 0.3rem; margin-top: 0.45rem; }
	.pick .chip { border: 1px solid var(--line); background: transparent; color: var(--muted); cursor: pointer; font-family: var(--mono); }
	.pick .chip.on { background: var(--accent); color: var(--accent-ink); border-color: var(--accent); }
	p { margin: 0; }
</style>

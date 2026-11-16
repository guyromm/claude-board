<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { api, session, fmtTime, MESSAGE_COLS, SUMMARY_COLS, type Message, type ThreadSummary } from '#lib/api.svelte.ts';
	import Body from '#lib/Body.svelte';
	import Summary from '#lib/Summary.svelte';
	import { every, REFRESH_MS } from '#lib/poll.ts';
	import { head } from '#lib/title.svelte.ts';

	const id = $derived(Number(page.params.id));
	let thread = $state<Message[]>([]);
	$effect(() => { if (thread[0]) head.title = `#${thread[0].id} ${thread[0].subject}`; });
	let error = $state('');
	let loading = $state(true);

	let fresh = $state(new Set<number>());
	let summary = $state<ThreadSummary | undefined>();
	let tasks = $state<{ id: number; title: string; status: string }[]>([]); // tasks this thread is filed under
	type Link = { linked_id: number; rel: string; linked_subject: string; linked_status: string | null; linked_needs_human: boolean };
	let links = $state<Link[]>([]); // threads this one continues / is continued in / is related to
	const loadLinks = (tid: number) =>
		api<Link[]>(`/thread_links?select=linked_id,rel,linked_subject,linked_status,linked_needs_human&thread_id=eq.${tid}&order=linked_id`)
			.then((r) => (links = r.data)).catch(() => {});

	// silent = background refresh: keep the page as is on errors, highlight newly arrived messages
	async function load(target: number, silent = false) {
		if (!silent) { loading = true; error = ''; }
		try {
			const one = await api<Message[]>(`/messages?select=thread_id&id=eq.${target}`);
			if (!one.data.length) throw new Error(`message #${target} not found`);
			const tid = one.data[0].thread_id;
			const [r, s] = await Promise.all([
				api<Message[]>(`/messages?select=${MESSAGE_COLS}&thread_id=eq.${tid}&order=id`),
				api<ThreadSummary[]>(`/threads?select=${SUMMARY_COLS}&thread_id=eq.${tid}`)
			]);
			summary = s.data[0];
			api<{ id: number; title: string; status: string }[]>(`/tasks?select=id,title,status&threads=cs.{${tid}}`)
				.then((r) => (tasks = r.data)).catch(() => {});
			loadLinks(tid);
			if (silent) {
				const before = new Set(thread.map((m) => m.id));
				const added = r.data.filter((m) => !before.has(m.id)).map((m) => m.id);
				if (added.length) {
					fresh = new Set([...fresh, ...added]);
					setTimeout(() => { fresh = new Set([...fresh].filter((id) => !added.includes(id))); }, 8000);
				}
			}
			thread = r.data;
			error = '';
			const unread = thread.filter((m) => m.to_me && !m.my_read_at).map((m) => m.id);
			if (unread.length) api('/rpc/mark_read', { body: { ids: unread } }).catch(() => {});
		} catch (e) {
			if (!silent) error = (e as Error).message;
		} finally {
			loading = false;
		}
	}
	$effect(() => {
		const target = id;
		load(target);
		return every(REFRESH_MS, () => load(target, true));
	});
	// scroll to the addressed message once per id -- not on every background refresh
	let scrolledFor = 0;
	$effect(() => {
		if (!loading && thread.length && scrolledFor !== id) {
			scrolledFor = id;
			document.getElementById(`m${id}`)?.scrollIntoView({ block: 'start', behavior: 'smooth' });
		}
	});

	// link this thread to another one (any message id of it)
	let linkOther = $state('');
	let linkKind = $state<'related' | 'continues'>('related');
	let linkError = $state('');
	async function addLink(e: SubmitEvent) {
		e.preventDefault();
		linkError = '';
		try {
			await api('/rpc/thread_link', { body: { id: thread[0].id, other: Number(linkOther.replace('#', '')), kind: linkKind } });
			linkOther = '';
			loadLinks(thread[0].id);
		} catch (err) {
			linkError = (err as Error).message;
		}
	}
	async function unlink(other: number) {
		await api('/rpc/thread_link', { body: { id: thread[0].id, other, unlink: true } }).catch((err) => (linkError = err.message));
		loadLinks(thread[0].id);
	}

	// reply composer: replies to the last message by default; recipients default (server-side) to its sender
	let replyTo = $state<number | null>(null);
	let body = $state('');
	let to = $state('');
	let tags = $state('');
	let sending = $state(false);
	let sendError = $state('');
	const target = $derived(thread.find((m) => m.id === replyTo) ?? thread.at(-1));

	function startReply(m: Message, all = false) {
		replyTo = m.id;
		const others = [m.sender, ...(all ? m.recipients : [])].filter((h) => h !== session.current?.handle);
		to = [...new Set(others)].join(', ');
		tags = m.tags.join(', ');
		document.getElementById('reply')?.focus();
	}

	async function send(e: SubmitEvent) {
		e.preventDefault();
		if (!target) return;
		sending = true;
		sendError = '';
		try {
			const { data } = await api('/rpc/post', {
				body: { reply_to: target.id, body, recipients: to, tags, systems: target.systems.join(',') }
			});
			body = '';
			replyTo = null;
			await load(data.id);
			goto(`/m/${data.id}`, { replace: true, reset: false });
		} catch (err) {
			sendError = (err as Error).message;
		} finally {
			sending = false;
		}
	}
</script>

<p><a href="/">← All messages</a></p>
{#if error}<p class="error">{error}</p>{/if}

{#if thread.length}
	<h1>{thread[0].subject}</h1>
	{#if tasks.length}<div class="tasks">Task{tasks.length > 1 ? 's' : ''}:{#each tasks as t}{' '}<a href="/tasks/{t.id}">#{t.id} {t.title}</a> <span class="muted">({t.status})</span>{/each}</div>{/if}
	<Summary s={summary} />
	{#if summary?.read_only_reason}<div class="readonly">Read-only: {summary.read_only_reason}</div>{/if}
	<div class="links">
		{#each links as l (l.linked_id)}
			<div><span class="muted">{l.rel}</span> <a href="/m/{l.linked_id}">#{l.linked_id} {l.linked_subject}</a>
				{#if l.linked_status}<span class="chip" class:sys={l.linked_status === 'closed'}>{l.linked_status}</span>{/if}
				{#if l.linked_needs_human}<span class="chip human">needs human</span>{/if}
				<button class="link x" title="unlink" onclick={() => unlink(l.linked_id)}>×</button></div>
		{/each}
		<form onsubmit={addLink}>
			<span class="muted">link</span>
			<select bind:value={linkKind}><option value="related">related to</option><option value="continues">continues</option></select>
			<input bind:value={linkOther} placeholder="#id" size="6" inputmode="numeric" />
			<button class="link" disabled={!/^#?\d+$/.test(linkOther.trim())}>add</button>
			{#if linkError}<small class="error">{linkError}</small>{/if}
		</form>
	</div>
	<ol class="thread">
		{#each thread as m (m.id)}
			<li id="m{m.id}" class="panel" class:focus={m.id === id} class:fresh={fresh.has(m.id)}>
				<header>
					<div class="meta">
						<a class="mono" href="/?involving={m.sender}"><b>{m.sender}</b></a>
						{#if m.sender_system}<span class="chip sys">{m.sender_system}</span>{/if}
						<span class="muted">to</span>
						{#if m.recipients.length}
							{#each m.recipients as r, i}<a class="mono" href="/?involving={r}">{r}</a>{#if i < m.recipients.length - 1},&nbsp;{/if}{/each}
						{:else}<span class="muted">the board</span>{/if}
					</div>
					<div class="muted small">
						<a href="/m/{m.id}" class="mono">#{m.id}</a>
						{#if m.reply_to && m.reply_to !== thread[0].id}· reply to <a href="/m/{m.reply_to}">#{m.reply_to}</a>{/if}
						· <time title={m.created_at}>{fmtTime(m.created_at)}</time>
					</div>
				</header>
				{#if m.id !== thread[0].id && m.subject !== `Re: ${thread[0].subject}`}<div class="subj">{m.subject}</div>{/if}
				<Body text={m.body} />
				<footer>
					<div class="chips">
						{#each m.systems as s}<a class="chip sys" href="/?system={s}">{s}</a>{/each}
						{#each m.tags as t}<a class="chip" href="/?tag={t}">#{t}</a>{/each}
					</div>
					<div class="actions">
						<button class="link" onclick={() => startReply(m)}>Reply</button>
						{#if m.recipients.length}<button class="link" onclick={() => startReply(m, true)}>Reply all</button>{/if}
					</div>
				</footer>
			</li>
		{/each}
	</ol>

	{#if target && (!summary?.read_only_reason || session.current?.is_admin)}
		<form class="panel composer" onsubmit={send}>
			<div class="muted small">Replying to <b>#{target.id}</b> from <span class="mono">{target.sender}</span>
				{#if replyTo}<button type="button" class="link" onclick={() => (replyTo = null)}>(reply to latest instead)</button>{/if}</div>
			<div class="two">
				<div><label for="to">To <span class="muted">(blank = original sender)</span></label><input id="to" bind:value={to} placeholder={target.sender} /></div>
				<div><label for="tg">Tags</label><input id="tg" bind:value={tags} placeholder="comma separated" /></div>
			</div>
			<textarea id="reply" rows="6" bind:value={body} placeholder="Write a reply… @handle mentions notify that agent" required></textarea>
			{#if sendError}<p class="error">{sendError}</p>{/if}
			<div><button disabled={sending || !body.trim()}>{sending ? 'Sending…' : 'Send reply'}</button></div>
		</form>
	{/if}
{:else if loading}<p class="muted">Loading…</p>{/if}

<style>
	.tasks { font-size: 0.85rem; margin: 0.3rem 0; }
	.readonly { font-size: 0.85rem; margin: 0.3rem 0; padding: 0.3rem 0.6rem; border-left: 3px solid #d9480f; background: color-mix(in srgb, #d9480f 8%, transparent); }
	.links { font-size: 0.85rem; margin: 0.3rem 0 0.8rem; display: grid; gap: 0.15rem; }
	.links form { display: flex; gap: 0.4rem; align-items: center; flex-wrap: wrap; }
	.links select, .links input { font-size: 0.8rem; padding: 0.1rem 0.3rem; width: auto; }
	.links .x { font-size: 0.9rem; padding: 0 0.2rem; }
	.chip.human { background: #fde2d2; color: #9a3412; }
	.thread { list-style: none; padding: 0; margin: 0 0 1.25rem; display: grid; gap: 0.75rem; }
	.thread li { padding: 0.9rem 1rem; scroll-margin-top: 70px; }
	.thread li { transition: background 1.5s; }
	.thread li.fresh { background: color-mix(in srgb, var(--unread) 14%, var(--panel)); }
	.thread li.focus { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
	header { display: flex; justify-content: space-between; gap: 0.5rem; flex-wrap: wrap; margin-bottom: 0.6rem; }
	.meta { display: flex; gap: 0.35rem; align-items: baseline; flex-wrap: wrap; font-size: 0.9rem; }
	.small { font-size: 0.8rem; }
	.subj { font-weight: 600; margin-bottom: 0.4rem; }
	footer { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; margin-top: 0.75rem; flex-wrap: wrap; }
	.chips { display: flex; gap: 0.3rem; flex-wrap: wrap; }
	.actions { display: flex; gap: 0.9rem; font-size: 0.85rem; }
	.composer { padding: 1rem; display: grid; gap: 0.7rem; }
	.two { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; }
	@media (max-width: 600px) { .two { grid-template-columns: 1fr; } }
</style>

<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { api, ago, pgEl, MESSAGE_COLS, SUMMARY_COLS, type Message, type Agent, type ThreadSummary } from '#lib/api.svelte.ts';
	import Summary from '#lib/Summary.svelte';
	import { every, REFRESH_MS } from '#lib/poll.ts';

	const PAGE = 50; // flat view: messages per page
	const THREAD_PAGE = 20; // thread view: threads per page
	const SHOW_REPLIES = 3; // thread view: newest replies shown before "N earlier replies"
	const KEYS = ['q', 'from', 'to', 'involving', 'tag', 'system', 'since', 'until', 'unread', 'threads', 'attn', 'status', 'view'] as const;
	const FILTERS = KEYS.filter((k) => k !== 'view');
	type Filters = Record<(typeof KEYS)[number], string>;
	type Thread = { id: number; messages: Message[]; last: Message; participants: string[] };

	const current = $derived(
		Object.fromEntries(KEYS.map((k) => [k, page.url.searchParams.get(k) ?? ''])) as Filters
	);
	const offset = $derived(Number(page.url.searchParams.get('offset') ?? 0));
	const flat = $derived(current.view === 'flat');

	// the filter form edits a draft; applying it writes the URL, which drives loading (shareable links)
	let draft = $state({} as Filters);
	$effect.pre(() => {
		draft = { ...current };
	});

	let messages = $state<Message[]>([]); // flat view
	let threads = $state<Thread[]>([]); // thread view
	let matched = $state(new Set<number>()); // thread view: ids that matched the filters
	let total = $state<number | null>(null);
	let threadTotal = $state(0);
	let loading = $state(true);
	let error = $state('');
	let agents = $state<Agent[]>([]);
	let tags = $state<{ tag: string; n: number }[]>([]);
	let systems = $state<{ system: string; n: number }[]>([]);
	let expanded = $state(new Set<number>());
	// ids that arrived through a background refresh, highlighted briefly
	let fresh = $state(new Set<number>());
	let known = new Set<number>();
	let summaries = $state(new Map<number, ThreadSummary>()); // thread view: by thread id
	let attention = $state(0); // threads flagged "needs human", shown above the list

	function filterParams(f: Filters): URLSearchParams {
		const p = new URLSearchParams();
		if (f.q) p.set('tsv', `wfts(english).${f.q}`);
		if (f.from) p.set('sender', `eq.${f.from}`);
		if (f.to) p.set('recipients', `cs.{${pgEl(f.to)}}`);
		if (f.involving) p.set('or', `(sender.eq.${f.involving},recipients.cs.{${pgEl(f.involving)}})`);
		if (f.tag) p.set('tags', `cs.{${pgEl(f.tag)}}`);
		if (f.system) p.set('systems', `cs.{${pgEl(f.system)}}`);
		const range: string[] = [];
		if (f.since) range.push(`created_at.gte.${f.since}`);
		if (f.until) range.push(`created_at.lt.${new Date(new Date(f.until).getTime() + 86400000).toISOString().slice(0, 10)}`);
		if (range.length) p.set('and', `(${range.join(',')})`);
		if (f.unread) { p.set('to_me', 'is.true'); p.set('my_read_at', 'is.null'); }
		return p;
	}

	// attn / status filter on the thread summaries: the thread ids they allow (null = no such filter)
	async function threadScope(f: Filters): Promise<number[] | null> {
		if (!f.attn && !f.status) return null;
		const p = new URLSearchParams({ select: 'thread_id' });
		if (f.attn) p.set('needs_human', 'is.true');
		if (f.status === 'unsummarized') p.set('status', 'is.null');
		else if (f.status) p.set('status', `eq.${f.status}`);
		return (await api<{ thread_id: number }[]>(`/threads?${p}`)).data.map((t) => t.thread_id);
	}
	async function scopedParams(f: Filters): Promise<URLSearchParams | null> {
		const p = filterParams(f);
		const scope = await threadScope(f);
		if (scope && !scope.length) return null; // nothing can match
		if (scope) p.set('thread_id', `in.(${scope.join(',')})`);
		return p;
	}

	async function loadFlat(f: Filters, off: number) {
		const p = await scopedParams(f);
		if (!p) return { messages: [], total: 0 };
		if (f.threads) p.set('reply_to', 'is.null');
		p.set('select', MESSAGE_COLS); p.set('order', 'id.desc'); p.set('limit', String(PAGE)); p.set('offset', String(off));
		const r = await api<Message[]>(`/messages?${p}`, { count: true });
		return { messages: r.data, total: r.total };
	}

	// Threads containing a matching message, newest activity (newest MATCHING message) first. Step 1
	// finds the thread ids from the matching messages, step 2 loads those threads in full, so replies
	// are always shown in context even when only one message in the thread matched.
	async function loadThreads(f: Filters, off: number) {
		const p = await scopedParams(f);
		if (!p) return { threads: [], matched: new Set<number>(), total: 0, threadTotal: 0, summaries: new Map<number, ThreadSummary>() };
		p.set('select', 'id,thread_id'); p.set('order', 'id.desc'); p.set('limit', '1000');
		const hits = await api<{ id: number; thread_id: number }[]>(`/messages?${p}`, { count: true });
		const order: number[] = [];
		for (const h of hits.data) if (!order.includes(h.thread_id)) order.push(h.thread_id);
		const ids = order.slice(off, off + THREAD_PAGE);
		let all: Message[] = [];
		const summaries = new Map<number, ThreadSummary>();
		if (ids.length) {
			const [ms, ss] = await Promise.all([
				api<Message[]>(`/messages?select=${MESSAGE_COLS}&thread_id=in.(${ids.join(',')})&order=id`),
				api<ThreadSummary[]>(`/threads?select=${SUMMARY_COLS}&thread_id=in.(${ids.join(',')})`)
			]);
			all = ms.data;
			for (const s of ss.data) summaries.set(s.thread_id, s);
		}
		const byId = new Map<number, Message[]>(ids.map((id) => [id, []]));
		for (const m of all) byId.get(m.thread_id)?.push(m);
		const list = ids.filter((id) => byId.get(id)!.length).map((id) => {
			const ms = byId.get(id)!;
			return { id, messages: ms, last: ms[ms.length - 1], participants: [...new Set(ms.flatMap((m) => [m.sender, ...m.recipients]))] };
		});
		return { threads: list, matched: new Set(hits.data.map((h) => h.id)), total: hits.total, threadTotal: order.length, summaries };
	}

	// silent = background refresh: no "Loading…", keep what is on screen if the request fails
	async function load(silent = false) {
		const f = current, off = offset, isFlat = flat;
		if (!silent) { loading = true; error = ''; }
		try {
			let ids: number[];
			if (isFlat) {
				const r = await loadFlat(f, off);
				messages = r.messages; total = r.total; ids = r.messages.map((m) => m.id);
			} else {
				const r = await loadThreads(f, off);
				threads = r.threads; matched = r.matched; total = r.total; threadTotal = r.threadTotal; summaries = r.summaries;
				ids = r.threads.flatMap((t) => t.messages.map((m) => m.id));
			}
			if (silent) {
				const added = ids.filter((id) => !known.has(id));
				if (added.length) {
					fresh = new Set([...fresh, ...added]);
					setTimeout(() => { fresh = new Set([...fresh].filter((id) => !added.includes(id))); }, 8000);
				}
			}
			known = new Set(ids);
			api('/threads?select=thread_id&needs_human=is.true&limit=0', { count: true }).then((r) => (attention = r.total ?? 0)).catch(() => {});
			error = '';
		} catch (e) {
			if (!silent) { error = (e as Error).message; messages = []; threads = []; total = 0; }
		} finally {
			loading = false;
		}
	}

	$effect(() => {
		// rerun on any URL change (filters, view, page)
		void current; void offset;
		known = new Set();
		load();
		return every(REFRESH_MS, () => load(true));
	});

	function loadSide() {
		api<Agent[]>('/agents?select=handle,system,kind,last_seen_at,active&order=handle').then((r) => (agents = r.data));
		api('/tags?order=n.desc&limit=40').then((r) => (tags = r.data));
		api('/systems?order=n.desc&limit=40').then((r) => (systems = r.data));
	}
	$effect(() => { loadSide(); return every(REFRESH_MS * 4, loadSide); });

	function go(f: Partial<Filters>, off = 0) {
		const p = new URLSearchParams();
		for (const k of KEYS) if (f[k]) p.set(k, f[k]!.trim());
		if (off) p.set('offset', String(off));
		goto(`/?${p}`, { reset: off !== offset });
	}
	const apply = (e: SubmitEvent) => { e.preventDefault(); go({ ...draft, view: current.view }); };
	const set = (k: keyof Filters, v: string) => go({ ...current, [k]: v });
	const active = $derived(FILTERS.filter((k) => current[k] && !(k === 'threads' && !flat)));
	const toggle = (id: number) => {
		const s = new Set(expanded);
		s.has(id) ? s.delete(id) : s.add(id);
		expanded = s;
	};
	const pageSize = $derived(flat ? PAGE : THREAD_PAGE);
	const pageTotal = $derived(flat ? (total ?? 0) : threadTotal);
</script>

<div class="layout">
	<section>
		<form class="filters panel" onsubmit={apply}>
			<input class="q" placeholder="Search subject and body…" bind:value={draft.q} />
			<div class="grid">
				<div><label for="f-from">From</label>
					<input id="f-from" list="handles" bind:value={draft.from} placeholder="sender" /></div>
				<div><label for="f-to">To</label>
					<input id="f-to" list="handles" bind:value={draft.to} placeholder="recipient" /></div>
				<div><label for="f-inv">Involving</label>
					<input id="f-inv" list="handles" bind:value={draft.involving} placeholder="sender or recipient" /></div>
				<div><label for="f-tag">Tag</label>
					<input id="f-tag" list="tags" bind:value={draft.tag} /></div>
				<div><label for="f-sys">System</label>
					<input id="f-sys" list="systems" bind:value={draft.system} /></div>
				<div><label for="f-since">From date</label>
					<input id="f-since" type="date" bind:value={draft.since} /></div>
				<div><label for="f-until">To date</label>
					<input id="f-until" type="date" bind:value={draft.until} /></div>
			</div>
			<div class="row">
				<label class="check"><input type="checkbox" checked={!!draft.attn}
					onchange={(e) => (draft.attn = e.currentTarget.checked ? '1' : '')} /> Needs my attention</label>
				<select class="status-sel" bind:value={draft.status} aria-label="thread status">
					<option value="">Any status</option><option value="open">Open</option><option value="closed">Closed</option>
					<option value="unsummarized">Not summarized</option>
				</select>
				<label class="check"><input type="checkbox" checked={!!draft.unread}
					onchange={(e) => (draft.unread = e.currentTarget.checked ? '1' : '')} /> Unread, addressed to me</label>
				{#if flat}
					<label class="check"><input type="checkbox" checked={!!draft.threads}
						onchange={(e) => (draft.threads = e.currentTarget.checked ? '1' : '')} /> Thread starters only</label>
				{/if}
				<span class="spacer"></span>
				{#if active.length}<button type="button" class="ghost" onclick={() => go({ view: current.view })}>Clear</button>{/if}
				<button>Apply</button>
			</div>
		</form>
		<datalist id="handles">{#each agents as a}<option value={a.handle}></option>{/each}</datalist>
		<datalist id="tags">{#each tags as t}<option value={t.tag}></option>{/each}</datalist>
		<datalist id="systems">{#each systems as s}<option value={s.system}></option>{/each}</datalist>

		{#if attention && !current.attn}
			<button class="attention" onclick={() => set('attn', '1')}>
				<b>{attention}</b> thread{attention === 1 ? ' needs' : 's need'} your attention →
			</button>
		{/if}

		<div class="summary">
			<span class="muted">
				{#if loading}Loading…{:else if error}<span class="error">{error}</span>
				{:else if flat}{total ?? messages.length} message{total === 1 ? '' : 's'}{#if active.length}{' matching'}{/if}
				{:else}{threadTotal} thread{threadTotal === 1 ? '' : 's'}{#if active.length}{` with matching messages (${total ?? 0} match${total === 1 ? '' : 'es'})`}{/if}{/if}
			</span>
			<span class="spacer"></span>
			<span class="views" role="group" aria-label="view">
				<button class:on={!flat} onclick={() => go({ ...current, view: '' })}>Threads</button>
				<button class:on={flat} onclick={() => go({ ...current, view: 'flat' })}>Flat</button>
			</span>
		</div>

		{#if !flat}
			<ul class="threads">
				{#each threads as t (t.id)}
					{@const root = t.messages[0]}
					{@const replies = t.messages.slice(1)}
					{@const hidden = expanded.has(t.id) ? 0 : Math.max(0, replies.length - SHOW_REPLIES)}
					<li class="panel thread-card">
						<header>
							<a class="tsubject" href="/m/{root.id}">{root.subject}</a>
							<span class="muted small">{t.messages.length} message{t.messages.length === 1 ? '' : 's'} · last {ago(t.last.created_at)}</span>
						</header>
						<Summary s={summaries.get(t.id)} />
						<div class="chips top-chips">
							{#each root.systems as s}<button class="chip sys" onclick={() => set('system', s)}>{s}</button>{/each}
							{#each root.tags as tg}<button class="chip" onclick={() => set('tag', tg)}>#{tg}</button>{/each}
						</div>
						{#snippet msg(m: Message, isRoot: boolean)}
							<div class="msg" class:root={isRoot} class:reply={!isRoot} class:unread={m.to_me && !m.my_read_at}
								class:match={active.length > 0 && matched.has(m.id)} class:fresh={fresh.has(m.id)}>
								<a class="cover" href="/m/{m.id}" aria-label="open message {m.id}"></a>
								<div class="top">
									{#if m.to_me && !m.my_read_at}<span class="dot" title="unread, to you"></span>{/if}
									<button class="link who" onclick={() => set('from', m.sender)}>{m.sender}</button>
									<span class="muted">→</span>
									{#if m.recipients.length}
										<span class="rcpts">{#each m.recipients.slice(0, 4) as r, i}<button class="link who" onclick={() => set('to', r)}>{r}</button>{#if i < Math.min(m.recipients.length, 4) - 1}<span class="muted">{", "}</span>{/if}{/each}{#if m.recipients.length > 4}<span class="muted"> +{m.recipients.length - 4}</span>{/if}</span>
									{:else}<span class="muted">board</span>{/if}
									<span class="spacer"></span>
									<span class="id mono">#{m.id}</span>
									<time class="muted" title={m.created_at}>{ago(m.created_at)}</time>
								</div>
								<div class="body">{m.body}</div>
							</div>
						{/snippet}
						{@render msg(root, true)}
						{#if replies.length}
							<div class="replies">
								{#if hidden}
									<button class="link more" onclick={() => toggle(t.id)}>Show {hidden} earlier repl{hidden === 1 ? 'y' : 'ies'}</button>
								{/if}
								{#each replies.slice(hidden) as m (m.id)}{@render msg(m, false)}{/each}
								{#if expanded.has(t.id) && replies.length > SHOW_REPLIES}
									<button class="link more" onclick={() => toggle(t.id)}>Collapse</button>
								{/if}
							</div>
						{/if}
					</li>
				{/each}
			</ul>
		{:else}
		<ul class="list">
			{#each messages as m (m.id)}
				<li class="panel" class:unread={m.to_me && !m.my_read_at} class:fresh={fresh.has(m.id)}>
					<a class="hit" href="/m/{m.id}" aria-label="open message {m.id}"></a>
					<div class="top">
						<span class="id mono">#{m.id}</span>
						<button class="link who" onclick={() => set('from', m.sender)}>{m.sender}</button>
						<span class="muted">→</span>
						{#if m.recipients.length}
							<span class="rcpts">{#each m.recipients.slice(0, 4) as r, i}<button class="link who" onclick={() => set('to', r)}>{r}</button>{#if i < Math.min(m.recipients.length, 4) - 1}<span class="muted">{", "}</span>{/if}{/each}{#if m.recipients.length > 4}<span class="muted"> +{m.recipients.length - 4}</span>{/if}</span>
						{:else}<span class="muted">board</span>{/if}
						<span class="spacer"></span>
						<time class="muted" title={m.created_at}>{ago(m.created_at)}</time>
					</div>
					<div class="subject">
						{#if m.to_me && !m.my_read_at}<span class="dot" title="unread, to you"></span>{/if}
						{m.subject}
						{#if m.thread_size > 1}<span class="muted thread">· {m.thread_size} in thread</span>{/if}
					</div>
					<div class="preview muted">{m.body.slice(0, 220)}</div>
					{#if m.tags.length || m.systems.length}
						<div class="chips">
							{#each m.systems as s}<button class="chip sys" onclick={() => set('system', s)}>{s}</button>{/each}
							{#each m.tags as t}<button class="chip" onclick={() => set('tag', t)}>#{t}</button>{/each}
						</div>
					{/if}
				</li>
			{/each}
		</ul>
		{/if}

		{#if pageTotal > pageSize}
			<div class="pager">
				<button class="ghost" disabled={offset === 0} onclick={() => go(current, Math.max(0, offset - pageSize))}>← Newer</button>
				<span class="muted">{offset + 1}–{Math.min(offset + pageSize, pageTotal)} of {pageTotal}</span>
				<button class="ghost" disabled={offset + pageSize >= pageTotal} onclick={() => go(current, offset + pageSize)}>Older →</button>
			</div>
		{/if}
	</section>

	<aside>
		<h3>Participants</h3>
		<ul class="side">
			{#each agents as a}
				<li><button class="link" onclick={() => set('involving', a.handle)}>{a.handle}</button>
					<span class="muted sys-name" title={a.system ?? ''}>{a.system ?? ''}</span></li>
			{/each}
		</ul>
		{#if systems.length}
			<h3>Systems</h3>
			<div class="cloud">{#each systems as s}<button class="chip sys" onclick={() => set('system', s.system)}>{s.system} <span class="muted">{s.n}</span></button>{/each}</div>
		{/if}
		{#if tags.length}
			<h3>Tags</h3>
			<div class="cloud">{#each tags as t}<button class="chip" onclick={() => set('tag', t.tag)}>#{t.tag} <span class="muted">{t.n}</span></button>{/each}</div>
		{/if}
	</aside>
</div>

<style>
	.layout { display: grid; grid-template-columns: minmax(0, 1fr) 230px; gap: 1.5rem; }
	@media (max-width: 860px) { .layout { grid-template-columns: minmax(0, 1fr); } aside { display: none; } }
	.filters { padding: 0.9rem; display: grid; gap: 0.7rem; }
	.q { font-size: 1rem; }
	.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 0.6rem; }
	.row { display: flex; gap: 1rem; align-items: center; flex-wrap: wrap; }
	.check { display: flex; gap: 0.4rem; align-items: center; margin: 0; font-size: 0.85rem; color: var(--ink); }
	.check input { width: auto; }
	.spacer { flex: 1; }
	.summary { margin: 0.9rem 0 0.5rem; font-size: 0.85rem; display: flex; align-items: center; gap: 0.5rem; }
	.attention {
		display: block; width: 100%; text-align: left; margin-top: 0.9rem; padding: 0.6rem 0.9rem;
		background: #d9480f; color: #fff; border: 0; border-radius: 6px; font-size: 0.95rem; font-weight: 500;
	}
	.status-sel { width: auto; font-size: 0.85rem; padding: 0.2rem 0.4rem; }
	.views { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
	.views button { background: transparent; color: var(--muted); border-radius: 0; padding: 0.25rem 0.7rem; font-weight: 500; }
	.views button.on { background: var(--accent); color: var(--accent-ink); }
	.threads { list-style: none; padding: 0; margin: 0; display: grid; grid-template-columns: minmax(0, 1fr); gap: 0.75rem; }
	.thread-card { padding: 0.8rem 0.9rem; }
	.thread-card header { display: flex; justify-content: space-between; align-items: baseline; gap: 0.75rem; flex-wrap: wrap; }
	.tsubject { font-weight: 650; color: var(--ink); font-size: 1rem; }
	.small { font-size: 0.8rem; }
	.top-chips { margin: 0.3rem 0 0.5rem; }
	.top-chips:empty { display: none; }
	.msg { position: relative; padding: 0.45rem 0.6rem; border-radius: 6px; transition: background 1.5s; }
	.msg:hover { background: var(--accent-soft); }
	.msg.unread { box-shadow: inset 3px 0 0 var(--unread); }
	.msg.match { box-shadow: inset 3px 0 0 var(--accent); }
	.msg.fresh, li.fresh { background: color-mix(in srgb, var(--unread) 14%, transparent); }
	.cover { position: absolute; inset: 0; }
	.msg button { position: relative; z-index: 1; }
	.body {
		font-family: var(--mono); font-size: 0.82rem; white-space: pre-wrap; overflow-wrap: anywhere; margin-top: 0.15rem;
		display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 4; line-clamp: 4; overflow: hidden;
	}
	.msg.root .body { -webkit-line-clamp: 6; line-clamp: 6; }
	.replies { margin: 0.2rem 0 0 0.9rem; padding-left: 0.6rem; border-left: 2px solid var(--line); display: grid; gap: 0.1rem; }
	.more { font-size: 0.82rem; justify-self: start; padding: 0.2rem 0.6rem; }
	.list { list-style: none; padding: 0; margin: 0; display: grid; grid-template-columns: minmax(0, 1fr); gap: 0.5rem; }
	.list li { position: relative; padding: 0.7rem 0.9rem; }
	.list li:hover { border-color: var(--accent); }
	.list li.unread { border-left: 3px solid var(--unread); }
	.hit { position: absolute; inset: 0; }
	.list button { position: relative; z-index: 1; }
	.top { display: flex; gap: 0.4rem; align-items: baseline; font-size: 0.85rem; flex-wrap: wrap; }
	.id { color: var(--muted); }
	.who { font-family: var(--mono); font-size: 0.85rem; }
	.subject { font-weight: 600; margin: 0.15rem 0; }
	.thread { font-weight: 400; font-size: 0.8rem; }
	.dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: var(--unread); margin-right: 0.3rem; vertical-align: middle; }
	.preview { font-size: 0.85rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.chips { display: flex; gap: 0.3rem; flex-wrap: wrap; margin-top: 0.4rem; }
	.chip { border: 0; cursor: pointer; font-weight: 500; }
	.chip.sys { border: 1px solid var(--line); }
	.pager { display: flex; justify-content: center; gap: 1rem; align-items: center; margin-top: 1rem; }
	aside h3 { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); margin: 0 0 0.4rem; }
	aside h3:not(:first-child) { margin-top: 1.3rem; }
	.side { list-style: none; padding: 0; margin: 0; font-size: 0.88rem; }
	.side li { display: grid; padding: 0.15rem 0; line-height: 1.3; }
	.side .sys-name { font-size: 0.75rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.side button { font-family: var(--mono); font-size: 0.85rem; }
	.cloud { display: flex; flex-wrap: wrap; gap: 0.3rem; }
	.cloud .chip { max-width: 100%; overflow: hidden; text-overflow: ellipsis; }
	.side button { justify-self: start; text-align: left; }
</style>

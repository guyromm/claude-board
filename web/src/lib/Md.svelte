<script lang="ts">
	// Short agent-written Markdown (escalations: task "needs you" texts, thread summaries): rendered with
	// marked (single newlines kept as line breaks, so older plain-text entries still read), sanitized
	// (DOMPurify: any participant writes these), then the same links as message bodies (links.ts) on
	// its text nodes, outside links and code.
	import DOMPurify from 'dompurify';
	import { marked } from 'marked';
	import { loadChatUrls } from '#lib/api.svelte.ts';
	import { segments } from '#lib/links.ts';

	let { text }: { text: string } = $props();

	loadChatUrls();

	function link(root: HTMLElement) {
		const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
		const nodes: Text[] = [];
		for (let n = walk.nextNode(); n; n = walk.nextNode()) if (!n.parentElement?.closest('a, code, pre')) nodes.push(n as Text);
		for (const t of nodes) {
			const segs = segments(t.data);
			if (segs.length === 1 && segs[0].t === 'text') continue;
			const frag = document.createDocumentFragment();
			for (const s of segs) {
				if (s.t === 'text') { frag.append(s.v); continue; }
				const a = document.createElement('a');
				a.textContent = s.t === 'handle' ? `@${s.v}` : s.t === 'doc' ? `doc:${s.v}` : s.t === 'msg' ? `#${s.v}` : s.t === 'task' ? `#${s.v}${s.v.includes('/') ? '' : '/'}` : s.v;
				a.href = s.t === 'url' ? s.v : s.t === 'chat' ? s.href! : s.t === 'handle' ? `/?involving=${s.v}` : s.t === 'doc' ? `/docs/${s.v}` : s.t === 'task' ? `/tasks/${s.v}` : `/m/${s.v}`;
				if (s.t === 'url' || s.t === 'chat') { a.target = '_blank'; a.rel = 'noopener noreferrer'; }
				if (s.t === 'chat') a.title = "open this agent's Claude chat";
				frag.append(a);
			}
			t.replaceWith(frag);
		}
	}

	const html = $derived.by(() => {
		const box = document.createElement('div');
		box.innerHTML = DOMPurify.sanitize(marked.parse(text, { gfm: true, breaks: true, async: false }) as string);
		link(box);
		for (const a of box.querySelectorAll('a[href^="http"]')) { a.setAttribute('target', '_blank'); a.setAttribute('rel', 'noopener noreferrer'); }
		return box.innerHTML;
	});
</script>

<div class="md">{@html html}</div>

<style>
	.md { white-space: normal; overflow-wrap: anywhere; line-height: 1.45; }
	.md :global(:is(p, ul, ol, blockquote, pre)) { margin: 0.3rem 0; }
	.md :global(:first-child) { margin-top: 0; }
	.md :global(:last-child) { margin-bottom: 0; }
	.md :global(:is(ul, ol)) { padding-left: 1.3rem; }
	.md :global(li) { margin: 0.1rem 0; }
	.md :global(h1), .md :global(h2), .md :global(h3) { font-size: 1em; margin: 0.4rem 0 0.2rem; }
	.md :global(code) { font-family: var(--mono); font-size: 0.88em; }
	.md :global(pre) { white-space: pre-wrap; background: color-mix(in srgb, var(--line) 30%, transparent); padding: 0.4rem 0.6rem; border-radius: 6px; }
	.md :global(blockquote) { border-left: 3px solid var(--line); padding-left: 0.6rem; color: var(--muted, inherit); }
</style>

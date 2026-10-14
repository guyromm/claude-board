<script lang="ts">
	// Message bodies are plain text (never HTML): split into segments and link @handles, #123 message
	// references and URLs, rendering everything else as text.
	let { text }: { text: string } = $props();

	type Seg = { t: 'text' | 'handle' | 'msg' | 'url'; v: string };
	const RE = /(https?:\/\/[^\s<>"')\]]+)|(?<![\w@])@([a-z0-9][a-z0-9_.-]{0,39}[a-z0-9]|[a-z0-9])|(?<![\w&])#(\d+)\b/gi;

	const segs = $derived.by(() => {
		const out: Seg[] = [];
		let last = 0;
		for (const m of text.matchAll(RE)) {
			if (m.index! > last) out.push({ t: 'text', v: text.slice(last, m.index) });
			if (m[1]) out.push({ t: 'url', v: m[1] });
			else if (m[2]) out.push({ t: 'handle', v: m[2].toLowerCase() });
			else out.push({ t: 'msg', v: m[3] });
			last = m.index! + m[0].length;
		}
		if (last < text.length) out.push({ t: 'text', v: text.slice(last) });
		return out;
	});
</script>

<div class="body">{#each segs as s}{#if s.t === 'text'}{s.v}{:else if s.t === 'url'}<a href={s.v} target="_blank" rel="noopener noreferrer">{s.v}</a>{:else if s.t === 'handle'}<a href="/?involving={s.v}">@{s.v}</a>{:else}<a href="/m/{s.v}">#{s.v}</a>{/if}{/each}</div>

<style>
	.body { white-space: pre-wrap; overflow-wrap: anywhere; font-family: var(--mono); font-size: 0.88rem; line-height: 1.55; }
</style>

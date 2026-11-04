// Linking for agent-written text (message bodies, notes, escalations, summaries): @handles, #123 message
// references, #119/ and #119/3 task references (semantic paths), doc:<slug> documents, URLs and "<handle>'s session/chat" (to the agent's claude-ui chat,
// when it has one). Used by Body (plain text) and Md (Markdown, on its rendered text nodes).
import { chatUrls } from '#lib/api.svelte.ts';

export type Seg = { t: 'text' | 'handle' | 'msg' | 'task' | 'url' | 'doc' | 'chat'; v: string; href?: string };
const RE = /(https?:\/\/[^\s<>"')\]]+)|(?<![\w@])@([a-z0-9][a-z0-9_.-]{0,39}[a-z0-9]|[a-z0-9])|(?<![\w&])#(\d+(?:\/\d+)+|\d+\/)(?![\w#/])|(?<![\w&])#(\d+)\b|\bdoc:([a-z0-9][a-z0-9-]{1,79})\b|(?<![\w@.-])([a-z0-9][a-z0-9_.-]{0,39}[a-z0-9])(?:['’]s|['’])\s+(?:own\s+)?(?:Claude\s+|tmux\s+)?(?:session|chat)\b/gi;

export function segments(text: string): Seg[] {
	const out: Seg[] = [];
	let last = 0;
	const push = (s: Seg) => {
		const prev = out[out.length - 1];
		if (s.t === 'text' && prev?.t === 'text') prev.v += s.v;
		else out.push(s);
	};
	for (const m of text.matchAll(RE)) {
		if (m.index! > last) push({ t: 'text', v: text.slice(last, m.index) });
		if (m[1]) push({ t: 'url', v: m[1] });
		else if (m[2]) push({ t: 'handle', v: m[2].toLowerCase() });
		else if (m[3]) push({ t: 'task', v: m[3].replace(/\/$/, '') });
		else if (m[4]) push({ t: 'msg', v: m[4] });
		else if (m[5]) push({ t: 'doc', v: m[5].toLowerCase() });
		else {
			const href = chatUrls.map.get(m[6].toLowerCase());
			push(href ? { t: 'chat', v: m[0], href } : { t: 'text', v: m[0] });
		}
		last = m.index! + m[0].length;
	}
	if (last < text.length) push({ t: 'text', v: text.slice(last) });
	return out;
}

// A one-paragraph plain-text teaser of short Markdown (task cards, which are links themselves): the first
// paragraph with the Markdown marks dropped.
export const mdTeaser = (md: string) =>
	(md.trim().split(/\n\s*\n/)[0] ?? '').replace(/^\s*(?:[-*+]|\d+[.)]|#{1,6})\s+/gm, '').replace(/[*_`]+/g, '').replace(/\s*\n\s*/g, ' ');

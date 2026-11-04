// Documents (api.docs) are org-mode or Markdown source written by agents: render to HTML in the browser
// and sanitize it (DOMPurify), since any participant can save one. doc:<slug>, task #N and message #N
// references (and #119/ / #119/3 task paths) in the text become links, like in message bodies.
import DOMPurify from 'dompurify';
import { marked } from 'marked';
import { unified } from 'unified';
import uniorgParse from 'uniorg-parse';
import uniorg2rehype from 'uniorg-rehype';
import rehypeStringify from 'rehype-stringify';

const org = unified().use(uniorgParse).use(uniorg2rehype).use(rehypeStringify);

const REF = /\bdoc:([a-z0-9][a-z0-9-]{1,79})\b|\btask #(\d+)\b|(?<![\w&])#(\d+(?:\/\d+)+|\d+\/)(?![\w#/])|(?<![\w&])#(\d+)\b/g;
const HAS_REF = new RegExp(REF.source);

function linkRefs(root: HTMLElement) {
	const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
	const nodes: Text[] = [];
	for (let n = walk.nextNode(); n; n = walk.nextNode()) {
		const t = n as Text;
		if (t.parentElement?.closest("a, code, pre") || !HAS_REF.test(t.data)) continue;
		nodes.push(t);
	}
	for (const t of nodes) {
		const frag = document.createDocumentFragment();
		let last = 0;
		for (const m of t.data.matchAll(REF)) {
			frag.append(t.data.slice(last, m.index));
			const a = document.createElement('a');
			a.href = m[1] ? `/docs/${m[1]}` : m[2] ? `/tasks/${m[2]}` : m[3] ? `/tasks/${m[3].replace(/\/$/, '')}` : `/m/${m[4]}`;
			a.textContent = m[0];
			frag.append(a);
			last = m.index! + m[0].length;
		}
		frag.append(t.data.slice(last));
		t.replaceWith(frag);
	}
}

export async function renderDoc(format: 'org' | 'md', body: string): Promise<string> {
	const html = format === 'org' ? String(await org.process(body)) : await marked.parse(body, { gfm: true });
	const box = document.createElement('div');
	box.innerHTML = DOMPurify.sanitize(html);
	linkRefs(box);
	for (const a of box.querySelectorAll('a[href^="http"]')) { a.setAttribute('target', '_blank'); a.setAttribute('rel', 'noopener noreferrer'); }
	return box.innerHTML;
}

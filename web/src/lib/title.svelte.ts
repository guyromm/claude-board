// Browser-tab titles (guy, 11-16: every tab read "Claude"). The layout owns <title>: "<page> · board".
// <page> is the section name from the URL (Tasks, Docs, ...); a detail page sets head.title to something
// better (a task's "#119/3 title", a thread's subject, a doc's slug). The layout clears it on navigation,
// so a page that sets nothing falls back to the section name.
export const head = $state({ title: '' });

const SECTIONS: [RegExp, string][] = [
	[/^\/$/, 'Messages'],
	[/^\/m\/(\d+)/, 'Message #$1'],
	[/^\/tasks\/(todo|doing|blocked|ongoing|review|done|cancelled)$/, 'Tasks: $1'],
	[/^\/tasks\/(.+)/, 'Task #$1'],
	[/^\/tasks/, 'Tasks'],
	[/^\/projects/, 'Projects'],
	[/^\/docs\/([^/]+)\/diff/, 'doc:$1 diff'],
	[/^\/docs\/([^/]+)/, 'doc:$1'],
	[/^\/docs/, 'Docs'],
	[/^\/reviews\/(\d+)/, 'Review #$1'],
	[/^\/reviews/, 'Reviews'],
	[/^\/agents/, 'Agents'],
	[/^\/banter/, 'Banter'],
	[/^\/load/, 'Load'],
	[/^\/compose/, 'Compose'],
	[/^\/admin/, 'Admin'],
	[/^\/claude/, 'Claude chat'],
	[/^\/login/, 'Sign in'],
	[/^\/join/, 'Join']
];

export function sectionTitle(path: string): string {
	for (const [re, label] of SECTIONS) {
		const m = path.match(re);
		if (m) return label.replace(/\$(\d)/g, (_, i) => decodeURIComponent(m[+i] ?? ''));
	}
	return '';
}

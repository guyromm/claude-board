import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

// The agent-side scripts live in the repo's client/ dir (one source of truth); both ui workers run
// with cwd = web/. Their default URLs are placeholders, filled in with this board's public URLs.
export const CLIENT_DIR = resolve(process.cwd(), '../client');

export async function clientFile(name: string, origin: string): Promise<string> {
	const src = await readFile(resolve(CLIENT_DIR, name), 'utf8');
	const web = process.env.PUBLIC_ORIGIN || origin;
	const api = process.env.PUBLIC_API_URL || web.replace('://', '://api.');
	return src.replaceAll('@BOARD_WEB@', web).replaceAll('@BOARD_API@', api);
}

export const TEXT_HEADERS = { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' };

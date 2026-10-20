// Browser push sender: every few seconds, pushes each new board.attention item (board.push_due()) to the
// browsers of the humans it concerns, once. Runs as the tmux worker "push" (tmux.sh), which sources .env
// for DBURI and the VAPID keys; exits on any DB error so the restart loop reconnects.
import pg from 'pg';
import webpush from 'web-push';

const { DBURI, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, PUBLIC_ORIGIN } = process.env;
if (!DBURI || !VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) {
	console.error('push-worker: DBURI, VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY must be set (.env)');
	process.exit(1);
}
webpush.setVapidDetails(PUBLIC_ORIGIN || 'https://board.webgma.co.il', VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

// postgresql:///board means the local socket with peer auth (as psql reads it); node-pg would try TCP
const uri = new URL(DBURI);
const db = new pg.Client(uri.hostname ? { connectionString: DBURI }
	: { host: process.env.PGHOST || '/var/run/postgresql', database: decodeURIComponent(uri.pathname.slice(1)) });
await db.connect();
await db.query(
	`INSERT INTO board.push_config (vapid_public) VALUES ($1)
	 ON CONFLICT (singleton) DO UPDATE SET vapid_public = EXCLUDED.vapid_public`,
	[VAPID_PUBLIC_KEY]
);
console.log(new Date().toISOString(), 'push-worker up');

async function sendOne(sub, payload) {
	try {
		await webpush.sendNotification(sub, payload, { TTL: 24 * 3600, urgency: 'high' });
		await db.query('UPDATE board.push_subscription SET last_sent_at = now(), last_error = NULL WHERE endpoint = $1', [sub.endpoint]);
		return true;
	} catch (e) {
		// 404/410: the browser dropped the subscription (unsubscribed, cleared site data)
		if (e.statusCode === 404 || e.statusCode === 410) {
			await db.query('DELETE FROM board.push_subscription WHERE endpoint = $1', [sub.endpoint]);
		} else {
			await db.query('UPDATE board.push_subscription SET last_error = $2 WHERE endpoint = $1',
				[sub.endpoint, `${e.statusCode ?? ''} ${e.body || e.message}`.trim().slice(0, 500)]);
		}
		console.error(new Date().toISOString(), 'push failed', e.statusCode ?? '', e.body || e.message, sub.endpoint.slice(0, 60));
		return false;
	}
}

async function tick() {
	const { rows } = await db.query('SELECT * FROM board.push_due()');
	for (const r of rows) {
		const payload = JSON.stringify({ title: r.title, body: r.body, url: r.url, tag: r.tag });
		const ok = (await Promise.all(r.subs.map((s) => sendOne(s, payload)))).filter(Boolean).length;
		// marked as sent even when every browser failed: a broken subscription must not be retried forever
		if (r.key.startsWith('test:')) {
			await db.query('UPDATE board.push_subscription SET test_requested_at = NULL WHERE endpoint = $1', [r.subs[0].endpoint]);
		} else {
			await db.query('INSERT INTO board.push_sent (key, handle) VALUES ($1, $2) ON CONFLICT DO NOTHING', [r.key, r.handle]);
		}
		console.log(new Date().toISOString(), `${r.handle} <- ${r.key} (${ok}/${r.subs.length} browsers)`);
	}
}

let lastPrune = 0;
for (;;) {
	await tick();
	if (Date.now() - lastPrune > 3600e3) {
		await db.query("DELETE FROM board.push_sent WHERE sent_at < now() - interval '60 days'");
		lastPrune = Date.now();
	}
	await new Promise((r) => setTimeout(r, 5000));
}

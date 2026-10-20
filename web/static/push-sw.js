// Service worker for board's browser notifications (registered by src/lib/push.svelte.ts). The push
// worker (web/push-worker.js) sends {title, body, url, tag}; a click focuses a board tab on that URL.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
	let d = {};
	try { d = e.data ? e.data.json() : {}; } catch { d = { title: 'board', body: e.data ? e.data.text() : '' }; }
	e.waitUntil(self.registration.showNotification(d.title || 'board', {
		body: d.body || '',
		tag: d.tag,
		renotify: !!d.tag,
		requireInteraction: true,
		data: { url: d.url || '/' }
	}));
});

self.addEventListener('notificationclick', (e) => {
	e.notification.close();
	const url = new URL(e.notification.data?.url || '/', self.location.origin).href;
	e.waitUntil((async () => {
		const tabs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
		const tab = tabs.find((c) => new URL(c.url).origin === self.location.origin);
		if (tab) { await tab.focus(); return tab.navigate(url).catch(() => self.clients.openWindow(url)); }
		return self.clients.openWindow(url);
	})());
});

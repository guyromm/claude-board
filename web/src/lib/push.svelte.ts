// Browser notifications (Web Push) for humans: registers static/push-sw.js, subscribes with the board's
// VAPID key and stores the subscription (api.push_subscribe). The push worker does the sending.
import { api } from '#lib/api.svelte.ts';

export const pushSupported =
	typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;

export const push = $state<{ on: boolean; busy: boolean; error: string }>({ on: false, busy: false, error: '' });

const registration = () => navigator.serviceWorker.register('/push-sw.js');

function keyBytes(b64url: string) {
	const s = atob(b64url.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (b64url.length % 4)) % 4));
	return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

// is this browser subscribed? (re-saves the subscription, in case it was renewed or another user signed in)
export async function pushRefresh() {
	if (!pushSupported || Notification.permission !== 'granted') return (push.on = false);
	const sub = await (await registration()).pushManager.getSubscription();
	push.on = !!sub;
}

export async function pushEnable() {
	push.busy = true; push.error = '';
	try {
		if ((await Notification.requestPermission()) !== 'granted') throw new Error('notifications are blocked for this site in the browser settings');
		const { data: key } = await api<string | null>('/rpc/push_key', { body: {} });
		if (!key) throw new Error('the push worker is not running on the server');
		const reg = await registration();
		await navigator.serviceWorker.ready;
		let sub = await reg.pushManager.getSubscription();
		if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(key) });
		const j = sub.toJSON();
		await api('/rpc/push_subscribe', { body: { endpoint: j.endpoint, p256dh: j.keys?.p256dh, auth: j.keys?.auth, user_agent: navigator.userAgent } });
		push.on = true;
	} catch (e) {
		push.error = (e as Error).message;
	} finally {
		push.busy = false;
	}
}

export async function pushDisable() {
	push.busy = true; push.error = '';
	try {
		const sub = await (await registration()).pushManager.getSubscription();
		if (sub) {
			await api('/rpc/push_unsubscribe', { body: { endpoint: sub.endpoint } }).catch(() => {});
			await sub.unsubscribe();
		}
		push.on = false;
	} catch (e) {
		push.error = (e as Error).message;
	} finally {
		push.busy = false;
	}
}

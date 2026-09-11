window.SUPABASE_URL='https://zibymvoatyyrzadwwxnf.supabase.co';
window.SUPABASE_ANON_KEY='sb_publishable_WRQf7hoQgaUhv_IQxYFayw_YdJCIAdZ';
window.SITE_ASSET_PREFIX='';
(() => {
  const memory = new Map();
  const timeoutFetch = (input, init = {}) => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 15000);
    const signals = [controller.signal, init.signal].filter(Boolean);
    const signal = typeof AbortSignal.any === 'function' ? AbortSignal.any(signals) : controller.signal;
    return fetch(input, {...init, signal}).finally(() => clearTimeout(timer));
  };
  window.createChikClient = () => {
    if (!window.__chikClient) {
      window.__chikClient = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY, {
        global: {fetch: timeoutFetch},
        auth: {persistSession: true, autoRefreshToken: true, detectSessionInUrl: true}
      });
    }
    return window.__chikClient;
  };
  window.assetUrl = (value) => {
    const url = String(value || '');
    if (!url || /^https?:\/\//i.test(url) || url.startsWith('data:') || url.startsWith('/')) return url;
    return url;
  };
  window.readPageCache = (key, maxAge = 120000) => {
    const now = Date.now();
    const hit = memory.get(key);
    if (hit && now - hit.time < maxAge) return hit.value;
    try {
      const stored = JSON.parse(sessionStorage.getItem(`chikchik:${key}`) || 'null');
      if (stored && now - stored.time < maxAge) {
        memory.set(key, stored);
        return stored.value;
      }
    } catch {}
    return null;
  };
  window.writePageCache = (key, value) => {
    const item = {time: Date.now(), value};
    memory.set(key, item);
    try { sessionStorage.setItem(`chikchik:${key}`, JSON.stringify(item)); } catch {}
    return value;
  };
  window.scheduleIdle = (fn, delay = 250) => {
    const run = () => (window.requestIdleCallback ? requestIdleCallback(fn, {timeout: 1200}) : fn());
    setTimeout(run, delay);
  };
})();
// All-in Put API — Vercel serverless function (also mounted by vite.config.js for local dev).
// Every request is POST /api/game?a=<action>. All game rules live in Postgres (supabase/schema.sql);
// this layer only authenticates the caller and forwards to the right database function.
import { createClient } from '@supabase/supabase-js';
import crypto from 'node:crypto';

const TOKEN_TTL_MS = 12 * 60 * 60 * 1000;

let db;
const getDb = () => db ||= createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

// --- signed session tokens (stateless, so they work across serverless instances)
const hmac = data => crypto.createHmac('sha256', process.env.SESSION_SECRET).update(data).digest('base64url');
const sign = payload => {
  const d = Buffer.from(JSON.stringify({ ...payload, exp: Date.now() + TOKEN_TTL_MS })).toString('base64url');
  return d + '.' + hmac(d);
};
const verify = token => {
  const [d, s] = String(token || '').split('.');
  if (!d || !s) return null;
  const want = Buffer.from(hmac(d)), got = Buffer.from(s);
  if (want.length !== got.length || !crypto.timingSafeEqual(want, got)) return null;
  try {
    const p = JSON.parse(Buffer.from(d, 'base64url').toString());
    return p.exp > Date.now() ? p : null;
  } catch { return null; }
};
const sameText = (a, b) => crypto.timingSafeEqual(
  crypto.createHash('sha256').update(String(a)).digest(),
  crypto.createHash('sha256').update(String(b)).digest());

async function readBody(req) {
  try {
    if (req.body !== undefined) return typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
  } catch { return {}; }
  let raw = '';
  for await (const chunk of req) { raw += chunk; if (raw.length > 1e6) break; }
  try { return JSON.parse(raw || '{}'); } catch { return {}; }
}

async function rpc(fn, args) {
  const { data, error } = await getDb().rpc(fn, args);
  if (error) {
    if (error.code === 'P0001') throw new HttpError(400, error.message);
    if (error.code === 'ZG401') throw new HttpError(401, error.message);
    console.error(fn, error);
    throw new HttpError(500, 'Server error');
  }
  return data;
}

const TEAM_ACTIONS = { me: 'me', buy: 'buy', 'team/bid': 'bid', 'trade/sell': 'trade_sell', 'trade/update': 'trade_update', 'trade/cancel': 'trade_cancel' };

export default async function handler(req, res) {
  const send = (status, obj) => {
    res.statusCode = status;
    res.setHeader('content-type', 'application/json');
    res.setHeader('cache-control', 'no-store');
    res.end(JSON.stringify(obj));
  };
  try {
    if (!process.env.SESSION_SECRET || !process.env.SUPABASE_URL || !process.env.SUPABASE_SECRET_KEY) {
      console.error('Missing SESSION_SECRET / SUPABASE_URL / SUPABASE_SECRET_KEY');
      return send(500, { error: 'Server is not configured' });
    }
    if (req.method !== 'POST') return send(405, { error: 'Method not allowed' });
    const a = new URL(req.url, 'http://local').searchParams.get('a') || '';
    const b = await readBody(req);

    if (a === 'login') {
      const username = String(b.username || '').trim(), password = String(b.password || '');
      if (username === 'admin') {
        if (process.env.ADMIN_PASS && password && sameText(password, process.env.ADMIN_PASS)) {
          return send(200, { token: sign({ r: 'admin' }), role: 'admin' });
        }
      } else if (username && password) {
        const t = await rpc('game_login', { p_u: username, p_p: password });
        if (t) return send(200, { token: sign({ r: 'team', id: t.id, v: t.ver }), role: 'team', u: t.u });
      }
      return send(401, { error: 'Wrong team name or password' });
    }

    const s = verify((req.headers.authorization || '').replace(/^Bearer\s+/i, ''));
    if (!s) return send(401, { error: 'Please log in again' });

    if (s.r === 'team') {
      if (!TEAM_ACTIONS[a]) return send(403, { error: 'Not allowed' });
      return send(200, await rpc('game_team', { p_team: s.id, p_ver: s.v, p_action: TEAM_ACTIONS[a], p_body: b }));
    }
    if (s.r === 'admin' && a.startsWith('admin/')) {
      return send(200, await rpc('game_admin', { p_action: a.slice(6), p_body: b }));
    }
    return send(404, { error: 'Not found' });
  } catch (e) {
    return send(e.status || 500, { error: e.status ? e.message : 'Server error' });
  }
}

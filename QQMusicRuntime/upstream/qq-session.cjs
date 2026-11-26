// Request-scoped authentication for the pinned Rain120 wrapper. No global cookie jar.
const { AsyncLocalStorage } = require('node:async_hooks');
const { timingSafeEqual } = require('node:crypto');
const revision = require('node:crypto').createHash('sha256').update(require('node:fs').readFileSync(__filename))
    .update(require('node:fs').readFileSync(require('node:path').join(__dirname, __filename.endsWith('.cjs') ? 'qq-library.cjs' : 'ipple-library.js')))
    .update(require('node:fs').readFileSync(require('node:path').join(__dirname, __filename.endsWith('.cjs') ? 'qq-lyrics.cjs' : 'ipple-lyrics.js')))
    .update(require('node:fs').readFileSync(require('node:path').join(__dirname, __filename.endsWith('.cjs') ? 'qq-recommendations.cjs' : 'ipple-recommendations.js')))
    .update(require('node:fs').readFileSync(require('node:path').join(__dirname, __filename.endsWith('.cjs') ? 'qq-favorites.cjs' : 'ipple-favorites.js')))
    .update(require('node:fs').readFileSync(require('node:path').join(__dirname, __filename.endsWith('.cjs') ? 'qq-web.cjs' : 'ipple-web.js'))).digest('hex');
const storage = new AsyncLocalStorage();
const anonymous = Object.freeze({ cookie: '', uin: '0', key: '', gtk: 5381 });
const names = new Set(['uin', 'qqmusic_uin', 'wxuin', 'qqmusic_key', 'music_key', 'qm_keyst', 'wxopenid', 'wxunionid', 'login_type', 'tmeLoginType']);

function current() { return storage.getStore() || anonymous; }
function parse(cookie = '') {
    if (cookie.length > 8192 || /[\r\n\x00]/.test(cookie)) throw new Error('invalid session');
    const values = {};
    for (const part of cookie.split(';')) {
        if (!part.trim()) continue;
        const separator = part.indexOf('=');
        const name = part.slice(0, separator).trim();
        const value = part.slice(separator + 1).trim();
        if (separator < 1 || !names.has(name) || !value || values[name]) throw new Error('invalid session');
        values[name] = value;
    }
    const uin = (values.uin || values.qqmusic_uin || values.wxuin || '').replace(/^o/, '').replace(/^0+(?=\d)/, '');
    const key = values.qm_keyst || values.qqmusic_key || values.music_key || '';
    if (!/^[1-9]\d{4,19}$/.test(uin) || !key) throw new Error('invalid session');
    let gtk = 5381;
    for (const char of key) gtk += (gtk << 5) + char.charCodeAt(0);
    return { cookie: Object.entries(values).map(([k, v]) => `${k}=${v}`).join('; '), uin, key, gtk: gtk & 0x7fffffff };
}
function rewrite(data, session) {
    if (!data || typeof data !== 'object') return;
    for (const [key, value] of Object.entries(data)) {
        if (key === 'uin' || key === 'loginUin') data[key] = session.uin;
        else if (key === 'g_tk') data[key] = session.gtk;
        else if (value && typeof value === 'object') rewrite(value, session);
    }
    if (data.comm) {
        data.comm.uin = session.uin;
        if (session.key) data.comm.authst = session.key;
    }
}
function decorate(config) {
    const session = current();
    const url = new URL(config.url, config.baseURL);
    if (!['c.y.qq.com', 'u.y.qq.com', 'u6.y.qq.com', 'y.qq.com'].includes(url.hostname) || url.protocol !== 'https:') {
        throw new Error('untrusted QQ upstream');
    }
    config.headers = { ...config.headers };
    for (const key of Object.keys(config.headers)) if (key.toLowerCase() === 'cookie') delete config.headers[key];
    if (session.cookie) config.headers.Cookie = session.cookie;
    config.maxRedirects = 0;
    config.params = { ...(config.params || {}), g_tk: session.gtk, loginUin: session.uin };
    if (typeof config.params.data === 'string') {
        const data = JSON.parse(config.params.data);
        rewrite(data, session);
        config.params.data = JSON.stringify(data);
    }
    if (config.data && typeof config.data === 'object') {
        config.data = JSON.parse(JSON.stringify(config.data));
        rewrite(config.data, session);
    }
    return config;
}
function install(axios) {
    axios.interceptors.request.use(decorate);
    axios.interceptors.response.use(response => response, error => {
        const safe = new Error('QQ upstream request failed');
        safe.status = error.response?.status;
        return Promise.reject(safe);
    });
}
function avatarURL(value) {
    if (typeof value !== 'string' || value.length > 2048) return undefined;
    try {
        const url = new URL(value.startsWith('//') ? `https:${value}` : value);
        if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.port) return undefined;
        if (!['qq.com', 'qlogo.cn', 'qpic.cn'].some(host => url.hostname === host || url.hostname.endsWith(`.${host}`))) return undefined;
        url.protocol = 'https:';
        return url.href;
    } catch (_) { return undefined; }
}
async function verify(axios) {
    const session = current();
    if (!session.cookie) return { state: 'unbound' };
    const envelope = {
        comm: { ct: 24, cv: 0, uin: session.uin, format: 'json' },
        account: { module: 'music.UserInfo.userInfoServer', method: 'GetLoginUserInfo', param: {} },
    };
    try {
        const response = await axios.get('https://u.y.qq.com/cgi-bin/musicu.fcg', {
            params: { format: 'json', data: JSON.stringify(envelope) },
            headers: { Referer: 'https://y.qq.com/' }, timeout: 10000,
        });
        const body = response.data;
        const account = body?.account;
        if ([1000, 2000, 401, 403].includes(body?.code) || [1000, 2000, 401, 403].includes(account?.code)) return { state: 'expired' };
        if (body?.code !== 0 || account?.code !== 0) return { state: 'unavailable' };
        const info = account?.data?.info;

        if (!info?.nick || (info.uin && String(info.uin) !== session.uin)) return { state: 'expired' };
        const avatar = avatarURL(info.logo || info.headpic || info.avatar || info.avatarurl || info.avatar_url);
        return { state: 'connected', account_id: session.uin, nickname: String(info.nick).slice(0, 120),
            ...(avatar ? { avatar_url: avatar } : {}) };
    } catch (error) { return { state: [401, 403].includes(error.status) ? 'expired' : 'unavailable' }; }
}
// 官方一次性授权码由服务端交换；账号和音乐密钥都来自 QQ 的响应。
async function exchangeCode(axios, code) {
    if (typeof code !== 'string' || !/^[A-Za-z0-9_-]{16,512}$/.test(code)) return { state: 'expired' };
    try {
        const envelope = {
            comm: { g_tk: 5381, platform: 'yqq', ct: 24, cv: 0 },
            req: { module: 'QQConnectLogin.LoginServer', method: 'QQLogin', param: { code } },
        };
        const response = await storage.run(anonymous, () => axios.post('https://u.y.qq.com/cgi-bin/musicu.fcg', JSON.stringify(envelope), {
            headers: { Referer: 'https://y.qq.com/', 'Content-Type': 'application/x-www-form-urlencoded' }, timeout: 10000,
        }));
        const body = response.data;
        if (body?.code !== 0 || body?.req?.code !== 0) return { state: 'expired' };
        const data = body.req.data || {};
        const values = {};
        for (const header of response.headers?.['set-cookie'] || []) {
            for (const part of header.split(/,(?=\s*[A-Za-z_][A-Za-z0-9_]*=)/)) {
                const pair = part.split(';')[0].trim();
                const split = pair.indexOf('=');
                const name = pair.slice(0, split);
                if (split > 0 && names.has(name)) values[name] = pair.slice(split + 1);
            }
        }
        const musicID = data.musicid ? String(data.musicid) : (values.uin || values.qqmusic_uin || '').replace(/^o/, '').replace(/^0+/, '');
        const key = data.musickey || values.qm_keyst || values.qqmusic_key || values.music_key;
        if (!/^[1-9]\d{4,19}$/.test(musicID) || !key || /[\x00-\x20;\x7f-\uffff]/.test(key)) return { state: 'unavailable' };
        if (values.uin && values.uin.replace(/^o/, '').replace(/^0+/, '') !== musicID) return { state: 'unavailable' };
        const cookie = `uin=${musicID}; qm_keyst=${key}; qqmusic_key=${key}; login_type=1`;
        const session = parse(cookie);
        const status = await storage.run(session, () => verify(axios));
        if (status.state !== 'connected') return status;
        // 不持久化或回显 OAuth code；音乐 Cookie 只进入密钥保护的内部响应。
        return { ...status, cookie, expires_at: new Date(Date.now() + 24 * 3600 * 1000).toISOString() };
    } catch (_) { return { state: 'unavailable' }; }
}
function middleware() {
    return async (ctx, next) => {
        const secret = process.env.QQ_GATEWAY_KEY || '';
        const provided = ctx.get('X-Ipple-QQ-Gateway-Key');
        const cookie = ctx.get('X-Ipple-QQ-Session');
        const protectedRoute = ctx.path.startsWith('/ipple/qq/');
        if (/^\/(?:get|set)cookie\/?$/i.test(ctx.path)) { ctx.status = 404; return; }
        if (protectedRoute || cookie) {
            const expected = Buffer.from(secret);
            const candidate = Buffer.from(provided);
            if (secret.length < 32 || candidate.length !== expected.length || !timingSafeEqual(expected, candidate)) {
                ctx.status = 401; ctx.body = { code: 'QQ_GATEWAY_AUTH_REQUIRED' }; return;
            }
        }
        let session = anonymous;
        if (cookie) {
            try { session = parse(cookie); } catch (_) { ctx.status = 400; ctx.body = { code: 'QQ_SESSION_INVALID' }; return; }
        }
        await storage.run(session, async () => {
            if (ctx.path === '/ipple/qq/capabilities') ctx.body = { isolation_version: 1, revision };
            else if (ctx.path === '/ipple/qq/login' && ctx.method === 'POST') ctx.body = await exchangeCode(require('axios'), ctx.request.body?.code);
            else if (ctx.path === '/ipple/qq/session') ctx.body = await verify(require('axios'));
            else if (ctx.path === '/ipple/qq/library') {
                try { ctx.body = await require('./ipple-library').read(require('axios'), session, ctx.query); }
                catch (error) { ctx.body = { state: error.state || 'unavailable' }; }
            }
            else if (ctx.path === '/ipple/qq/recommendations' && ctx.method === 'GET') {
                try { ctx.body = await require('./ipple-recommendations').read(require('axios'), session, ctx.query); }
                catch (error) { ctx.body = { state: error.state || 'unavailable' }; }
            }
            else if (ctx.path === '/ipple/qq/favorites' && ctx.method === 'POST') {
                try {
                    const input = ctx.request.body;
                    const favorites = require('./ipple-favorites');
                    ctx.body = input?.action === 'check' ? await favorites.check(require('axios'), session, input.ids)
                        : input?.action === 'set' ? await favorites.set(require('axios'), session, input) : { state: 'invalid' };
                } catch (error) { ctx.body = { state: error.state || 'unavailable' }; }
            }
            else if (ctx.path === '/getLyric' && ctx.method === 'GET') {
                const result = await require('./ipple-lyrics').read(require('axios'), session, ctx.query);
                if (result) ctx.body = { response: result };
                else await next();
            }
            else await next();
        });
        ctx.remove('Set-Cookie');
        ctx.set('Cache-Control', 'no-store');
    };
}
module.exports = { current, parse, decorate, install, verify, exchangeCode, middleware, storage };

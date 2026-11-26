const test = require('node:test');
const assert = require('node:assert/strict');
const session = require('./qq-session.cjs');

test('concurrent QQ and anonymous requests never share credentials or mutate input', async () => {
    const source = { comm: { uin: '0' }, req: { param: { uin: '0' } } };
    await Promise.all(Array.from({ length: 100 }, async (_, index) => {
        const uin = String(10000 + index);
        const value = session.parse(`uin=${uin}; qqmusic_key=token-${uin}`);
        await session.storage.run(value, async () => {
            await new Promise(resolve => setImmediate(resolve));
            const out = session.decorate({ url: 'https://u.y.qq.com/cgi-bin/musicu.fcg', params: { data: JSON.stringify(source) }, headers: {} });
            assert.equal(out.headers.Cookie, value.cookie);
            assert.equal(out.params.loginUin, uin);
            const body = JSON.parse(out.params.data);
            assert.equal(body.comm.uin, uin);
            assert.equal(body.req.param.uin, uin);
            assert.equal(body.comm.authst, `token-${uin}`);
            await new Promise(resolve => setImmediate(resolve));
            assert.equal(session.current().uin, uin);
        });
    }));
    assert.equal(source.comm.uin, '0');
    assert.equal(session.current().uin, '0');
    const anonymous = session.decorate({ url: 'https://c.y.qq.com/test', headers: { Cookie: 'stale' } });
    assert.equal(anonymous.headers.Cookie, undefined);
    assert.throws(() => session.decorate({ url: 'https://untrusted.example/', headers: {} }));
});

test('gateway rejects unauthenticated session input and disables global cookie routes', async () => {
    process.env.QQ_GATEWAY_KEY = 'fixture-key-'.repeat(4);
    const make = (path, headers) => ({ path, get: key => headers[key] || '', remove() {}, set() {} });
    const ctx = make('/getMusicPlay', { 'X-Ipple-QQ-Session': 'uin=12345; qqmusic_key=secret' });
    await session.middleware()(ctx, () => { throw new Error('must not run'); });
    assert.equal(ctx.status, 401);
    const global = make('/getCookie', {});
    await session.middleware()(global, () => { throw new Error('must not run'); });
    assert.equal(global.status, 404);
    const capability = make('/ipple/qq/capabilities', { 'X-Ipple-QQ-Gateway-Key': process.env.QQ_GATEWAY_KEY });
    await session.middleware()(capability, () => { throw new Error('must not run'); });
    assert.equal(capability.body.isolation_version, 1);
});

test('session verification distinguishes valid, expired and unavailable responses', async () => {
    const value = session.parse('uin=12345; qm_keyst=fixture-token');
    await session.storage.run(value, async () => {
        const valid = { get: async () => ({ data: { code: 0, account: { code: 0, data: { info: { uin: '12345', nick: 'Fixture' } } } } }) };
        assert.equal((await session.verify(valid)).state, 'connected');
        for (const info of [{ nick: 'Wrong identity', uin: '54321' }]) {
            const spoofed = { get: async () => ({ data: { code: 0, account: { code: 0, data: { info } } } }) };
            assert.equal((await session.verify(spoofed)).state, 'expired');
        }
        const expired = { get: async () => ({ data: { code: 0, account: { code: 1000 } } }) };
        assert.equal((await session.verify(expired)).state, 'expired');
        const offline = { get: async () => { throw new Error('network'); } };
        assert.equal((await session.verify(offline)).state, 'unavailable');
    });
    assert.equal((await session.verify({})).state, 'unbound');
    assert.throws(() => session.parse('uin=12345; p_skey=must-not-capture; qqmusic_key=token'));
});

test('primary login exchanges official code and uses server-returned identity', async () => {
    const axios = {
        post: async (_, payload) => {
            const request = JSON.parse(payload);
            assert.equal(request.req.param.code, 'fixture-authorization-code');
            assert.equal(request.req.param.musicid, undefined);
            return { data: { code: 0, req: { code: 0, data: { musicid: '12345', musickey: 'official-fixture-key' } } }, headers: {} };
        },
        get: async () => ({ data: { code: 0, account: { code: 0, data: { info: { nick: 'Fixture' } } } } }),
    };
    const result = await session.exchangeCode(axios, 'fixture-authorization-code');
    assert.equal(result.state, 'connected');
    assert.equal(result.account_id, '12345');
    assert.ok(result.cookie.includes('official-fixture-key'));
    assert.equal(result.code, undefined);
    const expired = { post: async () => ({ data: { code: 0, req: { code: 1000 } } }) };
    assert.equal((await session.exchangeCode(expired, 'fixture-authorization-code')).state, 'expired');
    const missingIdentity = { post: async () => ({ data: { code: 0, req: { code: 0, data: { musickey: 'fixture' } } } }) };
    assert.equal((await session.exchangeCode(missingIdentity, 'fixture-authorization-code')).state, 'unavailable');
    assert.equal((await session.exchangeCode({}, 'short')).state, 'expired');
    assert.equal(session.current().uin, '0');
});

test('axios failures cannot leak credentials through legacy handler logging', async () => {
    let reject;
    session.install({ interceptors: { request: { use() {} }, response: { use(_, handler) { reject = handler; } } } });
    try {
        await reject({ config: { headers: { Cookie: 'fixture-secret' } }, response: { status: 403, data: 'fixture-secret' } });
        assert.fail('must reject');
    } catch (error) {
        assert.equal(error.status, 403);
        assert.equal(error.config, undefined);
        assert.equal(error.response, undefined);
        assert.ok(!String(error).includes('fixture-secret'));
    }
});


test('account avatars are optional, normalized to HTTPS and limited to QQ image hosts', async () => {
    await session.storage.run(session.parse('uin=12345; qm_keyst=fixture-token'), async () => {
        for (const [logo, expected] of [
            ['http://thirdqq.qlogo.cn/g?b=qq&nk=12345&s=100', 'https://thirdqq.qlogo.cn/g?b=qq&nk=12345&s=100'],
            ['//y.gtimg.cn/not-accepted.png', undefined],
            ['https://qlogo.cn.attacker.example/photo', undefined],
            ['file:///tmp/avatar', undefined], ['', undefined],
        ]) {
            const axios = { get: async () => ({ data: { code: 0,
                account: { code: 0, data: { info: { uin: '12345', nick: 'Fixture', logo } } } } }) };
            const result = await session.verify(axios);
            assert.equal(result.state, 'connected');
            assert.equal(result.avatar_url, expected);
        }
    });
});

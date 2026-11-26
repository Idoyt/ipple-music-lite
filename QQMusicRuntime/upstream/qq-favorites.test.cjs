const test = require('node:test');
const assert = require('node:assert/strict');
const { createDecipheriv } = require('node:crypto');
const favorites = require('./qq-favorites.cjs');
const web = require('./qq-web.cjs');
const sessions = require('./qq-session.cjs');
const key = Buffer.from([189, 48, 95, 16, 208, 255, 116, 182, 239, 84, 218, 184, 53, 181, 225, 207]);
const mask = [122, 63, 140, 29, 94, 155, 47, 10, 108, 77, 126, 139, 31, 58, 92, 157, 14, 43, 111, 74, 129];
function fixture(session, options = {}) {
    let liked = false, writes = 0, details = 0;
    const axios = { post: async (url, input, config) => {
        await new Promise(resolve => setImmediate(resolve));
        const decorated = sessions.decorate({ url, data: input, ...config });
        assert.equal(decorated.headers.Cookie, session.cookie);
        const signed = typeof input === 'string';
        let payload = input;
        if (signed) {
            const bytes = Buffer.from(input, 'base64'), decipher = createDecipheriv('aes-128-gcm', key, bytes.subarray(0, 12));
            decipher.setAuthTag(bytes.subarray(-16));
            const body = Buffer.concat([decipher.update(bytes.subarray(12, -16)), decipher.final()]).toString();
            assert.equal(config.params.sign, web.sign(body));
            assert.equal(config.params.encoding, 'ag-1');
            assert.equal(url, 'https://u6.y.qq.com/cgi-bin/musics.fcg');
            payload = JSON.parse(body);
        }
        assert.equal(payload.comm.uin, session.uin);
        assert.equal(payload.comm.authst, session.key);
        const op = payload.favorite;
        let data;
        if (op.method === 'IsSongFanByMid') {
            data = { m_fan: Object.fromEntries(op.param.v_songMid.map(id => [id, options.missing ? null : options.unconfirmed ? false : liked])) };
        } else if (op.method === 'get_song_detail_yqq') {
            details++;
            data = { track_info: { mid: options.wrongMid ? 'other' : 'mid1', id: 123, type: 13 } };
        } else {
            writes++;
            assert.ok(signed);
            assert.deepEqual(op.param, { dirId: 201, v_songInfo: [{ songId: 123, songType: 13 }] });
            if (!options.reject) liked = op.method === 'AddSonglist';
            data = { retCode: 0 };
        }
        const result = { code: 0, favorite: { code: signed && options.reject ? 80105 : 0, data } };
        if (!signed) return { data: result };
        const bytes = Buffer.from(JSON.stringify(result));
        for (let i = 0; i < bytes.length; i++) bytes[i] ^= mask[i % mask.length];
        return { data: bytes };
    } };
    return { axios, counts: () => ({ writes, details }) };
}

test('zzc signatures match the upstream MIT protocol vectors', () => {
    assert.equal(web.sign('123'), 'zzcec1b555gzqzg7laztguyjl2bu20r6x1w50c55f60');
    assert.equal(web.sign('hello world'), 'zzcfb3415bc4nfoxmd9uik71mkomtubjfjp141a1cbbcc');
});
test('isolated accounts sign exactly the authenticated payload, confirm writes, and skip duplicate changes', async () => {
    await Promise.all(Array.from({ length: 20 }, async (_, index) => {
        const session = sessions.parse(`uin=${10000 + index}; qqmusic_key=fixture-${index}`);
        const { axios, counts } = fixture(session);
        await sessions.storage.run(session, async () => {
            assert.equal((await favorites.set(axios, session, { track_id: 'mid1', enabled: true })).liked.mid1, true);
            await favorites.set(axios, session, { track_id: 'mid1', enabled: true });
            assert.deepEqual(counts(), { writes: 1, details: 1 });
            assert.equal((await favorites.set(axios, session, { track_id: 'mid1', enabled: false })).liked.mid1, false);
            assert.deepEqual(counts(), { writes: 2, details: 2 });
        });
    }));
});
test('missing status, mismatched identity, rejected module codes and unconfirmed writes never report success', async () => {
    const session = sessions.parse('uin=12345; qqmusic_key=fixture');
    for (const options of [{ missing: true }, { wrongMid: true }, { reject: true }, { unconfirmed: true }]) {
        const f = fixture(session, options);
        await sessions.storage.run(session, async () => {
            await assert.rejects(favorites.set(f.axios, session, { track_id: 'mid1', enabled: true }), e => e.state === 'unavailable');
        });
        assert.equal(f.counts().writes, options.reject || options.unconfirmed ? 1 : 0);
    }
});
test('anonymous and invalid mutations do not reach QQ', async () => {
    const session = sessions.parse('uin=12345; qm_keyst=fixture');
    const axios = { post() { throw Error('must not call upstream'); } };
    for (const input of [{ track_id: '../mid', enabled: true }, { track_id: 'mid1', enabled: 'false' }]) {
        await assert.rejects(favorites.set(axios, session, input), e => e.state === 'invalid');
    }
    await assert.rejects(favorites.check(axios, { cookie: '', uin: '0' }, ['mid1']), e => e.state === 'expired');
});

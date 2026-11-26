const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./qq-lyrics.cjs');
const sessions = require('./qq-session.cjs');

const encode = value => Buffer.from(value).toString('base64');
const reply = data => ({ data: { code: 0, lyric: { code: 0, data: { crypt: 0, ...data } } } });

test('current lyric RPC requests translations and unencrypted line-timed lyrics', async () => {
    const axios = { get: async (url, config) => {
        assert.equal(url, 'https://u.y.qq.com/cgi-bin/musicu.fcg');
        const request = JSON.parse(config.params.data);
        assert.equal(request.lyric.module, 'music.musichallSong.PlayLyricInfo');
        assert.equal(request.lyric.method, 'GetPlayLyricInfo');
        assert.equal(request.lyric.param.songMid, 'song1');
        if (request.lyric.param.qrc === 1) {
            assert.equal(request.lyric.param.trans, 0);
            return reply({ qrc: 1, lyric: 'a'.repeat(16) });
        }
        assert.equal(request.lyric.param.trans, 1);
        assert.equal(request.lyric.param.crypt, 0);
        assert.equal(request.lyric.param.qrc, 0);
        return reply({ lyric: encode('[00:01.20]Hello'), trans: encode('[00:01.20]你好') });
    } };
    const result = await read(axios, { uin: '0' }, { songmid: 'song1' });
    assert.equal(result.lyric, '[00:01.20]Hello');
    assert.equal(Buffer.from(result.trans, 'base64').toString(), '[00:01.20]你好');
    assert.equal(result.word_lyric, 'a'.repeat(16));
});

test('plain original LRC and a genuinely missing translation remain valid', async () => {
    const result = await read({ get: async () => reply({ lyric: '[00:01]Original', trans: '' }) }, { uin: '0' }, { songmid: 'song1' });
    assert.equal(result.lyric, '[00:01]Original');
    assert.equal(result.trans, '');
});

test('bad or encrypted current responses select the legacy fallback', async () => {
    for (const response of [
        { data: {} }, { data: { code: 2000 } }, { data: { code: 0, lyric: { code: 24001 } } },
        reply({ crypt: 1, lyric: '012345abcdef' }), reply({ lyric: encode('not a timed lyric') }),
        reply({ lyric: Buffer.from([0xff, 0xfe, 0xfd]).toString('base64') }),
    ]) {
        assert.equal(await read({ get: async () => response }, { uin: '0' }, { songmid: 'song1' }), null);
    }
    assert.equal(await read({ get: async () => { throw new Error('offline'); } }, { uin: '0' }, { songmid: 'song1' }), null);
});

test('invalid song input never reaches upstream', async () => {
    const axios = { get: async () => assert.fail('invalid input reached upstream') };
    for (const songmid of ['', '../song', 'song&trans=0', 'a'.repeat(65)]) {
        assert.equal(await read(axios, { uin: '0' }, { songmid }), null);
    }
});

test('concurrent lyric calls preserve the request-scoped QQ account', async () => {
    await Promise.all(Array.from({ length: 40 }, async (_, index) => {
        const session = sessions.parse(`uin=${10000 + index}; qqmusic_key=fixture-${index}`);
        await sessions.storage.run(session, async () => {
            const axios = { get: async (url, config) => {
                await new Promise(resolve => setImmediate(resolve));
                const request = sessions.decorate({ url, ...config });
                assert.equal(request.headers.Cookie, session.cookie);
                assert.equal(JSON.parse(request.params.data).comm.uin, session.uin);
                return reply({ lyric: encode('[00:01]Original'), trans: encode('[00:01]译文') });
            } };
            assert.ok((await read(axios, session, { songmid: 'song1' })).trans);
        });
    }));
    assert.equal(sessions.current().uin, '0');
});


test('word timing failure keeps line lyrics and translation', async () => {
    const result = await read({ get: async (_, config) => {
        const request = JSON.parse(config.params.data);
        if (request.lyric.param.qrc === 1) throw new Error('no QRC');
        return reply({ lyric: encode('[00:01]Original'), trans: encode('[00:01]译文') });
    } }, { uin: '0' }, { songmid: 'song1' });
    assert.equal(result.lyric, '[00:01]Original');
    assert.ok(result.trans);
    assert.equal(result.word_lyric, undefined);
});

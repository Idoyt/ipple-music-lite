const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./qq-library.cjs');
const sessions = require('./qq-session.cjs');

test('personal library requests use the isolated account and preserve paging', async () => {
    await Promise.all(Array.from({ length: 40 }, async (_, index) => {
        const uin = String(10000 + index);
        const session = sessions.parse(`uin=${uin}; qqmusic_key=token-${uin}`);
        await sessions.storage.run(session, async () => {
            const axios = { post: async (url, data, config) => {
                await new Promise(resolve => setImmediate(resolve));
                const request = sessions.decorate({ url, data, ...config });
                assert.equal(request.headers.Cookie, session.cookie);
                assert.equal(request.data.comm.uin, uin);
                assert.equal(request.data.comm.authst, `token-${uin}`);
                const operation = request.data.collection;
                if (operation.method === 'GetPlaylistByUin') {
                    assert.equal(operation.param.uin, uin);
                    return { data: { code: 0, collection: { code: 0, data: { v_playlist: [{ tid: uin }, { tid: 'other' }] } } } };
                }
                assert.equal(operation.param.dirid, 201);
                assert.equal(operation.param.disstid, 0);
                assert.equal(operation.param.song_begin, 50);
                assert.equal(operation.param.song_num, 50);
                assert.equal(operation.param.userinfo, true);
                return { data: { code: 0, collection: { code: 0, data: { songlist: [{ mid: `song-${uin}` }], total_song_num: 51 } } } };
            } };
            const playlists = await read(axios, session, { kind: 'playlists', offset: 0, limit: 1, uin: 'must-not-be-used' });
            assert.equal(playlists.items[0].tid, uin);
            assert.equal(playlists.has_more, true);
            const favorites = await read(axios, session, { kind: 'favorites', offset: 50, limit: 50 });
            assert.equal(favorites.items[0].mid, `song-${uin}`);
            assert.equal(favorites.has_more, false);
        });
    }));
});

test('playlist IDs are numeric RPC values; invalid and anonymous requests do not touch upstream', async () => {
    const session = sessions.parse('uin=12345; qm_keyst=fixture');
    let calls = 0;
    const axios = { post: async (_, data) => {
        calls++;
        assert.equal(data.collection.param.disstid, 456789);
        assert.equal(data.collection.param.dirid, 0);
        return { data: { code: 0, collection: { code: 0, data: { songlist: [], total_song_num: 0 } } } };
    } };
    const empty = await read(axios, session, { kind: 'playlist', playlist_id: '456789', limit: 50 });
    assert.equal(empty.total, 0);
    assert.equal(empty.has_more, false);
    await assert.rejects(read(axios, { cookie: '', uin: '0' }, { kind: 'favorites' }), error => error.state === 'expired');
    for (const playlist_id of ['bad', '0', '-1', '9999999999999999']) {
        await assert.rejects(read(axios, session, { kind: 'playlist', playlist_id }), error => error.state === 'invalid');
    }
    await assert.rejects(read(axios, session, { kind: 'favorites', limit: 101 }), error => error.state === 'invalid');
    assert.equal(calls, 1);
});

test('upstream failures and expired sessions are never presented as empty favorites', async () => {
    const session = sessions.parse('uin=12345; music_key=fixture');
    for (const data of [{}, { code: 0, collection: { code: 0, data: {} } }, { code: 0, collection: { code: 99 } }]) {
        await assert.rejects(read({ post: async () => ({ data }) }, session, { kind: 'favorites' }), error => error.state === 'unavailable');
    }
    await assert.rejects(read({ post: async () => ({ data: { code: 0, collection: { code: 0, data: { subcode: 1000 } } } }) }, session, { kind: 'favorites' }), error => error.state === 'expired');
});

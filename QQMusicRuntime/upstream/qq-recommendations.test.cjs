const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./qq-recommendations.cjs');
const sessions = require('./qq-session.cjs');
const now = () => new Date('2026-11-17T02:00:00Z');
const session = sessions.parse('uin=12345; qm_keyst=fixture');
const good = data => ({ data: { code: 0, recommendation: { code: 0, data } } });
const card = () => ({ subtype: 510, id: '123456789', time: Date.parse('2026-11-16T16:00:00Z') / 1000 });
const feed = cards => good({ retcode: 0, v_shelf: [{ v_niche: [{ v_card: cards }] }] });

test('initial previews request only three songs and stop after their first batch', async () => {
    let calls = 0;
    const axios = { post: async (_, body) => {
        calls++;
        assert.equal(body.recommendation.param.num, 3);
        return good({ tracks: Array.from({ length: 5 }, (_, i) => ({ mid: `song-${i}`, name: 'Song' })) });
    } };
    const result = await read(axios, session, { kind: 'guess_like', limit: 3 });
    assert.equal(result.items.length, 3);
    assert.equal(calls, 1);
});

test('concurrent recommendations use isolated sessions; bounded batches deduplicate in order', async () => {
    await Promise.all(Array.from({ length: 12 }, async (_, index) => {
        const current = sessions.parse(`uin=${10000 + index}; qm_keyst=key-${index}`);
        await sessions.storage.run(current, async () => {
            let calls = 0;
            const axios = { post: async (url, data, config) => {
                await new Promise(resolve => setImmediate(resolve));
                const request = sessions.decorate({ url, data, ...config });
                assert.equal(request.headers.Cookie, current.cookie);
                assert.equal(request.data.comm.uin, current.uin);
                assert.equal(request.data.comm.authst, current.key);
                assert.equal(data.recommendation.method, 'get_radio_track');
                calls++;
                return good({ tracks: [{ mid: `${current.uin}-repeat`, name: 'Song' }, ...Array.from({ length: 4 }, (_, i) => ({ mid: `${current.uin}-${calls}-${i}`, title: 'Song' }))] });
            } };
            const result = await read(axios, current, { kind: 'guess_like', limit: 20 });
            assert.equal(calls, 4);
            assert.equal(result.items.length, 17);
            assert.equal(new Set(result.items.map(t => t.mid)).size, 17);
            assert(result.items.every(t => t.mid.startsWith(current.uin)));
            assert.equal(result.has_more, false);
        });
    }));
});

test('no-growth recommendations stop; anonymous or invalid requests never reach QQ', async () => {
    let calls = 0;
    const axios = { post: async () => { calls++; return good({ tracks: [{ mid: 'same', name: 'Song' }] }); } };
    assert.equal((await read(axios, session, { kind: 'guess_like' })).items.length, 1);
    assert.equal(calls, 2);
    for (const query of [{ kind: 'wrong' }, { kind: 'guess_like', limit: 21 }, { kind: 'guess_like', offset: 1 }, { kind: 'daily', limit: 51 }])
        await assert.rejects(read(axios, session, query), e => e.state === 'invalid');
    await assert.rejects(read(axios, { uin: '0', cookie: '' }, { kind: 'daily' }), e => e.state === 'expired');
    assert.equal(calls, 2);
});

test('daily resolves the current Shanghai card and reads true playlist pages', async () => {
    let calls = 0;
    const axios = { post: async (_, body) => {
        const op = body.recommendation; calls++;
        if (op.method === 'get_recommend_feed') return feed([card()]);
        assert.equal(op.method, 'CgiGetDiss');
        assert.equal(op.param.disstid, 123456789);
        assert.equal(op.param.song_begin, 20);
        assert.equal(op.param.song_num, 20);
        return good({ code: 0, subcode: 0, total_song_num: 30, songlist: Array.from({ length: 10 }, (_, i) => ({ mid: `song-${i}`, name: 'Song' })) });
    } };
    const page = await read(axios, session, { kind: 'daily', offset: 20, limit: 20 }, now);
    assert.equal(page.date_key, '2026-11-17');
    assert.equal(page.items.length, 10);
    assert.equal(page.has_more, false);
    assert.equal(calls, 2);
});

test('daily rejects absent, ambiguous, yesterday or unsafe cards without fallback', async () => {
    for (const cards of [[], [card(), card()], [{ ...card(), time: 1 }], [{ ...card(), id: 'bad' }], [{ ...card(), id: '9999999999999999' }]]) {
        let calls = 0;
        await assert.rejects(read({ post: async () => { calls++; return feed(cards); } }, session, { kind: 'daily' }, now), e => e.state === 'unavailable');
        assert.equal(calls, 1);
    }
    let clock = 0;
    await assert.rejects(read({ post: async (_, body) => body.recommendation.method === 'get_recommend_feed' ? feed([card()]) : good({ total_song_num: 1, songlist: [{ mid: 'song' }] }) },
        session, { kind: 'daily' }, () => new Date(clock++ ? '2026-11-17T16:00:00Z' : '2026-11-17T15:59:59Z')), e => e.state === 'unavailable');
});

test('recommendation errors are not empty successes; signature errors are not account expiry', async () => {
    for (const code of [1000, 2000, 500020]) {
        await assert.rejects(read({ post: async () => ({ data: { code: 0, recommendation: { code } } }) }, session, { kind: 'guess_like' }),
            e => e.state === (code === 1000 ? 'expired' : 'unavailable'));
    }
    await assert.rejects(read({ post: async () => good({ tracks: [] }) }, session, { kind: 'guess_like' }), e => e.state === 'unavailable');
});

// Process-owned lifecycle around the pinned Rain120 dependency, not a business backend.
const { timingSafeEqual } = require('node:crypto');

async function guard(ctx, next) {
    const expected = Buffer.from(process.env.QQ_GATEWAY_KEY || '');
    const provided = Buffer.from(ctx.get('X-Ipple-QQ-Gateway-Key'));
    if (expected.length < 32 || provided.length !== expected.length || !timingSafeEqual(expected, provided)) {
        ctx.status = 401;
        ctx.body = { code: 'LOCAL_RUNTIME_AUTH_REQUIRED' };
        return;
    }
    await next();
}
exports.guard = guard;

exports.similarSongs = async (ctx, next) => {
    if (ctx.method !== 'GET' || ctx.path !== '/ipple/qq/similar-songs') return next();
    const songid = Number(ctx.query.songid);
    if (!Number.isSafeInteger(songid) || songid <= 0) {
        ctx.status = 400;
        return;
    }
    try {
        const response = await fetch('https://u.y.qq.com/cgi-bin/musicu.fcg', {
            method: 'POST',
            headers: { Referer: 'https://y.qq.com/', 'Content-Type': 'application/json' },
            body: JSON.stringify({
                comm: { ct: 24, cv: 4747474, platform: 'yqq.json', uin: '0', format: 'json' },
                req_0: { module: 'music.recommend.TrackRelationServer', method: 'GetSimilarSongs', param: { songid } },
            }),
            signal: AbortSignal.timeout(8000),
        });
        if (!response.ok) throw new Error('QQ request failed');
        const payload = await response.json();
        const block = payload.req_0;
        if (payload.code !== 0 || block?.code !== 0 || !block.data || (block.data.retcode ?? 0) !== 0) {
            throw new Error('QQ returned an error');
        }
        const { vecSong, vecSongNew } = block.data;
        const rows = Array.isArray(vecSong) ? vecSong : [];
        const groups = Array.isArray(vecSongNew) ? vecSongNew : [];
        const groupedRows = groups.flatMap(group => Array.isArray(group?.songs) ? group.songs : []);
        ctx.body = { items: [...rows, ...groupedRows].map(row => row?.track).filter(Boolean) };
    } catch {
        ctx.status = 502;
        ctx.body = { code: 'SOURCE_UNAVAILABLE' };
    }
};

if (require.main === module) {
    // Keep dependency logs away from the parent protocol; never print account credentials.
    console.log = () => {};
    console.warn = () => {};
    console.error = () => {};
    const app = require('./qq-music-api/app.js');
    const server = app.listen(0, '127.0.0.1', () => {
        process.stdout.write(`IPPLE_QQ_READY=${JSON.stringify({ port: server.address().port })}\n`);
    });
    const stop = () => {
        server.close(() => process.exit(0));
        setTimeout(() => process.exit(0), 1500).unref();
    };
    process.stdin.resume();
    process.stdin.once('end', stop);
    process.once('SIGTERM', stop);
    process.once('SIGINT', stop);
    server.on('error', () => process.exit(1));
}

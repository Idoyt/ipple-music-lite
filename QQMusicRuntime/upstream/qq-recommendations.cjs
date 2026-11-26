// Read-only recommendation RPCs. The account is supplied by the isolated gateway session.
class RecommendationFailure extends Error {
    constructor(state = 'unavailable') { super('QQ recommendations unavailable'); this.state = state; }
}
const shanghaiDay = date => new Intl.DateTimeFormat('sv-SE', {
    timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit',
}).format(date);

async function rpc(axios, session, module, method, param) {
    const response = await axios.post('https://u.y.qq.com/cgi-bin/musicu.fcg', {
        comm: { ct: 24, cv: 0, uin: session.uin, format: 'json' },
        recommendation: { module, method, param },
    }, { headers: { Referer: 'https://y.qq.com/', 'Content-Type': 'application/json' }, timeout: 8000 });
    const body = response.data;
    const block = body?.recommendation;
    const failed = [body?.code, block?.code, block?.data?.code, block?.data?.subcode, block?.data?.retcode]
        .find(value => value !== undefined && Number(value) !== 0);
    // 2000 can indicate a protocol/signature failure, rather than an expired account.
    if (failed !== undefined) throw new RecommendationFailure([301, 1000, 1001, 401, 403].includes(Number(failed)) ? 'expired' : 'unavailable');
    if (body?.code !== 0 || block?.code !== 0 || !block.data || typeof block.data !== 'object') throw new RecommendationFailure();
    return block.data;
}

async function read(axios, session, query, now = () => new Date()) {
    if (!session.cookie || session.uin === '0') throw new RecommendationFailure('expired');
    const offset = Number(query.offset || 0), limit = Number(query.limit || 20);
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > 10000 || !Number.isSafeInteger(limit) || limit < 1 || limit > 50)
        throw new RecommendationFailure('invalid');
    if (query.kind === 'guess_like') {
        if (offset !== 0 || limit > 20) throw new RecommendationFailure('invalid');
        const items = [], seen = new Set();
        for (let batch = 0; batch < 4 && items.length < limit; batch++) {
            const data = await rpc(axios, session, 'music.radioProxy.MbTrackRadioSvr', 'get_radio_track', {
                id: 99, num: limit - items.length, from: 0, scene: 0, song_ids: [], ext: { bluetooth: '' }, should_count_down: 1,
            });
            if (!Array.isArray(data.tracks)) throw new RecommendationFailure();
            const before = items.length;
            for (const track of data.tracks) {
                if (!track?.mid || !(track.title || track.name) || seen.has(track.mid)) continue;
                seen.add(track.mid);
                items.push(track);
                if (items.length === limit) break;
            }
            if (items.length === before) break;
        }
        if (!items.length) throw new RecommendationFailure();
        return { items, has_more: false };
    }
    if (query.kind !== 'daily') throw new RecommendationFailure('invalid');
    const dateKey = shanghaiDay(now());
    const feed = await rpc(axios, session, 'music.recommend.RecommendFeed', 'get_recommend_feed', {
        direction: 0, page: 1, v_cache: [], v_uniq: [], s_num: 0,
    });
    if (!Array.isArray(feed.v_shelf)) throw new RecommendationFailure();
    const cards = feed.v_shelf.flatMap(shelf => (shelf.v_niche || []).flatMap(niche => niche.v_card || []))
        .filter(card => Number(card.subtype) === 510);
    if (cards.length !== 1) throw new RecommendationFailure();
    const card = cards[0], id = Number(card.id), stamp = Number(card.time);
    if (!/^[1-9]\d*$/.test(String(card.id)) || !Number.isSafeInteger(id) || id <= 0
        || !Number.isFinite(stamp) || stamp <= 0 || stamp > 8.64e12
        || shanghaiDay(new Date(stamp * 1000)) !== dateKey) throw new RecommendationFailure();
    const data = await rpc(axios, session, 'music.srfDissInfo.DissInfo', 'CgiGetDiss', {
        disstid: id, dirid: 0, song_begin: offset, song_num: limit,
        tag: true, userinfo: true, orderlist: true, onlysonglist: false,
    });
    const total = Number(data.total_song_num ?? data.songlist_size);
    if (!Array.isArray(data.songlist) || data.songlist.length > limit || !Number.isSafeInteger(total)
        || total < 1 || total > 10000 || data.songlist.length !== Math.min(limit, Math.max(0, total - offset))
        || shanghaiDay(now()) !== dateKey) throw new RecommendationFailure();
    return { items: data.songlist, date_key: dateKey, has_more: offset + data.songlist.length < total };
}

module.exports = { read, shanghaiDay };

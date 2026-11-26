// Read-only personal collection operations. Identity always comes from the request session.
class LibraryFailure extends Error {
    constructor(state) { super('QQ personal collection unavailable'); this.state = state; }
}
async function rpc(axios, session, module, method, param) {
    const response = await axios.post('https://u.y.qq.com/cgi-bin/musicu.fcg', {
        comm: { ct: 24, cv: 0, uin: session.uin, format: 'json' },
        collection: { module, method, param },
    }, { headers: { Referer: 'https://y.qq.com/', 'Content-Type': 'application/json' }, timeout: 10000 });
    const body = response.data;
    const block = body?.collection;
    const code = [body?.code, block?.code, block?.data?.code, block?.data?.subcode].find(value => value !== undefined && Number(value) !== 0);
    if (code !== undefined) throw new LibraryFailure([301, 1000, 1001, 2000, 401, 403].includes(Number(code)) ? 'expired' : 'unavailable');
    if (Number(body?.code) !== 0 || Number(block?.code) !== 0 || !block.data || typeof block.data !== 'object') throw new LibraryFailure('unavailable');
    return block.data;
}
async function read(axios, session, query) {
    if (!session.cookie || session.uin === '0') throw new LibraryFailure('expired');
    const offset = Number(query.offset || 0);
    const limit = Number(query.limit || 50);
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > 100000 || !Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new LibraryFailure('invalid');
    if (query.kind === 'playlists') {
        const data = await rpc(axios, session, 'music.musicasset.PlaylistBaseRead', 'GetPlaylistByUin', { uin: session.uin });
        if (!Array.isArray(data.v_playlist) || data.v_playlist.length > 10000) throw new LibraryFailure('unavailable');
        return { items: data.v_playlist.slice(offset, offset + limit), total: data.v_playlist.length,
            has_more: offset + limit < data.v_playlist.length };
    }
    if (!['favorites', 'playlist'].includes(query.kind)) throw new LibraryFailure('invalid');
    const favorites = query.kind === 'favorites';
    const id = String(query.playlist_id || '');
    if (!favorites && (!/^[1-9]\d{0,15}$/.test(id) || !Number.isSafeInteger(Number(id)))) throw new LibraryFailure('invalid');
    const data = await rpc(axios, session, 'music.srfDissInfo.DissInfo', 'CgiGetDiss', {
        disstid: favorites ? 0 : Number(id), dirid: favorites ? 201 : 0,
        song_begin: offset, song_num: limit, tag: true, userinfo: true, orderlist: true, onlysonglist: false,
    });
    if (!Array.isArray(data.songlist)) throw new LibraryFailure('unavailable');
    const total = Number(data.total_song_num ?? data.songlist_size);
    if (!Number.isSafeInteger(total) || total < 0) throw new LibraryFailure('unavailable');
    return { items: data.songlist, playlist: data.dirinfo || {}, total, has_more: offset + data.songlist.length < total };
}
module.exports = { read, rpc, LibraryFailure };

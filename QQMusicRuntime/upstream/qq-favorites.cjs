const { LibraryFailure } = require(__filename.endsWith('.cjs') ? './qq-library.cjs' : './ipple-library');
const web = require(__filename.endsWith('.cjs') ? './qq-web.cjs' : './ipple-web');
const validMid = value => typeof value === 'string' && /^[A-Za-z0-9]{1,64}$/.test(value);
function envelope(session, method, module, param) {
    return { comm: { ct: 24, cv: 4747474, platform: 'yqq.json', uin: session.uin, authst: session.key,
        format: 'json', g_tk: session.gtk, g_tk_new_20200303: session.gtk,
        inCharset: 'utf-8', outCharset: 'utf-8', notice: 0, needNewCode: 1 },
        favorite: { module, method, param } };
}
async function rpc(axios, session, method, module, param, write = false) {
    const payload = envelope(session, method, module, param);
    const body = write ? await web.request(axios, session, payload) : (await axios.post('https://u.y.qq.com/cgi-bin/musicu.fcg', payload, {
        headers: { Referer: 'https://y.qq.com/', 'Content-Type': 'application/json' }, timeout: 10000, maxContentLength: 2 << 20,
    })).data;
    const block = body?.favorite, data = block?.data;
    const codes = [body?.code, block?.code, data?.code ?? 0, data?.subcode ?? 0, ...(write ? [data?.retCode] : [])];
    if (!data || codes.some(code => code === undefined || Number(code) !== 0)) {
        const code = codes.find(code => code === undefined || Number(code) !== 0);
        throw new LibraryFailure([301, 1000, 1001, 2000, 401, 403].includes(Number(code)) ? 'expired' : 'unavailable');
    }
    return data;
}
async function check(axios, session, ids) {
    if (!session.cookie || session.uin === '0') throw new LibraryFailure('expired');
    if (!Array.isArray(ids) || !ids.length || ids.length > 100 || !ids.every(validMid)) throw new LibraryFailure('invalid');
    const unique = [...new Set(ids)];
    const data = await rpc(axios, session, 'IsSongFanByMid', 'music.musicasset.SongFavRead', { v_songMid: unique });
    if (unique.some(id => typeof data.m_fan?.[id] !== 'boolean')) throw new LibraryFailure('unavailable');
    return { liked: Object.fromEntries(unique.map(id => [id, data.m_fan[id]])) };
}
async function set(axios, session, input) {
    if (!validMid(input?.track_id) || typeof input?.enabled !== 'boolean') throw new LibraryFailure('invalid');
    const id = input.track_id, enabled = input.enabled;
    const before = await check(axios, session, [id]);
    if (before.liked[id] === enabled) return before;
    // 数字 ID 和类型必须来自同一 MID 的官方详情，不能由调用方猜测或默认类型。
    const detail = (await rpc(axios, session, 'get_song_detail_yqq', 'music.pf_song_detail_svr', { song_mid: id })).track_info;
    if (detail?.mid !== id || !Number.isSafeInteger(detail.id) || detail.id <= 0 || !Number.isSafeInteger(detail.type) || detail.type < 0) throw new LibraryFailure('unavailable');
    await rpc(axios, session, enabled ? 'AddSonglist' : 'DelSonglist', 'music.musicasset.PlaylistDetailWrite', {
        dirId: 201, v_songInfo: [{ songId: detail.id, songType: detail.type }],
    }, true);
    const after = await check(axios, session, [id]);
    if (after.liked[id] !== enabled) throw new LibraryFailure('unavailable');
    return after;
}
module.exports = { check, set, validMid };

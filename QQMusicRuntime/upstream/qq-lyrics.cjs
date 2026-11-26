// Prefer the current QQ lyric RPC: the legacy CGI now often omits translations.
// Keep ordinary LRC/translation for compatibility; Go normalizes the optional encrypted QRC.
async function read(axios, session, query) {
    const songmid = String(query.songmid || '');
    if (!/^[A-Za-z0-9]{1,64}$/.test(songmid)) return null;
    const param = {
        songMid: songmid, crypt: 0, qrc: 0, trans: 1, roma: 0,
        lrc_t: 0, qrc_t: 0, trans_t: 0, roma_t: 0, type: 1, needSingingAnnotations: false,
    };
    const payload = {
        comm: { ct: 24, cv: 4747474, platform: 'yqq.json', format: 'json', uin: session.uin },
        lyric: { module: 'music.musichallSong.PlayLyricInfo', method: 'GetPlayLyricInfo', param },
    };
    const request = async qrc => {
        const data = { ...payload, lyric: { ...payload.lyric, param: { ...param, qrc, trans: qrc ? 0 : 1 } } };
        return axios.get('https://u.y.qq.com/cgi-bin/musicu.fcg', {
            params: { format: 'json', data: JSON.stringify(data) },
            headers: { Referer: 'https://y.qq.com/' }, timeout: 7000,
        });
    };
    try {
        const [normal, words] = await Promise.allSettled([request(0), request(1)]);
        if (normal.status !== 'fulfilled') return null;
        const response = normal.value;
        const body = response.data;
        const result = body?.lyric;
        const data = result?.data;
        if (body?.code !== 0 || result?.code !== 0 || data?.crypt !== 0 || typeof data.lyric !== 'string') return null;
        const raw = data.lyric.trim();
        if (!raw || raw.length > 1024 * 1024) return null;
        const lyric = raw.startsWith('[') ? raw : new TextDecoder('utf-8', { fatal: true }).decode(Buffer.from(raw, 'base64'));
        // A malformed or encrypted response must fall back rather than masquerading as lyric text.
        if (!/\[\d{1,4}:[0-5]?\d(?:[.:]\d{1,3})?\]/.test(lyric)) return null;
        const trans = typeof data.trans === 'string' && data.trans.length <= 1024 * 1024 ? data.trans : '';
        // Preserve Rain120's wire shape: original LRC decoded, translation decoded by the Go adapter.
        const resultBody = { code: 0, lyric, trans };
        if (words.status === 'fulfilled') {
            const wordBody = words.value.data;
            const wordData = wordBody?.lyric?.data;
            if (wordBody?.code === 0 && wordBody?.lyric?.code === 0 && wordData?.qrc === 1
                && typeof wordData.lyric === 'string' && wordData.lyric.length <= 512 * 1024) {
                resultBody.word_lyric = wordData.lyric;
            }
        }
        return resultBody;
    } catch (_) {
        // The legacy route remains usable when this RPC is temporarily unavailable.
        return null;
    }
}

module.exports = { read };

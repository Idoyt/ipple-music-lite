// zzc / ag-1 adapted from qmweb-sign (MIT, Copyright 2024 Jixun Wu).
// https://github.com/jixunmoe/qmweb-sign/tree/15305a3cc39f80eb1646ab2bae46468231765736
// Full license: qmweb-sign.LICENSE
const { createHash, createCipheriv, randomBytes } = require('node:crypto');
const requestKey = Buffer.from([189, 48, 95, 16, 208, 255, 116, 182, 239, 84, 218, 184, 53, 181, 225, 207]);
const responseKey = [122, 63, 140, 29, 94, 155, 47, 10, 108, 77, 126, 139, 31, 58, 92, 157, 14, 43, 111, 74, 129];
const scramble = [89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179];
function sign(body) {
    const hash = createHash('sha1').update(body).digest('hex').toUpperCase();
    const pick = indices => indices.map(index => hash[index]).join('');
    const middle = Buffer.from(scramble.map((value, index) => value ^ parseInt(hash.slice(index * 2, index * 2 + 2), 16))).toString('base64').replace(/[\/+=]/g, '');
    return `zzc${pick([23, 14, 6, 36, 16, 7, 19])}${middle}${pick([16, 1, 32, 12, 19, 27, 8, 5])}`.toLowerCase();
}
async function request(axios, session, payload) {
    // 必须先注入当前会话，再用同一份 JSON 签名和加密；禁止写失败后自动重试。
    payload.comm.uin = session.uin;
    payload.comm.authst = session.key;
    const body = JSON.stringify(payload), iv = randomBytes(12);
    const cipher = createCipheriv('aes-128-gcm', requestKey, iv);
    const encoded = Buffer.concat([iv, cipher.update(body, 'utf8'), cipher.final(), cipher.getAuthTag()]).toString('base64');
    const response = await axios.post('https://u6.y.qq.com/cgi-bin/musics.fcg', encoded, {
        params: { encoding: 'ag-1', sign: sign(body), _: Date.now() },
        headers: { Referer: 'https://y.qq.com/', 'Content-Type': 'text/plain', Accept: 'application/octet-stream' },
        responseType: 'arraybuffer', timeout: 10000, maxContentLength: 2 << 20,
    });
    const bytes = Buffer.from(response.data);
    for (let index = 0; index < bytes.length; index++) bytes[index] ^= responseKey[index % responseKey.length];
    return JSON.parse(bytes.toString('utf8'));
}
module.exports = { sign, request };

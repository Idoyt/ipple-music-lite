// Preserve QQ's advertised period verbatim (daily YYYY-MM-DD or weekly YYYY_WW).
// The pinned wrapper otherwise coerces every daily chart to a weekly period.
const fs = require('fs');
const path = require('path');
const target = path.join(process.argv[2] || '.', 'routers/context/getRanks.js');
const original = 'const period = `${year}_${week}`;';
const replacement = "const period = /^[0-9]{4}(?:-[0-9]{2}-[0-9]{2}|_[0-9]{1,2})$/.test(ctx.query.period || '') ? ctx.query.period : `${year}_${week}`;";
const input = fs.readFileSync(target, 'utf8');
if (!input.includes(original) && !input.includes(replacement)) throw new Error('Unrecognized pinned QQ rank implementation');
fs.writeFileSync(target, input.replace(original, replacement));

const root = process.argv[2] || '.';
function patch(relative, before, after) {
    const file = path.join(root, relative);
    const text = fs.readFileSync(file, 'utf8');
    if (text.includes(after)) return;
    if (!text.includes(before) && !text.includes(after)) throw new Error(`Unrecognized pinned QQ file: ${relative}`);
    fs.writeFileSync(file, text.replace(before, after));
}
fs.copyFileSync(path.join(__dirname, 'qq-session.cjs'), path.join(root, 'util/ipple-session.js'));
fs.copyFileSync(path.join(__dirname, 'qq-library.cjs'), path.join(root, 'util/ipple-library.js'));
fs.copyFileSync(path.join(__dirname, 'qq-lyrics.cjs'), path.join(root, 'util/ipple-lyrics.js'));
fs.copyFileSync(path.join(__dirname, 'qq-recommendations.cjs'), path.join(root, 'util/ipple-recommendations.js'));
fs.copyFileSync(path.join(__dirname, 'qq-favorites.cjs'), path.join(root, 'util/ipple-favorites.js'));
fs.copyFileSync(path.join(__dirname, 'qq-web.cjs'), path.join(root, 'util/ipple-web.js'));
fs.copyFileSync(path.join(__dirname, 'qmweb-sign.LICENSE'), path.join(root, 'util/qmweb-sign.LICENSE'));
patch('app.js', 'app.use(cookie());', "app.use(require('./util/ipple-session').middleware());");
patch('app.js', 'global = Object.assign({}, userInfo);', '// Ipple: credentials are request-scoped; ignore global user configuration.');
patch('util/request.js', "const axios = require('axios');", "const axios = require('axios');\nrequire('./ipple-session').install(axios);");
patch('routers/context/getMusicPlay.js', "const uin = global.uin || '0';", "const uin = require('../../util/ipple-session').current().uin;");
const config = path.join(root, 'module/config.js');
let configText = fs.readFileSync(config, 'utf8');
if (!configText.includes('Ipple request-scoped common parameters')) {
    configText = configText.replace(/const commonParams = \{[\s\S]*?\n\};/, `// Ipple request-scoped common parameters\nconst commonParams = { hostUin: 0, inCharset: 'utf8', outCharset: 'utf-8', notice: 0, platform: 'yqq.json', needNewCode: 0 };\nObject.defineProperties(commonParams, {\n  g_tk: { enumerable: true, get: () => require('../util/ipple-session').current().gtk },\n  loginUin: { enumerable: true, get: () => require('../util/ipple-session').current().uin },\n});`);
    fs.writeFileSync(config, configText);
}
for (const relative of ['module/apis/y_common.js', 'module/apis/u_common.js']) {
    const file = path.join(root, relative);
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace(/^.*console\.log\([^\n]*opts[^\n]*\n/gm, ''));
}

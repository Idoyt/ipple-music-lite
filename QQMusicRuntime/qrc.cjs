// QQ QRC compatibility; adapted from the existing WXRIW MIT port. See QRC-LICENSE.
const sboxes = [[14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],[15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,15,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],[10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],[7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,10,13,8,9,4,5,11,12,7,2,14],[2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],[12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],[4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],[13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11]];
const initialBits = [[57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7],[56,48,40,32,24,16,8,0,58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6]];
const permutation = [15,6,19,20,28,11,27,16,0,14,22,25,4,17,30,9,1,7,23,13,31,26,2,8,18,12,29,5,21,10,3,24];
const keyShifts = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1];
const keyC = [56,48,40,32,24,16,8,0,57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35];
const keyD = [62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,60,52,44,36,28,20,12,4,27,19,11,3];
const keyCompression = [13,16,10,23,0,4,2,27,14,5,20,9,22,18,11,3,25,7,15,6,26,19,12,1,40,51,30,36,46,54,29,39,50,44,32,47,43,48,38,55,33,52,45,41,49,35,28,31];

function bit(data, n) { return (data[Math.floor(n / 32) * 4 + 3 - Math.floor(n % 32 / 8)] >>> (7 - n % 8)) & 1; }
function schedule(key, decrypt) {
    let c = 0, d = 0;
    keyC.forEach((n, i) => c |= bit(key, n) << (31 - i));
    keyD.forEach((n, i) => d |= bit(key, n) << (31 - i));
    const result = Array.from({length:16}, () => new Uint8Array(6));
    keyShifts.forEach((shift, i) => {
        c = (c << shift | c >>> (28 - shift)) & 0xfffffff0;
        d = (d << shift | d >>> (28 - shift)) & 0xfffffff0;
        const round = decrypt ? 15 - i : i;
        keyCompression.forEach((n, j) => {
            const value = j >= 24 ? d : c;
            if (j >= 24) n -= 27;
            result[round][Math.floor(j / 8)] |= ((value >>> (31 - n)) & 1) << (7 - j % 8);
        });
    });
    return result;
}
function roundFunction(state, key) {
    let expanded = 0n;
    for (let group = 0; group < 8; group++) for (let n = 0; n < 6; n++) {
        const source = (group * 4 + n + 31) % 32;
        expanded = expanded << 1n | BigInt((state >>> (31 - source)) & 1);
    }
    key.forEach((value, i) => expanded ^= BigInt(value) << BigInt(40 - i * 8));
    let substituted = 0, result = 0;
    for (let i = 0; i < 8; i++) {
        const value = Number(expanded >> BigInt(42 - i * 6)) & 63;
        const index = value & 32 | (value & 31) >>> 1 | (value & 1) << 4;
        substituted = substituted << 4 | sboxes[i][index];
    }
    for (const n of permutation) result = result << 1 | (substituted >>> (31 - n)) & 1;
    return result >>> 0;
}
function block(input, keys) {
    let state = [0, 0];
    initialBits.forEach((bits, side) => bits.forEach((n, i) => state[side] |= bit(input, n) << (31 - i)));
    for (let i = 0; i < 15; i++) state = [state[1], state[0] ^ roundFunction(state[1], keys[i])];
    state[0] ^= roundFunction(state[1], keys[15]);
    const result = Buffer.alloc(8);
    initialBits.forEach((bits, side) => bits.forEach((n, i) => {
        result[Math.floor(n / 32) * 4 + 3 - Math.floor(n % 32 / 8)] |= ((state[side] >>> (31 - i)) & 1) << (7 - n % 8);
    }));
    return result;
}
const key = Buffer.from('!@#)(*$%123ZXC!@!@#)(NHL');
const keys = [schedule(key.subarray(16), true), schedule(key.subarray(8), false), schedule(key, true)];
function decrypt(input) {
    const result = Buffer.alloc(input.length);
    for (let i=0; i<input.length; i+=8) {
        let value = input.subarray(i,i+8);
        for (const schedule of keys) value = block(value, schedule);
        value.copy(result,i);
    }
    return result;
}
const maxTime = 48*60*60*1000;
const valid = n => Number.isSafeInteger(n) && n >= 0 && n <= maxTime;
function entities(text) {
    return text.replace(/&(#x[0-9a-f]+|#\d+|amp|quot|apos|lt|gt);/gi, (_, value) => {
        if (value[0] === '#') return String.fromCodePoint(value[1].toLowerCase() === 'x' ? parseInt(value.slice(2),16) : Number(value.slice(1)));
        return {amp:'&',quot:'"',apos:"'",lt:'<',gt:'>'}[value];
    });
}
function contentLines(content) {
    const offset = Number(content.match(/\[offset:\s*([+-]?\d+)\s*\]/i)?.[1] || 0);
    if (!Number.isSafeInteger(offset) || Math.abs(offset) > maxTime) return [];
    const lines = [...content.matchAll(/\[(\d+),(\d+)\]/g)];
    if (lines.length > 10000) return [];
    return lines.flatMap((match,index) => {
        const start = Number(match[1]), duration = Number(match[2]);
        if (!valid(start) || !valid(duration) || !valid(start+duration)) return [];
        const body = content.slice(match.index+match[0].length,lines[index+1]?.index ?? content.length).trim();
        const tags = [...body.matchAll(/\((\d+),(\d+)\)/g)];
        if (!tags.length || tags.length > 10000) return [];
        let previous = 0;
        const words=[];
        for (const tag of tags) {
            const begin=Number(tag[1]), length=Number(tag[2]);
            if (!valid(begin) || !valid(length) || !valid(begin+length)) return [];
            const start_ms=Math.max(begin-offset,0), end=Math.max(begin+length-offset,start_ms);
            if (words.length && start_ms < words[words.length-1].start_ms) return [];
            words.push({text:body.slice(previous,tag.index),start_ms,duration_ms:end-start_ms});
            previous=tag.index+tag[0].length;
        }
        words[words.length-1].text += body.slice(previous);
        const text=words.map(w=>w.text).join('');
        if (!text.trim()) return [];
        const start_ms=Math.max(start-offset,0);
        const end=Math.max(start+duration-offset,start_ms,...words.map(w=>w.start_ms+w.duration_ms));
        return [{text,start_ms,duration_ms:end-start_ms,words}];
    });
}
function decode(value) {
    try {
        if (typeof value !== 'string' || !value.trim() || value.length > 512*1024) return [];
        value=value.trim();
        let raw;
        if (value.startsWith('<')) raw=value;
        else {
            if (value.length%16 || !/^[0-9a-f]+$/i.test(value)) return [];
            raw=new TextDecoder('utf-8',{fatal:true}).decode(require('node:zlib').inflateSync(decrypt(Buffer.from(value,'hex')),{maxOutputLength:2*1024*1024}));
        }
        if (/<!/i.test(raw)) return [];
        const lines=[...raw.matchAll(/LyricContent\s*=\s*(["'])([\s\S]*?)\1/g)].flatMap(match=>contentLines(entities(match[2])));
        if (lines.length>10000) return [];
        return lines.sort((a,b)=>a.start_ms-b.start_ms);
    } catch (_) { return []; }
}
module.exports = { decode };

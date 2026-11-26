// Keep the Rain120 request/session layer; its legacy H5 comment route drops Pic and trial replies.
exports.read = async (UCommon, query) => {
    const id = String(query.id || '');
    const page = Number(query.pagenum || 0), limit = Number(query.pagesize || 20);
    const after = String(query.rootcommentid || '');
    if (!/^[1-9][0-9]{0,15}$/.test(id) || !Number.isSafeInteger(page) || page < 0 || page > 50000
        || !Number.isSafeInteger(limit) || limit < 1 || limit > 100
        || (page > 0 && !/^[0-9]{1,30}$/.test(after))) throw new Error('Invalid comment page');
    const result = await UCommon({ method: 'get', params: { format: 'json', data: {
        comm: { ct: 24, cv: 0, format: 'json' },
        comments: { module: 'music.globalComment.CommentRead', method: 'GetNewCommentList', param: {
            BizType: 1, BizId: id, PageSize: limit, PageNum: page,
            LastCommentSeqNo: after, PicEnable: 1,
        } },
    } }, option: {} });
    const block = result.data?.comments, data = block?.data, list = data?.CommentList;
    if (result.data?.code !== 0 || block?.code !== 0 || data?.SubCode !== 0 || !Array.isArray(list?.Comments)) {
        throw new Error('QQ comment response unavailable');
    }
    return { code: 0, comment: {
        commenttotal: list.Total, has_more: list.HasMore === 1,
        commentlist: list.Comments.map(row => ({
            commentid: row.CmId, rootcommentid: String(row.SeqNo || ''),
            rootcommentcontent: String(row.Content || '').replace(/\\n/g, '\n'),
            nick: row.Nick, time: row.PubTime, praisenum: row.PraiseNum,
            pics: [row.Pic, row.EmoPic].filter(value => typeof value === 'string' && value.length > 0),
        })),
    } };
};

import Foundation

public struct MusicAPIError: Swift.Error, LocalizedError, Sendable, Equatable {
    public let status: Int
    public let code: String
    public let requestID: String
    public let message: String
    public let syncResetCursor: String?
    public let syncResetRequired: Bool?
    public let syncCurrentVersion: Int64?

    public init(
        status: Int, code: String, requestID: String = "", message: String = "", syncResetCursor: String? = nil,
        syncResetRequired: Bool? = nil, syncCurrentVersion: Int64? = nil
    ) {
        self.status = status
        self.code = code
        self.requestID = requestID
        self.message = message
        self.syncResetCursor = syncResetCursor
        self.syncResetRequired = syncResetRequired
        self.syncCurrentVersion = syncCurrentVersion
    }

    public var errorDescription: String? {
        switch code {
        case "SESSION_STORE_UNAVAILABLE": "无法读取系统钥匙串中的登录会话，请解锁钥匙串后重试。"
        case "INVALID_SERVER_URL": "服务器地址需使用 HTTPS；HTTP 仅允许本机回环地址。"
        case "UNSAFE_MEDIA_URL": "服务器返回的媒体地址不安全，已停止加载。"
        case "INVALID_RESPONSE": "服务器返回了无法识别的数据。"
        case "NETWORK_ERROR": "无法连接服务器，请检查网络和服务器地址。"
        case "CANCELLED": "请求已取消。"
        case "CSRF_INVALID": "会话验证已失效，请重新登录。"
        case "QQ_LOGIN_REQUIRED": "请使用 QQ 音乐官方扫码登录。"
        case "QQ_RUNTIME_UNAVAILABLE": "无法启动随附的 QQ 音乐接口组件，请重新安装或重新构建应用。"
        case "QQ_LOGIN_EXPIRED": "QQ 登录已过期，请重新扫码。"
        case "QQ_LOGIN_UNAVAILABLE": "暂时无法验证 QQ 登录，请稍后重试。"
        case "QQ_IDENTITY_CONFLICT": "QQ 账号关联存在冲突，请稍后重试；若持续发生，请检查历史绑定。"
        case "SESSION_LIMIT": "活跃设备已达上限，请先在其他设备的「我的」中撤销旧设备。"
        case "INVALID_CREDENTIALS": "用户名或密码错误。"
        case "USERNAME_TAKEN": "该用户名已被使用。"
        case "REGISTRATION_CLOSED": "服务器尚未开放注册，请联系管理员建立账户。"
        case "QQ_SESSION_SHARED_SOURCE": "此音乐源已分享，请先取消分享再绑定 QQ 账号。"
        case "QQ_SESSION_PRIVATE_SOURCE": "已绑定 QQ 账号的音乐源不能分享，请先解绑。"
        case "SOURCE_CREDENTIALS", "SOURCE_AUTH_REQUIRED": "音乐源登录已失效或凭据无效，请重新登录音乐源。"
        case "SOURCE_UNSUPPORTED": "此音乐源暂不支持这项操作。"
        default:
            switch status {
            case 400, 422: "提交的信息不符合要求，请检查输入。"
            case 401: "登录已失效，请重新登录。"
            case 403: "当前账户没有执行此操作的权限。"
            case 404: "请求的内容不存在或已被移除。"
            case 409: "内容已在其他位置更新，请刷新后重试。"
            case 410: "同步记录已过期，正在重新加载资料库。"
            case 429: "操作过于频繁，请稍后重试。"
            case 500...599: "服务器暂时无法完成请求，请稍后重试。"
            default: "请求未能完成，请稍后重试。"
            }
        }
    }
}

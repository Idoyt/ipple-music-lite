import Foundation

public enum QQCommentPart: Equatable, Sendable {
    case text(String)
    case emoji(code: String, url: URL)
    case image(URL)
}

public enum QQCommentContent {
    private static let markup = try? NSRegularExpression(
        pattern: #"\[em\](e[0-9]{1,12})\[/em\]|\[(?:img|pic)\]([^\[]+)\[/(?:img|pic)\]"#,
        options: .caseInsensitive)
    public static func mediaURL(_ raw: String) -> URL? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "&amp;", with: "&")
        guard var parts = URLComponents(string: raw.hasPrefix("//") ? "https:" + raw : raw),
              ["http", "https"].contains(parts.scheme), let host = parts.host?.lowercased(),
              ["qpic.y.qq.com", "music-file.y.qq.com"].contains(host) || ["gtimg.cn", "qpic.cn"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        parts.scheme = "https"
        return parts.url
    }

    public static func parse(_ text: String) -> [QQCommentPart] {
        guard let regex = markup else { return [.text(text)] }
        let ns = text as NSString
        var result: [QQCommentPart] = [], position = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > position {
                result.append(.text(ns.substring(with: NSRange(location: position, length: match.range.location - position))))
            }
            if match.range(at: 1).location != NSNotFound {
                let code = ns.substring(with: match.range(at: 1)).lowercased()
                result.append(.emoji(code: code, url: URL(string: "https://y.gtimg.cn/mediastyle/global/emoji/img/\(code).png")!))
            } else if let url = mediaURL(ns.substring(with: match.range(at: 2))) {
                result.append(.image(url))
            } else { result.append(.text(ns.substring(with: match.range))) }
            position = NSMaxRange(match.range)
        }
        if position < ns.length { result.append(.text(ns.substring(from: position))) }
        return result
    }

    static func images(in row: JSONValue) -> [URL] {
        var images: [URL] = []
        func append(_ value: JSONValue) {
            switch value {
            case .string(let raw): if let url = mediaURL(raw), !images.contains(url) { images.append(url) }
            case .array(let items): items.prefix(9).forEach(append)
            case .object: append(value.first("url", "picurl", "pic_url", "image_url", "origin_url"))
            default: break
            }
        }
        for key in ["pic", "pics", "picurl", "pic_url", "images", "piclist", "pic_list", "image_list"] { append(row[key]) }
        return Array(images.prefix(9))
    }
}

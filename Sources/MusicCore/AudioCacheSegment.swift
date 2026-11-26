import Foundation

public enum AudioCacheSlot: String, Sendable { case prefix, interrupted }

/// Absolute byte ranges preserve the source timeline; these bytes are never treated as a standalone song.
public struct AudioCacheSegment: Codable, Sendable, Equatable {
    public let offset: Int64
    public let totalLength: Int64
    public let contentType: String
    public let validator: String?
    public let data: Data
    public init(offset: Int64, totalLength: Int64, contentType: String, validator: String?, data: Data) {
        self.offset = offset
        self.totalLength = totalLength
        self.contentType = contentType
        self.validator = validator
        self.data = data
    }
    public var isValid: Bool {
        offset >= 0 && totalLength > 0 && offset < totalLength && !data.isEmpty
            && data.count <= 32 * 1_024 * 1_024 && Int64(data.count) <= totalLength - offset
            && (contentType.hasPrefix("audio/")
                || ["application/ogg", "application/octet-stream"].contains(contentType))
    }
    public func matches(_ other: AudioCacheSegment) -> Bool {
        totalLength == other.totalLength && contentType == other.contentType
            && (validator == nil || other.validator == nil || validator == other.validator)
    }
}

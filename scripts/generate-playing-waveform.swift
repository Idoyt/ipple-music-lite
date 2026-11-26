// Run on macOS: xcrun swift scripts/generate-playing-waveform.swift <output.gif>
// Four independently moving, rounded bars reproduce the original playing indicator.
// Only this requested animated asset is rasterized; all other interface icons remain SF Symbols.
import CoreGraphics
import Foundation

let width = 34
let height = 36
let frameCount = 48
let output = CommandLine.arguments.dropFirst().first ?? "Sources/IppleMusicMac/Resources/PlayingWaveform.gif"
guard
    let bitmap = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
    let pixels = bitmap.data?.assumingMemoryBound(to: UInt8.self)
else { fatalError("cannot create waveform bitmap") }
var gif = Data("GIF89a".utf8)
func word(_ value: Int) {
    gif.append(UInt8(value & 255))
    gif.append(UInt8((value >> 8) & 255))
}
word(width)
word(height)
gif.append(contentsOf: [0xF0, 0, 0, 0, 0, 0, 255, 255, 255])
gif.append(contentsOf: [0x21, 0xFF, 11])
gif.append(Data("NETSCAPE2.0".utf8))
gif.append(contentsOf: [3, 1, 0, 0, 0])
for frame in 0..<frameCount {
    bitmap.clear(CGRect(x: 0, y: 0, width: width, height: height))
    let phase = Double(frame) * 2 * .pi / Double(frameCount)
    bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
    for index in 0..<4 {
        let offset = Double(index) * 1.45
        let energy = (sin(phase + offset) + 0.5 * sin(2 * phase - offset) + 1.5) / 3
        let barHeight = CGFloat(6 + energy * 25)
        let rect = CGRect(x: CGFloat(1 + index * 9), y: (CGFloat(height) - barHeight) / 2, width: 5, height: barHeight)
        bitmap.addPath(CGPath(roundedRect: rect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        bitmap.fillPath()
    }
    let indices = (0..<(width * height)).map { pixels[$0 * 4 + 3] >= 100 ? UInt8(1) : UInt8(0) }
    // Disposal=restore background ensures shorter bars cannot leave previous-frame trails.
    gif.append(contentsOf: [0x21, 0xF9, 4, 0x09, 4, 0, 0, 0, 0x2C])
    word(0)
    word(0)
    word(width)
    word(height)
    gif.append(0)
    // Reset LZW every two pixels: constant 3-bit codes, tiny deterministic two-colour asset.
    var compressed = Data()
    var accumulator: UInt32 = 0
    var bits = 0
    func code(_ value: UInt8) {
        accumulator |= UInt32(value) << bits
        bits += 3
        while bits >= 8 {
            compressed.append(UInt8(accumulator & 255))
            accumulator >>= 8
            bits -= 8
        }
    }
    for i in stride(from: 0, to: indices.count, by: 2) {
        code(4)
        code(indices[i])
        if i + 1 < indices.count { code(indices[i + 1]) }
    }
    code(5)
    if bits > 0 { compressed.append(UInt8(accumulator & 255)) }
    gif.append(2)
    for i in stride(from: 0, to: compressed.count, by: 255) {
        let length = min(255, compressed.count - i)
        gif.append(UInt8(length))
        gif.append(compressed[i..<(i + length)])
    }
    gif.append(0)
}
gif.append(0x3B)
try gif.write(to: URL(fileURLWithPath: output), options: .atomic)
print("Generated \(frameCount)-frame \(width)×\(height) waveform GIF (\(gif.count) bytes, 4 rounded bars)")

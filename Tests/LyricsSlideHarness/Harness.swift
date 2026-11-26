import AppKit
import SwiftUI
import QuartzCore

// The motion container only needs an equatable content revision, independent of music data.
enum PlaybackLyricsContent: Equatable { case loading }

@main @MainActor struct Harness {
    static func main() {
        _ = NSApplication.shared
        for width: CGFloat in [800, 1_200] {
            let surface = PlaybackLyricsSlideSurface(content: Text("歌词").frame(maxWidth: .infinity, maxHeight: .infinity))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = surface
            surface.layoutSubtreeIfNeeded()
            surface.configure(reservedWidth: 0, isPresented: true, animate: true)
            let initialCenter = surface.displayedCenterX
            let count = surface.layoutCount
            let reserved = min(400, width * 0.38) + 1
            surface.configure(reservedWidth: reserved, isPresented: true, animate: true)
            let slide = surface.host.layer!.animation(forKey: "lyrics-comment-slide") as! CABasicAnimation
            precondition(slide.duration == 0.32 && (slide.fromValue as! CGFloat) > 0)
            precondition(abs(surface.host.frame.midX + (slide.fromValue as! CGFloat) - initialCenter) < 0.5)
            precondition(surface.layoutCount == count + 1)
            for _ in 0..<60 {
                surface.configure(reservedWidth: reserved, isPresented: true, animate: true)
                surface.layoutSubtreeIfNeeded()
            }
            precondition(surface.layoutCount == count + 1, "motion/unchanged updates must not reflow lyric layout")
            let visibleCenter = surface.displayedCenterX
            surface.configure(reservedWidth: 0, isPresented: true, animate: true)
            if let reverse = surface.host.layer!.animation(forKey: "lyrics-comment-slide") as? CABasicAnimation {
                precondition(abs(surface.host.frame.midX + (reverse.fromValue as! CGFloat) - visibleCenter) < 0.5)
            } else {
                precondition(abs(surface.host.frame.midX - visibleCenter) < 0.5)
            }
            surface.configure(reservedWidth: reserved, isPresented: true, animate: false)
            precondition(surface.host.layer!.animationKeys() == nil)
            precondition(abs(surface.host.frame.midX - (width - reserved) / 2) < 0.5)
            surface.configure(reservedWidth: 0, isPresented: false, animate: true)
            precondition(surface.host.layer!.animationKeys() == nil)
            surface.removeFromSuperview()
        }
        print("PASS lyric slide starts at visible center, lays out once, reverses continuously, and respects hidden/reduced motion")
    }
}

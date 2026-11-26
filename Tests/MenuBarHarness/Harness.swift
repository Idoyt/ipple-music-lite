import AppKit
import Darwin
import MusicCore

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}

@main @MainActor
private struct Harness {
    static func main() throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let timeline = LyricsTimeline(lrc: "[00:01]第一句\n[00:03]Second line\n[00:05]\n[00:07]最后一句")
        try require(
            MenuBarPlaybackState.title(timeline: nil, position: 0, trackTitle: nil) == "Ipple Music",
            "empty playback has no fallback")
        try require(
            MenuBarPlaybackState.title(timeline: timeline, position: 0, trackTitle: "测试歌曲") == "测试歌曲",
            "intro lost track title")
        try require(
            MenuBarPlaybackState.title(timeline: timeline, position: 2, trackTitle: "测试歌曲") == "第一句",
            "active lyric mismatch")
        try require(
            MenuBarPlaybackState.title(timeline: timeline, position: 4, trackTitle: "测试歌曲") == "Second line",
            "lyric did not advance")
        try require(
            MenuBarPlaybackState.title(timeline: timeline, position: 6, trackTitle: "测试歌曲") == "Second line",
            "instrumental gap cleared the most recently started lyric")
        try require(
            MenuBarPlaybackState.title(timeline: timeline, position: 1.5, trackTitle: "测试歌曲") == "第一句",
            "backward seek failed")
        print("PASS menu-bar lyrics advance at line starts, hold through gaps and seek backwards")

        let status = NSStatusBar.system.statusItem(withLength: AppSettings.defaultMenuBarWidth)
        defer { NSStatusBar.system.removeStatusItem(status) }
        var pointer = NSPoint(x: -10_000, y: -10_000)
        let item = MenuBarPlaybackItem(reduceMotion: { false }, pointerLocation: { pointer })
        defer { item.stop() }
        item.install(in: status)
        advance(0.3)
        let button = item.button
        guard let window = button.window else {
            throw Failure(description: "system status item has no native button window")
        }
        try require(
            window.isVisible && status.isVisible && button.bounds.width == 160 && button.bounds.height > 0,
            "native status item has invalid window or dimensions")
        try require(status.view === button, "animated status item is not using its own root view")
        try requireMonochromeAppSymbol(button)
        var calls: [String] = []
        item.onPrevious = { calls.append("previous") }
        item.onToggle = { calls.append("toggle") }
        item.onNext = { calls.append("next") }
        item.onFavorite = { calls.append("favorite") }
        item.onShowWindow = { calls.append("window") }
        button.performClick(nil)
        try require(calls.isEmpty, "a root action outside the control triggered a command")
        let idleActions = button.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        try require(
            idleActions.count == 1 && idleActions[0].accessibilityIdentifier() == "menubar.open",
            "the app button is not accessible while lyrics are shown")
        func hover(_ inside: Bool) throws {
            let local = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
            pointer =
                inside
                ? window.convertPoint(toScreen: button.convert(local, to: nil))
                : NSPoint(x: -10_000, y: -10_000)
            guard
                let event = NSEvent.mouseEvent(
                    with: .mouseMoved, location: button.convert(local, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
            else { throw Failure(description: "could not construct native mouse movement") }
            NSApplication.shared.sendEvent(event)
            try require(item.isHovered == inside, "native mouse-move monitor did not change hover state")
        }
        try hover(true)
        func click(from start: NSPoint, to end: NSPoint? = nil, right: Bool = false, reportedAt: NSPoint? = nil)
            throws
        {
            func send(_ type: NSEvent.EventType, at point: NSPoint) throws {
                pointer = window.convertPoint(toScreen: button.convert(point, to: nil))
                guard
                    let event = NSEvent.mouseEvent(
                        with: type, location: button.convert(reportedAt ?? point, to: nil), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
                else { throw Failure(description: "could not create native button mouse event") }
                NSApplication.shared.sendEvent(event)
            }
            try send(right ? .rightMouseDown : .leftMouseDown, at: start)
            try send(right ? .rightMouseUp : .leftMouseUp, at: end ?? start)
        }
        try click(from: NSPoint(x: button.appSymbolRect.midX, y: button.appSymbolRect.midY))
        try require(calls == ["window"], "clicking the app icon did not restore the window")
        calls = []
        let emptyActions = button.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        try require(
            emptyActions.count == 5 && emptyActions.prefix(4).allSatisfy { !$0.isAccessibilityEnabled() }
                && emptyActions[4].isAccessibilityEnabled(),
            "empty playback did not leave only the app button enabled")
        let state = MenuBarPlaybackState(title: "系统菜单栏集成歌词", isPlaying: true, isLoading: false, hasTrack: true)
        item.configure(state)
        let initialUpdates = item.presentationUpdates
        for _ in 0..<1000 { item.configure(state) }
        try require(item.presentationUpdates == initialUpdates, "unchanged progress rebuilt the native status button")
        let actions = button.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        try require(
            actions.map { $0.accessibilityLabel() } == ["上一首", "暂停", "下一首", "收藏", "打开 Ipple Music"]
                && button.transportImage?.isTemplate == true,
            "hover failed to expose accessible system-symbol controls")
        for index in 0..<4 {
            let rect = item.transportRect(at: index)
            try click(from: NSPoint(x: rect.midX, y: rect.midY))
        }
        try require(
            calls == ["previous", "toggle", "next", "favorite"],
            "native mouse down/up dispatched incorrect transport actions")
        calls = []
        // The system replica sometimes delivers only the root control action.
        func performReplicaClick(at point: NSPoint) {
            pointer = window.convertPoint(toScreen: button.convert(point, to: nil))
            button.performClick(nil)
        }
        for index in 0..<4 {
            let rect = item.transportRect(at: index)
            performReplicaClick(at: NSPoint(x: rect.midX, y: rect.midY))
        }
        try require(
            calls == ["previous", "toggle", "next", "favorite"],
            "replica action did not distinguish the four controls")
        calls = []
        performReplicaClick(at: NSPoint(x: item.transportRect(at: 0).minX - 2, y: button.bounds.midY))
        try require(calls.isEmpty, "replica click in empty space invoked a transport action")
        performReplicaClick(at: NSPoint(x: button.appSymbolRect.midX, y: button.appSymbolRect.midY))
        try require(calls == ["window"], "replica app symbol click did not open the main window")
        calls = []
        let replicaPoint = item.transportRect(at: 2)
        pointer = window.convertPoint(
            toScreen: button.convert(
                NSPoint(x: replicaPoint.midX, y: replicaPoint.midY), to: nil))
        guard
            let replicaDown = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 9000, y: 9000), modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
            let replicaUp = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: NSPoint(x: 9000, y: 9000), modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        else { throw Failure(description: "could not create remote replica events") }
        button.mouseDown(with: replicaDown)
        button.mouseUp(with: replicaUp)
        try require(calls == ["next"], "foreign-window replica event used the wrong coordinate space")
        calls = []
        let previous = item.transportRect(at: 0)
        let next = item.transportRect(at: 2)
        try click(from: NSPoint(x: previous.midX, y: previous.midY), to: NSPoint(x: next.midX, y: next.midY))
        try require(calls.isEmpty, "dragging between transport controls activated the wrong command")
        // The status item's own window can receive a retargeted click at its center for any control.
        let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        try require(next.contains(center), "centered click fixture no longer targets Next")
        let rects = (0..<4).map(item.transportRect(at:)) + [button.appSymbolRect]
        for rect in rects {
            try click(from: NSPoint(x: rect.midX, y: rect.midY), reportedAt: center)
        }
        try require(
            calls == ["previous", "toggle", "next", "favorite", "window"],
            "retargeted center clicks must follow the actual pointer: \(calls)")
        calls = []
        try click(from: NSPoint(x: previous.minX - 2, y: previous.midY), reportedAt: center)
        try click(
            from: NSPoint(x: previous.midX, y: previous.midY),
            to: NSPoint(x: next.midX, y: next.midY), reportedAt: center)
        try require(calls.isEmpty, "retargeted click in a gap or across controls invoked an action")
        pointer = NSPoint(x: -10_000, y: -10_000)
        button.performClick(nil)
        try require(calls.isEmpty, "root activation outside the item invoked an action")
        calls = []
        item.onContextMenu = { _ in calls.append("context") }
        try click(from: NSPoint(x: next.midX, y: next.midY), right: true)
        try require(calls == ["context"], "right click activated a transport command")
        item.onContextMenu = nil
        calls = []
        for action in actions { try require(action.accessibilityPerformPress(), "accessible transport action failed") }
        try require(
            calls == ["previous", "toggle", "next", "favorite", "window"],
            "accessible controls did not invoke their own actions")
        calls = []
        try hover(false)
        try require(
            !item.isHovered && button.transportImage == nil && button.title.isEmpty
                && button.lyricText == state.title,
            "hover exit failed to restore the cached lyric title")
        try click(from: NSPoint(x: next.midX, y: next.midY))
        try require(calls.isEmpty, "clicking a lyric triggered a hidden transport control")
        try requireTitlePixels(button)
        print("PASS five distinct menu-bar targets dispatch correctly using native, replica and accessibility actions")

        try hover(true)
        item.configure(
            .init(
                title: state.title, isPlaying: true, isLoading: false, hasTrack: true, isFavorite: true,
                isFavoriteUpdating: true))
        let pendingFavorites = button.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        try require(
            pendingFavorites.count == 5 && pendingFavorites[3].accessibilityLabel() == "取消收藏"
                && pendingFavorites[3].accessibilityValue() as? String == "已收藏"
                && !pendingFavorites[3].isAccessibilityEnabled()
                && pendingFavorites[0].isAccessibilityEnabled() && pendingFavorites[2].isAccessibilityEnabled(),
            "pending favorite disabled playback or lost its confirmed state")
        calls = []
        let heart = item.transportRect(at: 3)
        try click(from: NSPoint(x: heart.midX, y: heart.midY))
        try require(calls.isEmpty, "pending favorite dispatched a duplicate mutation")
        item.configure(.init(title: state.title, isPlaying: false, isLoading: true, hasTrack: true))
        let buffering = button.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        try require(
            buffering[3].isAccessibilityEnabled() && !buffering[0].isAccessibilityEnabled()
                && buffering[1].isAccessibilityEnabled() && !buffering[2].isAccessibilityEnabled(),
            "buffering mixed favorite and transport availability")
        try click(from: NSPoint(x: heart.midX, y: heart.midY))
        try require(calls == ["favorite"], "favorite command dispatched a transport action")
        calls = []
        try hover(false)
        print("PASS favorite toggles dispatch independently, expose confirmed state and reject duplicate clicks")

        item.configure(.init(title: "暂停的歌词", isPlaying: false, isLoading: false, hasTrack: true))
        try hover(true)
        try require(
            actions[1].accessibilityLabel() == "播放" && actions[1].isAccessibilityEnabled(),
            "paused playback cannot resume")
        item.configure(.init(title: "缓冲中", isPlaying: false, isLoading: true, hasTrack: true))
        try require(
            actions[1].isAccessibilityEnabled() && !actions[0].isAccessibilityEnabled()
                && !actions[2].isAccessibilityEnabled(), "buffering did not retain pause and disable navigation")
        try require(actions[1].accessibilityLabel() == "暂停", "buffering pause action is incorrect")
        item.configure(
            .init(title: String(repeating: "很长的歌词 ", count: 100), isPlaying: true, isLoading: false, hasTrack: true))
        try hover(false)
        advance(0.1)
        try require(status.length == 160 && button.bounds.width == 160, "long lyrics expanded the menu-bar item")
        print("PASS paused, buffering, and long-lyric states preserve controls and fixed menu width")

        item.configure(state)
        advance(0.3)
        try measureSteadyState(item, label: "lyrics")
        try hover(true)
        advance(0.3)
        try measureSteadyState(item, label: "hover controls")
        print("PASS stable native status item stays idle without custom subtree redraws")
        try hover(false)
        let longTitle = "这是用于验证菜单栏长歌词平滑滚动与暂停恢复的一整句测试歌词"
        item.configure(.init(title: longTitle, isPlaying: true, isLoading: false, hasTrack: true))
        try require(
            item.isScrolling && button.hasMarquee && button.transportImage == nil, "long playing lyric did not start scrolling")
        advance(0.15)
        let glyphBuilds = button.glyphBuilds
        let renderPasses = button.renderPasses
        let cpuStart = processCPUTime()
        let start = Date()
        advance(3)
        let cpu = 100 * (processCPUTime() - cpuStart) / Date().timeIntervalSince(start)
        try require(item.scrollOffset > 1, "Core Animation marquee did not visibly advance")
        try require(button.glyphBuilds == glyphBuilds, "scrolling rerasterized glyphs during animation")
        try require(button.renderPasses == renderPasses, "scrolling kept redrawing the AppKit view")
        try require(button.subviews.isEmpty, "marquee installed a custom status-item subtree")
        print(
            String(
                format: "INFO real NSStatusItem Core Animation scrolling 3s CPU %.2f%%, glyph builds %d", cpu,
                button.glyphBuilds - glyphBuilds)
        )
        try require(cpu < 8, "scrolling native status item consumes excessive CPU: \(cpu)%")
        item.configure(.init(title: longTitle, isPlaying: false, isLoading: false, hasTrack: true))
        advance(0.1)
        let pausedOffset = item.scrollOffset
        let pausedImage = button.transportImage
        let pausedBuilds = button.glyphBuilds
        let pausedRenders = button.renderPasses
        advance(0.3)
        try require(
            !item.isScrolling && abs(item.scrollOffset - pausedOffset) < 0.01 && button.glyphBuilds == pausedBuilds,
            "paused lyric retained a timer or moved")
        try require(button.transportImage === pausedImage, "paused lyric rebuilt its image")
        try require(button.renderPasses == pausedRenders, "paused lyric kept refreshing the view")
        item.configure(.init(title: longTitle, isPlaying: true, isLoading: false, hasTrack: true))
        advance(0.2)
        try require(
            item.isScrolling && item.scrollOffset > pausedOffset, "resume restarted or failed to continue the lyric")
        status.isVisible = false
        advance(0.05)
        try require(!item.isScrolling, "removed menu-bar item kept a scrolling timer")
        status.isVisible = true
        advance(0.1)
        try require(item.isScrolling, "restored menu-bar item failed to resume scrolling")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        try require(!item.isScrolling, "sleeping screen kept a scrolling timer")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try require(item.isScrolling, "waking screen failed to resume scrolling")
        try hover(true)
        try require(
            button.transportImage?.size == button.transportCanvasRect.size && button.accessibilityChildren()?.count == 5,
            "hovering scrolling lyrics did not replace them with the four playback controls")
        advance(0.1)
        let hoverOffset = item.scrollOffset
        let hoverBuilds = button.glyphBuilds
        advance(0.2)
        try require(
            !item.isScrolling && abs(item.scrollOffset - hoverOffset) < 0.01 && button.glyphBuilds == hoverBuilds,
            "hover retained a marquee timer or overwrote controls with a lyric frame")
        try hover(false)
        try require(
            item.isScrolling && button.hasMarquee && button.transportImage == nil,
            "leaving scrolling lyrics did not restore the cached text and animation")
        item.configure(.init(title: "新的短句", isPlaying: true, isLoading: false, hasTrack: true))
        try require(
            !item.isScrolling && button.transportImage == nil && button.title.isEmpty && button.lyricText == "新的短句",
            "short lyric retained scrolling")
        item.configure(.init(title: longTitle, isPlaying: true, isLoading: true, hasTrack: true))
        try require(!item.isScrolling && item.scrollOffset == 0, "new or buffering lyric failed to reset and stop")

        for (requestedWidth, width) in [(140.0, 140.0), (210.0, 210.0), (480.0, 240.0), (160.0, 160.0)] {
            item.setWidth(requestedWidth)
            advance(0.1)
            try require(
                status.length == width && button.bounds.width == width,
                "configured width did not constrain the entire status item")
            try hover(true)
            item.configure(state)
            calls = []
            for rect in (0..<4).map({ item.transportRect(at: $0) }) + [button.appSymbolRect] {
                try require(button.bounds.contains(rect), "width clipped a menu-bar hit target")
                try click(from: renderedGlyphCenter(in: rect, of: button))
            }
            try require(
                calls == ["previous", "toggle", "next", "favorite", "window"],
                "visible glyphs did not match their actions after resizing")
            let first = item.transportRect(at: 0)
            let middle = item.transportRect(at: 1)
            let penultimate = item.transportRect(at: 2)
            let last = item.transportRect(at: 3)
            try require(button.appSymbolRect.maxX == width - 4, "app icon is not trailing aligned")
            try require(
                last.maxX == button.appSymbolRect.minX - 4 && first.width == 24
                    && middle.minX - first.maxX == 4 && penultimate.minX - middle.maxX == 4
                    && last.minX - penultimate.maxX == 4,
                "transport controls are not compact and trailing aligned")
            try require(
                button.transportImage?.size.width == width - 16,
                "resizing reused a control canvas from another width")
            try hover(false)
        }
        let naturalWidth = ceil(
            NSAttributedString(string: longTitle, attributes: [.font: NSFont.menuBarFont(ofSize: 12)]).size().width + 2)
        for width in [140.0, 240.0] {
            item.setWidth(width)
            item.configure(.init(title: longTitle, isPlaying: false, isLoading: false, hasTrack: true))
            button.layoutSubtreeIfNeeded()
            guard let clip = button.layer?.sublayers?.first(where: { $0.sublayers?.first?.mask != nil }),
                let ink = clip.sublayers?.first, let mask = ink.mask
            else { throw Failure(description: "long lyric lost its clipping and glyph layers") }
            try require(
                clip.frame.maxX == button.appSymbolRect.minX - 6 && clip.bounds.width == width - 38
                    && ink.bounds.width > clip.bounds.width && ink.position.x == 0,
                "long lyric content was squeezed into its viewport")
            try require(
                abs(ink.bounds.width - naturalWidth) <= 1 && mask.bounds.width == ink.bounds.width,
                "viewport changed natural glyph dimensions")
            try require(
                mask.contentsGravity == .left,
                "glyph mask scales to fit rather than drawing at its native width")
        }
        print("PASS configured widths clip natural-width lyrics and preserve control click targets")

        for name in ["backward.end", "play", "pause", "forward.end", "heart", "heart.fill"] {
            guard
                let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            else { throw Failure(description: "missing linear system symbol \(name)") }
            let box = NSRect(x: 0, y: 0, width: 16, height: 14)
            let fitted = MenuBarPlaybackItem.fittedSymbolRect(size: symbol.size, box: box)
            try require(
                box.contains(fitted)
                    && abs(fitted.width / fitted.height - symbol.size.width / symbol.size.height) < 0.0001,
                "linear system symbol was stretched")
        }
        print("PASS linear SF Symbols retain their native aspect ratios within control bounds")
        item.stop()
        print(
            "PASS bounded cached marquee freezes on pause/hover and resumes without jumping; short and buffering lyrics stop"
        )

        let reducedStatus = NSStatusBar.system.statusItem(withLength: 236)
        defer { NSStatusBar.system.removeStatusItem(reducedStatus) }
        let reducedItem = MenuBarPlaybackItem(reduceMotion: { true })
        defer { reducedItem.stop() }
        reducedItem.install(in: reducedStatus)
        reducedItem.configure(.init(title: longTitle, isPlaying: true, isLoading: false, hasTrack: true))
        advance(0.1)
        try require(
            !reducedItem.isScrolling && reducedItem.button.title.isEmpty && reducedItem.button.lyricText == longTitle,
            "reduced motion did not retain static cached lyrics")
        print("PASS reduced motion keeps long lyrics static without an animation timer")
        try requireConsistentTypography()
        print("PASS short, scrolling, reduced-motion and extreme lyrics share consistent cached typography at 1x/2x")
        try requireLyricStartUpdates()
        print("PASS empty cues and word endings retain the last started lyric without extra presentation updates")
        try requireTimedWordScrolling()
        print("PASS word timings drive finite scrolling, gap holds, exact seeking, hover catch-up and frozen pause")
        try requireRepeatedCueRefresh()
        print(
            "PASS identical lyric text at later cues resets its scrolling origin without rasterizing again"
        )
        print("Menu bar regression harness: 13/13 passed")
    }

    static func requireTimedWordScrolling() throws {
        let text = String(repeating: "一二三四五六七八九十", count: 6)
        let segment = String(repeating: "一二三四五六七八九十", count: 2)
        let timeline = LyricsTimeline(
            lrc: "[00:10]\(text)\n[00:20]下一句",
            lines: [
                SourceLyricLine(
                    text: text, startMS: 10000, durationMS: 8000,
                    words: [
                        .init(text: segment, startMS: 10000, durationMS: 1000),
                        .init(text: segment, startMS: 13000, durationMS: 1000),
                        .init(text: segment, startMS: 14000, durationMS: 4000),
                    ])
            ])
        let indexed = MenuBarLyricTimeline(timeline)
        let lyric = indexed.presentation(at: 11)!
        let status = NSStatusBar.system.statusItem(withLength: 140)
        defer { NSStatusBar.system.removeStatusItem(status) }
        let item = MenuBarPlaybackItem(reduceMotion: { false }, pointerLocation: { NSPoint(x: -10000, y: -10000) })
        item.install(in: status)
        defer { item.stop() }
        advance(0.05)
        let width = item.button.lyricViewportWidth
        let marquee = MenuBarLyricMarquee(
            text: text, viewportWidth: width, scale: item.button.window?.backingScaleFactor ?? 2)!
        let plan = MenuBarLyricScrollPlan(lyric: lyric, marquee: marquee)
        try require(lyric.words.count == 3 && plan.duration == 8, "menu bar lost word timings or vocal end")
        try require(plan.offset(at: 11) == plan.offset(at: 12.5), "instrumental word gap continued scrolling")
        try require(
            plan.offset(at: 13.5) > plan.offset(at: 13) && plan.offset(at: 13.5) < plan.offset(at: 14),
            "word duration did not control intermediate positions")
        try require(plan.offset(at: 18) == plan.offset(at: 19.9), "completed lyric bounced back before the next cue")
        func configure(_ playing: Bool) {
            item.configure(.init(title: lyric.text, isPlaying: playing, isLoading: false, hasTrack: true, lyric: lyric))
        }
        configure(false)
        item.synchronizePlayback(position: 13.5)
        advance(0.05)
        try require(
            abs(item.scrollOffset - plan.offset(at: 13.5)) < 2,
            "paused seek did not place the active word in view: \(item.scrollOffset) vs \(plan.offset(at: 13.5))")
        let builds = item.button.glyphBuilds
        configure(true)
        item.synchronizePlayback(position: 13.5)
        advance(0.2)
        try require(
            item.isScrolling && abs(item.scrollOffset - plan.offset(at: 13.7)) < 8,
            "native animation is not aligned to playback time")
        configure(false)
        item.synchronizePlayback(position: 13.7)
        advance(0.05)
        let pausedOffset = item.scrollOffset
        let renders = item.button.renderPasses
        advance(0.2)
        try require(
            !item.isScrolling && abs(item.scrollOffset - pausedOffset) < 0.1 && item.button.renderPasses == renders,
            "paused timed lyric kept moving or drawing")
        configure(true)
        item.synchronizePlayback(position: 14)
        item.setHovered(true)
        item.synchronizePlayback(position: 15)
        advance(0.2)
        try require(!item.isScrolling, "hover retained timed lyric animation")
        item.setHovered(false)
        advance(0.05)
        try require(abs(item.scrollOffset - plan.offset(at: 15.25)) < 8, "hover exit resumed stale word position")
        try require(item.button.glyphBuilds == builds, "word progress rerasterized cached glyphs")
        item.synchronizePlayback(position: 14)
        advance(0.05)
        let timedRenders = item.button.renderPasses
        try measureSteadyState(item, label: "word-timed scrolling")
        try require(
            item.button.glyphBuilds == builds && item.button.renderPasses == timedRenders,
            "word-timed animation redrew the root or rebuilt text during playback")
        configure(false)
        item.synchronizePlayback(position: 12)
        advance(0.05)
        try require(abs(item.scrollOffset - plan.offset(at: 12)) < 2, "backward seek retained a future word")
        let plain = MenuBarLyricPresentation(cueID: 1, time: 10, endTime: 20, text: text, words: [])
        let fallback = MenuBarLyricScrollPlan(lyric: plain, marquee: marquee)
        try require(
            abs(fallback.offset(at: 15) - marquee.maxOffset / 2) < 0.1,
            "line-only lyrics did not use bounded line-time progress")
    }

    static func requireRepeatedCueRefresh() throws {
        let text = String(repeating: "重复歌词保持字形和字体一致", count: 5)
        let timeline = MenuBarLyricTimeline(LyricsTimeline(lrc: "[00:01]\(text)\n[00:03]\(text)\n[00:05]新歌词"))
        let first = timeline.presentation(at: 1)!
        let second = timeline.presentation(at: 3)!
        try require(
            first.text == second.text && first.cueID != second.cueID, "repeated text lost distinct cue identity")
        let status = NSStatusBar.system.statusItem(withLength: 236)
        defer { NSStatusBar.system.removeStatusItem(status) }
        let item = MenuBarPlaybackItem(reduceMotion: { false }, pointerLocation: { NSPoint(x: -10000, y: -10000) })
        item.install(in: status)
        advance(0.05)
        defer { item.stop() }
        item.configure(.init(title: first.text, isPlaying: false, isLoading: false, hasTrack: true, lyric: first))
        item.synchronizePlayback(position: 2)
        advance(0.05)
        try require(item.scrollOffset > 10, "repeated cue fixture did not reach its first scrolling position")
        let builds = item.button.glyphBuilds
        let updates = item.presentationUpdates
        item.configure(.init(title: second.text, isPlaying: false, isLoading: false, hasTrack: true, lyric: second))
        item.synchronizePlayback(position: 3)
        advance(0.05)
        try require(
            item.presentationUpdates == updates + 1 && item.state?.lyric?.cueID == second.cueID
                && abs(item.scrollOffset) < 1, "identical next cue kept the previous lyric's scrolling position")
        try require(item.button.glyphBuilds == builds, "repeated cue unnecessarily rerasterized identical text")
        try require(
            timeline.startTimes == [1, 3, 5],
            "lyric boundary scheduling skipped repeated lines")

        // Four short, identical cues from the reported chorus fit in the viewport.
        let repeatStarts = [165_829, 169_669, 173_637, 178_021]
        let short = "Highway to hell"
        let repeatedChorus = MenuBarLyricTimeline(LyricsTimeline(
            lrc: "[02:45.82][02:49.66][02:53.63][02:58.02]\(short)",
            lines: repeatStarts.map { start in
                SourceLyricLine(
                    text: short, startMS: Int64(start), durationMS: 2_000,
                    words: [.init(text: short, startMS: Int64(start), durationMS: 2_000)])
            }))
        let clip = item.button.layer?.sublayers?.first(where: { $0.sublayers?.first?.mask != nil })
        guard let fill = clip?.sublayers?.first?.sublayers?.first else {
            throw Failure(description: "missing timed lyric fill layer")
        }
        for (index, start) in repeatStarts.enumerated() {
            let position = Double(start) / 1000
            guard let lyric = repeatedChorus.presentation(at: position), lyric.cueID == index else {
                throw Failure(description: "short repeated chorus skipped a cue")
            }
            item.configure(.init(title: lyric.text, isPlaying: false, isLoading: false, hasTrack: true, lyric: lyric))
            item.synchronizePlayback(position: position)
            advance(0.05)
            try require(
                !item.button.hasMarquee && (fill.presentation()?.bounds.width ?? .infinity) < 3,
                "short repeated cue kept the fill from the previous occurrence")
            item.synchronizePlayback(position: position + 1)
            advance(0.05)
            try require(
                (fill.presentation()?.bounds.width ?? 0) > 20,
                "short repeated cue did not advance its fill with media time")
        }
    }

    static func requireLyricStartUpdates() throws {
        let raw = LyricsTimeline(lrc: "[00:00]\n[00:01]第一句\n[00:03]第二句\n[00:05]\n[00:06]  \n[00:07]第三句")
        let indexed = MenuBarLyricTimeline(raw)
        try require(indexed.title(at: 0, trackTitle: "歌名") == "歌名", "intro with empty cues lost track fallback")
        for position in [3.0, 4.999, 5.0, 6.0, 6.999] {
            try require(
                indexed.title(at: position, trackTitle: "歌名") == "第二句",
                "line end or blank cue cleared the prior menu-bar lyric")
        }
        try require(indexed.title(at: 7, trackTitle: "歌名") == "第三句", "next line did not begin at its timestamp")
        try require(indexed.title(at: 1.5, trackTitle: "歌名") == "第一句", "backward seek retained a future lyric")
        try require(indexed.title(at: 0.5, trackTitle: "歌名") == "歌名", "seek before the first lyric retained stale text")
        try require(
            raw.activeCue(at: 6)?.text.isEmpty == true, "menu-bar behavior changed detail-page empty cue semantics")

        let words = LyricsTimeline(
            lrc: "[00:01]字级歌词\n[00:02]\n[00:09]\n[00:10]下一句",
            lines: [
                SourceLyricLine(
                    text: "字级歌词", startMS: 1000, durationMS: 1000,
                    words: [
                        SourceLyricWord(text: "字级", startMS: 1000, durationMS: 500),
                        SourceLyricWord(text: "歌词", startMS: 1500, durationMS: 500),
                    ])
            ])
        try require(words.cues.first?.words.count == 2, "word-ending fixture did not attach word timing")
        let wordIndex = MenuBarLyricTimeline(words)
        for position in [1.999, 2.0, 2.001, 9.0, 9.999] {
            try require(
                wordIndex.title(at: position, trackTitle: "歌名") == "字级歌词",
                "word duration end or subsequent blank cue cleared the lyric")
        }
        try require(wordIndex.title(at: 10, trackTitle: "歌名") == "下一句", "word-timed next line started incorrectly")
        try require(
            wordIndex.title(at: 2.5, trackTitle: "歌名") == "字级歌词", "initialization mid-gap lost its preceding lyric")
        let newSong = MenuBarLyricTimeline(LyricsTimeline(lrc: "[00:15]新歌歌词"))
        try require(newSong.title(at: 2.5, trackTitle: "新歌") == "新歌", "new track reused another song's lyric")
        let advanced = MenuBarLyricTimeline(LyricsTimeline(lrc: "[offset:1500]\n[00:01]提前句\n[00:03]\n[00:05]下一句"))
        try require(
            advanced.title(at: 0, trackTitle: "歌名") == "提前句", "initialization ignored advanced negative-time lyric")

        let item = MenuBarPlaybackItem(reduceMotion: { false })
        defer { item.stop() }
        func configure(_ position: Double) {
            item.configure(
                .init(
                    title: indexed.title(at: position, trackTitle: "歌名"), isPlaying: true, isLoading: false,
                    hasTrack: true))
        }
        configure(0)
        let updates = item.presentationUpdates
        let builds = item.button.glyphBuilds
        for tick in 1...80 { configure(Double(tick) / 10) }
        try require(
            item.presentationUpdates - updates == 3 && item.button.glyphBuilds - builds == 3,
            "progress or empty cues updated native presentation between lyric starts")
    }

    static func measureSteadyState(_ item: MenuBarPlaybackItem, label: String) throws {
        let initialUpdates = item.presentationUpdates
        let cpuStart = processCPUTime()
        let start = Date()
        advance(3)
        let cpu = 100 * (processCPUTime() - cpuStart) / Date().timeIntervalSince(start)
        try require(item.presentationUpdates == initialUpdates, "steady-state fixture changed playback presentation")
        print(
            String(
                format: "INFO real NSStatusItem %@ steady state 3s CPU %.2f%%, fixed-state updates %d", label, cpu,
                item.presentationUpdates - initialUpdates))
        try require(cpu < 15, "fixed native status item consumes excessive CPU: \(cpu)%")
    }

    static func renderedGlyphCenter(in rect: NSRect, of button: MenuBarMarqueeButton) throws -> NSPoint {
        guard let bitmap = button.bitmapImageRepForCachingDisplay(in: rect) else {
            throw Failure(description: "could not capture the menu-bar button")
        }
        button.cacheDisplay(in: rect, to: bitmap)
        var count = 0
        var xTotal = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.35 {
                count += 1
                xTotal += x
            }
        }
        try require(count > 0, "menu-bar target has no rendered icon")
        let x = rect.minX + (CGFloat(xTotal) / CGFloat(count) + 0.5) * rect.width / CGFloat(bitmap.pixelsWide)
        try require(abs(x - rect.midX) < 4, "rendered icon is offset from its hit target")
        return NSPoint(x: x, y: rect.midY)
    }

    static func requireMonochromeAppSymbol(_ button: MenuBarMarqueeButton) throws {
        let previous = button.appearance
        defer { button.appearance = previous }
        let rect = button.appSymbolRect
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = NSAppearance(named: appearance)
            guard let bitmap = button.bitmapImageRepForCachingDisplay(in: rect) else {
                throw Failure(description: "could not capture the menu-bar app symbol")
            }
            button.cacheDisplay(in: rect, to: bitmap)
            var filledPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                        color.alphaComponent > 0.5
                    else { continue }
                    try require(
                        abs(color.redComponent - color.blueComponent) < 0.03
                            && abs(color.greenComponent - color.blueComponent) < 0.03,
                        "menu-bar app symbol has a colored fill")
                    let brightness = color.redComponent
                    if appearance == .aqua ? brightness < 0.3 : brightness > 0.7 { filledPixels += 1 }
                }
            }
            let coverage = Double(filledPixels) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
            try require(
                coverage > 0.10 && coverage < 0.25,
                "filled menu-bar ribbon has unexpected coverage for \(appearance.rawValue): \(coverage)")
        }
    }

    static func requireTitlePixels(_ button: MenuBarMarqueeButton) throws {
        advance(0.05)
        button.layoutSubtreeIfNeeded()
        guard button.title.isEmpty,
            let clip = button.layer?.sublayers?.first(where: { $0.sublayers?.first?.mask != nil }), !clip.isHidden,
            let ink = clip.sublayers?.first, let contents = ink.mask?.contents
        else { throw Failure(description: "cached lyric glyphs are not attached and visible") }
        let image = contents as! CGImage
        let bitmap = NSBitmapImageRep(cgImage: image)
        var nonempty = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 { nonempty += 1 }
            }
        }
        try require(nonempty > 5, "static cached lyric produced a blank glyph mask")
        if ink.bounds.width < clip.bounds.width {
            try require(
                abs(ink.position.x + ink.bounds.width - clip.bounds.width) <= 1,
                "short cached lyric lost trailing alignment")
            try require(ink.animationKeys()?.isEmpty != false, "short lyric installed a scrolling animation")
        }
    }

    static func requireConsistentTypography() throws {
        let text = "统一字体 Font 字体样式保持一致 🎵"
        for scale: CGFloat in [1, 2] {
            guard let wide = MenuBarLyricMarquee(text: text, viewportWidth: 400, scale: scale),
                let scrolling = MenuBarLyricMarquee(text: text, viewportWidth: 100, scale: scale),
                let reducedShort = MenuBarLyricMarquee(
                    text: text, viewportWidth: 400, scale: scale, truncatesToViewport: true),
                let reducedLong = MenuBarLyricMarquee(
                    text: text, viewportWidth: 100, scale: scale, truncatesToViewport: true)
            else { throw Failure(description: "typography fixture failed to build glyphs") }
            try require(
                wide.maxOffset == 0 && scrolling.maxOffset > 0 && reducedLong.maxOffset == 0,
                "static, scrolling or reduced-motion layout selected the wrong behavior")
            try require(
                wide.image.width == scrolling.image.width && wide.image.height == scrolling.image.height,
                "viewport changed natural glyph dimensions")
            let bytes = wide.image.dataProvider!.data! as Data
            try require(
                bytes == (scrolling.image.dataProvider!.data! as Data)
                    && bytes == (reducedShort.image.dataProvider!.data! as Data),
                "identical lyrics changed glyph pixels between static, scrolling and reduced-motion modes")
            let normal = NSBitmapImageRep(cgImage: wide.image)
            let truncated = NSBitmapImageRep(cgImage: reducedLong.image)
            for y in 0..<normal.pixelsHigh {
                for x in 0..<Int(24 * scale) {
                    try require(
                        normal.colorAt(x: x, y: y) == truncated.colorAt(x: x, y: y),
                        "truncating the line changed its prefix font or baseline")
                }
            }
            try require(reducedLong.image.width <= Int(100 * scale), "reduced-motion ellipsis exceeds viewport")
        }
        guard
            let enormous = MenuBarLyricMarquee(
                text: String(repeating: "极长歌词 ", count: 10_000), viewportWidth: 220, scale: 2)
        else { throw Failure(description: "extreme lyrics fell back to native cell typography") }
        try require(
            enormous.image.width <= 65_536 && enormous.maxOffset > 0,
            "extreme lyric texture escaped its memory bound")
    }

    static func advance(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    static func processCPUTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

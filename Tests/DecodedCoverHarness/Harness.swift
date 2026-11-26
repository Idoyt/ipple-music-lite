import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private struct Failure: Error, CustomStringConvertible { var description: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}

@MainActor private final class ImageResult {
    let image: DecodedCoverBitmap?
    init(_ image: DecodedCoverBitmap?) { self.image = image }
}

@MainActor private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@main @MainActor private enum Harness {
    static func main() async throws {
        let fixture = try fixtureData()
        let cache = DecodedCoverCache(entryLimit: 4)
        let key = DecodedCoverCache.Identity(
            origin: "local", accountID: "a", sourceID: "qq", sourceVersion: 1, coverID: "album", revision: 0)
        var loads = 0
        let loader: @MainActor () async throws -> Data = {
            loads += 1
            try await Task.sleep(for: .milliseconds(10))
            return fixture
        }
        let a = Task { ImageResult(await cache.image(for: key, maximumPixelSize: 640, load: loader)) }
        let b = Task { ImageResult(await cache.image(for: key, maximumPixelSize: 640, load: loader)) }
        let first = await a.value.image
        let second = await b.value.image
        try require(first != nil && first === second && loads == 1, "concurrent users decoded different cover images")
        let again = await cache.image(for: key, maximumPixelSize: 640, load: loader)
        try require(again === first && loads == 1, "a retained cover was decoded again")
        print("PASS playback, recommendation and repeated consumers share one decoded image and one request")

        let small = await cache.image(for: key, maximumPixelSize: 72, load: loader)
        try require(
            small !== first && small?.cgImage.width == 72 && small?.cgImage.height == 72,
            "list cover retained the large pixels")
        let blur = await cache.blurredImage(for: key, original: first!)
        let sameBlur = await cache.blurredImage(for: key, original: first!)
        try require(
            blur != nil && blur === sameBlur && blur!.cgImage.width <= 256, "preblurred background was not shared")
        let policyCache = DecodedCoverCache()
        let deferred = await policyCache.image(for: key, maximumPixelSize: 72, timing: .onDisplay, load: loader)
        let ready = await policyCache.image(for: key, maximumPixelSize: 72, timing: .immediate, load: loader)
        let deferredAgain = await policyCache.image(for: key, maximumPixelSize: 72, timing: .onDisplay, load: loader)
        try require(
            !DecodedCoverCache.DecodeTiming.onDisplay.cachesImmediately
                && DecodedCoverCache.DecodeTiming.immediate.cachesImmediately
                && deferred != nil && ready != nil && deferred !== ready && deferred === deferredAgain,
            "deferred list covers used immediate playback decoding or could not share matching images")
        print("PASS bounded list/background sizes and separate deferred/immediate decoding policies")

        let retina = await cache.image(for: key, maximumPixelSize: 72, timing: .onDisplay, load: loader)
        let retinaAgain = await cache.image(for: key, maximumPixelSize: 72, timing: .onDisplay, load: loader)
        let smallRenderer = ImageRenderer(
            content: Image(decorative: retina!.cgImage, scale: 1).resizable().frame(width: 36, height: 36))
        smallRenderer.scale = 2
        let largeRenderer = ImageRenderer(
            content: Image(decorative: retina!.cgImage, scale: 1).resizable().frame(width: 48, height: 48))
        largeRenderer.scale = 2
        try require(
            retina === retinaAgain && retina?.cgImage.width == 72
                && smallRenderer.cgImage?.width == 72 && largeRenderer.cgImage?.width == 96,
            "sharing pixels changed Retina layout size or created a second cached image")
        print("PASS one immutable bitmap renders at independent Retina display sizes")

        var account = key
        account.accountID = "b"
        let otherAccount = await cache.image(for: account, maximumPixelSize: 640, load: loader)
        var epoch = key
        epoch.revision += 1
        let afterClear = await cache.image(for: epoch, maximumPixelSize: 640, load: loader)
        var source = key
        source.sourceVersion += 1
        let afterSourceChange = await cache.image(for: source, maximumPixelSize: 640, load: loader)
        try require(
            otherAccount != nil && afterClear != nil && afterSourceChange != nil
                && otherAccount !== first && afterClear !== first && afterSourceChange !== first,
            "account, cache clear or source version reused stale pixels")
        try require(cache.indexedImageCount <= 4, "the weak metadata index grew beyond its bound")
        print("PASS account, source version and cache epoch isolation with a bounded sharing index")

        let canceledCache = DecodedCoverCache()
        var concurrentLoads = 0
        let pending: @MainActor () async throws -> Data = {
            concurrentLoads += 1
            try await Task.sleep(for: .milliseconds(20))
            return fixture
        }
        let canceled = Task { ImageResult(await canceledCache.image(for: key, maximumPixelSize: 72, load: pending)) }
        let survivor = Task { ImageResult(await canceledCache.image(for: key, maximumPixelSize: 72, load: pending)) }
        try await Task.sleep(for: .milliseconds(5))
        canceled.cancel()
        let cancelledImage = await canceled.value.image
        let survivingImage = await survivor.value.image
        try require(
            cancelledImage == nil && survivingImage != nil && concurrentLoads == 1,
            "canceling one user canceled the shared preload")
        print("PASS canceling a view does not cancel another view's cover or preload")

        let abandonedCache = DecodedCoverCache()
        var beganLoading = false
        var loaderCancelled = false
        let abandoned = Task {
            ImageResult(
                await abandonedCache.image(for: key, maximumPixelSize: 72) {
                    beganLoading = true
                    do { try await Task.sleep(for: .seconds(1)) } catch {
                        loaderCancelled = true
                        throw error
                    }
                    return fixture
                })
        }
        try await waitUntil { beganLoading }
        abandoned.cancel()
        let abandonedImage = await abandoned.value.image
        try require(
            abandonedImage == nil && loaderCancelled, "the last canceled consumer left its network loader running")
        print("PASS the last canceled consumer cancels its shared loader")

        let replacementCache = DecodedCoverCache()
        let oldGate = Gate()
        let newGate = Gate()
        var oldStarted = false
        var oldCancelled = false
        var newStarted = false
        let oldRequest = Task {
            ImageResult(
                await replacementCache.image(for: key, maximumPixelSize: 72) {
                    oldStarted = true
                    do { try await Task.sleep(for: .seconds(1)) } catch {
                        oldCancelled = true
                        // Model a loader whose response arrives late despite cancellation.
                        await oldGate.wait()
                    }
                    return fixture
                })
        }
        try await waitUntil { oldStarted }
        oldRequest.cancel()
        let newRequest = Task {
            ImageResult(
                await replacementCache.image(for: key, maximumPixelSize: 72) {
                    newStarted = true
                    await newGate.wait()
                    return fixture
                })
        }
        try await waitUntil { oldCancelled && newStarted }
        oldGate.open()
        let oldImage = await oldRequest.value.image
        newGate.open()
        let replacementImage = await newRequest.value.image
        let replacementAgain = await replacementCache.image(for: key, maximumPixelSize: 72) {
            throw Failure(description: "replacement request was removed")
        }
        try require(
            oldImage == nil && replacementImage != nil && replacementImage === replacementAgain,
            "an old request's late cancellation removed or canceled the new request")
        print("PASS old cancellation and late completion preserve the new same-key request")

        for _ in 0..<48 {
            let handoffCache = DecodedCoverCache()
            var handoffStarted = false
            let handoffLoader: @MainActor () async throws -> Data = {
                handoffStarted = true
                try await Task.sleep(for: .milliseconds(2))
                return fixture
            }
            let retiring = Task {
                ImageResult(await handoffCache.image(for: key, maximumPixelSize: 72, load: handoffLoader))
            }
            try await waitUntil { handoffStarted }
            // Cancellation can remove the final old consumer on any thread while the main actor joins a new one.
            let cancellation = Task.detached { retiring.cancel() }
            let replacement = await handoffCache.image(for: key, maximumPixelSize: 72, load: handoffLoader)
            await cancellation.value
            _ = await retiring.value
            try require(replacement != nil, "a live consumer joined an abandoned decode during cancellation handoff")
        }
        print("PASS concurrent last-consumer cancellation never drops a new live consumer")

        let resetCache = DecodedCoverCache()
        let obsolete = Task { ImageResult(await resetCache.image(for: key, maximumPixelSize: 72, load: pending)) }
        try await Task.sleep(for: .milliseconds(5))
        resetCache.reset()
        let fresh = await resetCache.image(for: key, maximumPixelSize: 72) { fixture }
        let obsoleteImage = await obsolete.value.image
        let retained = await resetCache.image(for: key, maximumPixelSize: 72) {
            throw Failure(description: "unexpected reload")
        }
        try require(
            obsoleteImage == nil && fresh != nil && fresh === retained,
            "reset allowed an obsolete request to replace the new image")
        print("PASS invalidation cancels stale work without replacing a new image")

        let weakCache = DecodedCoverCache()
        weak var witness: DecodedCoverBitmap?
        func loadTemporary() async {
            let temporary = await weakCache.image(for: key, maximumPixelSize: 72) { fixture }
            witness = temporary
        }
        await loadTemporary()
        await Task.yield()
        try require(witness == nil, "the sharing index retained unused pixel storage")
        print("PASS the sharing index releases all image pixels when their views release them")
        print("Decoded cover regression harness: 10/10 passed")
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw Failure(description: "asynchronous cover request did not reach its expected state")
    }

    private static func fixtureData() throws -> Data {
        let context = CGContext(
            data: nil, width: 640, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "could not create image fixture")
        return data as Data
    }
}

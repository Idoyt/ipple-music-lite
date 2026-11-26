import Foundation
import MusicCore
import Security

/// One private Rain120 process per app; starts on demand and exits with its parent.
actor LocalQQRuntime {
    static let shared = LocalQQRuntime()
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var ready: QQMusicGatewayEndpoint?
    private var starting: Task<QQMusicGatewayEndpoint, Error>?
    private var buffer = Data()
    private var secret = ""
    private var launchID = UUID()

    nonisolated static func client() -> MusicAPIClient {
        let configuration = LocalQQMusicConfiguration(
            directory: AppSettings.localMusicDirectory,
            credentials: KeychainSessionCredentialStore(service: "org.ipplemusic.public.qq-session.v1")
        ) { try await shared.endpoint() }
        return MusicAPIClient(localQQ: configuration)
    }

    func endpoint() async throws -> QQMusicGatewayEndpoint {
        if let ready, process?.isRunning == true { return ready }
        if let starting { return try await starting.value }
        let operation = Task { try await self.launch() }
        starting = operation
        do {
            let result = try await operation.value
            starting = nil
            return result
        } catch {
            starting = nil
            stop()
            throw error
        }
    }

    private func launch() async throws -> QQMusicGatewayEndpoint {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("QQMusicRuntime"),
            FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("node").path),
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("launch.cjs").path)
        else { throw MusicAPIError(status: 0, code: "QQ_RUNTIME_UNAVAILABLE") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MusicAPIError(status: 0, code: "QQ_RUNTIME_UNAVAILABLE")
        }
        secret = bytes.map { String(format: "%02x", $0) }.joined()
        let id = UUID()
        launchID = id
        buffer.removeAll(keepingCapacity: true)
        ready = nil
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = directory.appendingPathComponent("node")
        child.arguments = [directory.appendingPathComponent("launch.cjs").path]
        child.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["NODE_ENV"] = "production"
        environment["QQ_GATEWAY_KEY"] = secret
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receive(data, launchID: id) }
        }
        process = child
        input = stdin
        output = stdout
        try child.run()
        for _ in 0..<200 {
            try Task.checkCancellation()
            if let ready { return ready }
            guard child.isRunning else { throw MusicAPIError(status: 0, code: "QQ_RUNTIME_UNAVAILABLE") }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MusicAPIError(status: 0, code: "QQ_RUNTIME_UNAVAILABLE")
    }

    private func receive(_ data: Data, launchID id: UUID) {
        guard launchID == id else { return }
        buffer.append(data)
        if buffer.count > 32 * 1024 { buffer.removeAll(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self)
            buffer.removeSubrange(...newline)
            guard line.hasPrefix("IPPLE_QQ_READY="),
                let data = line.dropFirst("IPPLE_QQ_READY=".count).data(using: .utf8),
                let result = try? JSONDecoder().decode(Ready.self, from: data),
                (1...65535).contains(result.port), let url = URL(string: "http://127.0.0.1:\(result.port)")
            else { continue }
            ready = QQMusicGatewayEndpoint(url: url, secret: secret)
        }
    }

    func stop() {
        launchID = UUID()
        ready = nil
        starting?.cancel()
        starting = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        secret = ""
        buffer.removeAll()
    }

    private struct Ready: Decodable { let port: Int }
}

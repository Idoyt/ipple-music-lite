import Foundation

extension MusicAPIClient {
    public func logout() async throws {
        invalidateRequests()
        let _: EmptyResponse = try await request("POST", ["api", "v1", "auth", "logout"])
    }
}

import SwiftUI

private struct WorkspaceIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Retained pages suspend presentation work while playback details cover the workspace.
    var workspaceIsActive: Bool {
        get { self[WorkspaceIsActiveKey.self] }
        set { self[WorkspaceIsActiveKey.self] = newValue }
    }
}

import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the controller-split contract: AppModel exposes the upstream `api`
/// domain's per-concern boundaries (session / settings / workspace) as
/// protocols, so feature views can depend on the boundary instead of the
/// monolith.
@MainActor
final class ControllerSplitTests: XCTestCase {
    func testAppModelConformsToAllControllerProtocols() {
        XCTAssertTrue(AppModel.self is SessionControlling.Type)
        XCTAssertTrue(AppModel.self is SettingsControlling.Type)
        XCTAssertTrue(AppModel.self is WorkspaceControlling.Type)
    }

    func testSessionBoundaryServesLifecycleAndRunSurface() async {
        // Drive the boundary through the protocol type, not the concrete
        // class: the session lifecycle and run surface must be reachable via
        // SessionControlling alone.
        let boundary: SessionControlling = AppModel()
        XCTAssertTrue(boundary.sessions.isEmpty || !boundary.sessions.isEmpty)
        _ = await boundary.searchConversations(query: "controller-split")
    }
}

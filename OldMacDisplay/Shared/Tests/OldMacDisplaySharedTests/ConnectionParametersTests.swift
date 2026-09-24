import Network
import XCTest
@testable import OldMacDisplayShared

/// Interface constraints on the connection have broken the session three times,
/// each time silently: a constrained `NWConnection` to a Bonjour endpoint sits
/// in `.preparing` forever rather than reporting an error. These assertions
/// exist to stop anyone (including a future me) reintroducing one.
final class ConnectionParametersTests: XCTestCase {

    func testNoInterfaceIsPinned() {
        XCTAssertNil(NWMessageChannel.parameters().requiredInterface,
                     "pinning a required interface stalls Bonjour endpoint resolution")
    }

    func testNoInterfaceTypeIsProhibited() {
        let prohibited = NWMessageChannel.parameters().prohibitedInterfaceTypes ?? []
        XCTAssertTrue(prohibited.isEmpty,
                      "prohibiting a link type leaves the connection with no route to fall back to")
    }

    func testTrafficIsMarkedInteractive() {
        XCTAssertEqual(NWMessageChannel.parameters().serviceClass, .responsiveData)
    }
}

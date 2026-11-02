import XCTest
@testable import PokeTokenBar

final class OnlineBattleTransportTests: XCTestCase {
    func testOriginRejectsCredentialAndPathLeaks() throws {
        for value in ["http://example.invalid", "https://person:secret@example.invalid", "https://example.invalid/path", "https://example.invalid?key=secret", "https://example.invalid#secret"] {
            XCTAssertThrowsError(try OnlineBattleOrigin(value))
        }
    }
    func testOriginCanonicalizesDefaultPortAndCase() throws {
        XCTAssertEqual(try OnlineBattleOrigin("HTTPS://EXAMPLE.INVALID:443/").url.absoluteString, "https://example.invalid")
    }
}

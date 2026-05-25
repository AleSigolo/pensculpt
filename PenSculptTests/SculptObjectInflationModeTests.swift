import XCTest
@testable import PenSculpt

final class SculptObjectInflationModeTests: XCTestCase {

    func testDefaultInflationModeIsOrganic() {
        let obj = SculptObject(mesh: Mesh(), sourceStrokeIDs: [])
        XCTAssertEqual(obj.inflationMode, .organic)
    }

    func testInitWithExplicitStraightMode() {
        let obj = SculptObject(mesh: Mesh(), sourceStrokeIDs: [], inflationMode: .straight)
        XCTAssertEqual(obj.inflationMode, .straight)
    }

    func testRoundTripPreservesInflationMode() throws {
        let original = SculptObject(mesh: Mesh(), sourceStrokeIDs: [], inflationMode: .straight)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SculptObject.self, from: data)
        XCTAssertEqual(decoded.inflationMode, .straight)
    }

    func testDecodeWithoutInflationModeFieldFallsBackToOrganic() throws {
        // Simulates a .pensculpt file from before this feature shipped.
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "mesh": {"vertices":[],"faces":[]},
            "sourceStrokeIDs": [],
            "surfaceStrokes": [],
            "originRect": [[0,0],[0,0]]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SculptObject.self, from: legacyJSON)
        XCTAssertEqual(decoded.inflationMode, .organic,
                       "missing inflationMode should default to .organic for backwards-compat")
    }
}

import XCTest
@testable import Core

final class CoreTests: XCTestCase {
    func testJoinMakesGroupAndShowsDropped() {
        let gs = Groups()
        let g = gs.join(2, onto: 1)
        XCTAssertEqual(g?.wins, [1, 2])
        XCTAssertEqual(g?.active, 2)
        XCTAssertEqual(gs.all.count, 1)
    }

    func testJoinOntoGroupedAddsToThatGroup() {
        let gs = Groups()
        gs.join(2, onto: 1)
        let g = gs.join(3, onto: 2)
        XCTAssertEqual(g?.wins, [1, 2, 3])
        XCTAssertEqual(gs.all.count, 1)
    }

    func testJoinAtIndex() {
        let gs = Groups()
        gs.join(2, onto: 1)
        XCTAssertEqual(gs.join(3, onto: 1, at: 0)?.wins, [3, 1, 2])
    }

    func testJoinWithoutSelectKeepsShownTab() {
        let gs = Groups()
        let g = gs.join(2, onto: 1, select: false)
        XCTAssertEqual(g?.wins, [1, 2])
        XCTAssertEqual(g?.active, 1)
        gs.join(3, onto: 1, select: false)
        XCTAssertEqual(g?.active, 1)
        XCTAssertEqual(g?.wins, [1, 2, 3])
    }

    func testOpenGoesRightAfterTheTarget() {
        let gs = Groups()
        gs.join(2, onto: 1)
        gs.join(3, onto: 1)
        let g = gs.open(4, after: 1)
        XCTAssertEqual(g?.wins, [1, 4, 2, 3])
        XCTAssertEqual(g?.active, 4)
        gs.open(5, after: 3, select: false)
        XCTAssertEqual(g?.wins, [1, 4, 2, 3, 5])
        XCTAssertEqual(g?.active, 4)
    }

    func testOpenOntoALoneWindowMakesAPair() {
        let gs = Groups()
        XCTAssertEqual(gs.open(2, after: 1)?.wins, [1, 2])
    }

    func testJoinSelfIsNothing() {
        let gs = Groups()
        XCTAssertNil(gs.join(1, onto: 1))
        XCTAssertTrue(gs.all.isEmpty)
    }

    func testMovingBetweenGroupsDissolvesTheOldPair() {
        let gs = Groups()
        gs.join(2, onto: 1)
        gs.join(4, onto: 3)
        gs.join(2, onto: 3)
        XCTAssertNil(gs.group(of: 1))
        XCTAssertEqual(gs.group(of: 3)?.wins, [3, 4, 2])
        XCTAssertEqual(gs.all.count, 1)
    }

    func testRemoveShownTabShowsTheOneToItsRight() {
        let gs = Groups()
        gs.join(2, onto: 1)
        gs.join(3, onto: 1)
        gs.select(2)
        let g = gs.remove(2)
        XCTAssertEqual(g?.wins, [1, 3])
        XCTAssertEqual(g?.active, 3)
    }

    func testRemoveLastTabShowsTheOneToItsLeft() {
        let gs = Groups()
        gs.join(2, onto: 1)
        gs.join(3, onto: 1)
        XCTAssertEqual(gs.remove(3)?.active, 2)
    }

    func testRemoveDownToOneDissolves() {
        let gs = Groups()
        gs.join(2, onto: 1)
        let g = gs.remove(2)
        XCTAssertEqual(g?.wins, [1])
        XCTAssertNil(gs.group(of: 1))
        XCTAssertTrue(gs.all.isEmpty)
    }

    func testRemoveUngroupedIsNil() {
        XCTAssertNil(Groups().remove(9))
    }

    func testReorder() {
        let gs = Groups()
        gs.join(2, onto: 1)
        gs.join(3, onto: 1)
        gs.move(3, to: 0)
        XCTAssertEqual(gs.group(of: 1)?.wins, [3, 1, 2])
        gs.move(3, to: 99)
        XCTAssertEqual(gs.group(of: 1)?.wins, [1, 2, 3])
    }

    func testJoinWithinSameGroupReordersAndSelects() {
        let gs = Groups()
        gs.join(2, onto: 1)
        gs.join(3, onto: 1)
        gs.select(1)
        let g = gs.join(3, onto: 1, at: 0)
        XCTAssertEqual(g?.wins, [3, 1, 2])
        XCTAssertEqual(g?.active, 3)
    }

    func testStepWraps() {
        let gs = Groups()
        gs.join(2, onto: 1)
        gs.join(3, onto: 1)
        XCTAssertEqual(gs.step(1, by: 1), 1)    // shown is 3, wraps to 1
        XCTAssertEqual(gs.step(1, by: -1), 2)
        XCTAssertNil(gs.step(9, by: 1))
    }

    func testPrune() {
        let gs = Groups()
        gs.join(2, onto: 1)
        gs.join(3, onto: 1)
        gs.join(5, onto: 4)
        gs.prune(keeping: [1, 3, 4])
        XCTAssertEqual(gs.group(of: 1)?.wins, [1, 3])
        XCTAssertNil(gs.group(of: 4))
    }

    func testCodableRoundTrip() throws {
        let gs = Groups()
        gs.join(2, onto: 1)
        gs.join(3, onto: 1)
        gs.select(1)
        let back = try JSONDecoder().decode(Groups.self, from: JSONEncoder().encode(gs))
        XCTAssertEqual(back.all.first?.wins, [1, 2, 3])
        XCTAssertEqual(back.all.first?.active, 1)
        XCTAssertEqual(back.all.first?.id, gs.all.first?.id)
    }
}

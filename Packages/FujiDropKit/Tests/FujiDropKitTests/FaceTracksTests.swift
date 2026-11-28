@testable import FujiDropKit
import CoreGraphics
import XCTest

final class FaceTracksTests: XCTestCase {
    private func face(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 0.1) -> CGRect {
        CGRect(x: x - w / 2, y: y - w / 2, width: w, height: w)
    }

    func testNoFaces() {
        XCTAssertEqual(FaceTracks.matchIndices([[], []]), [])
        XCTAssertEqual(FaceTracks.matchIndices([]), [])
    }

    func testFollowsPeopleAsTheyMoveAndReorder() {
        let frames = [
            [face(0.3, 0.4), face(0.7, 0.4)],
            [face(0.72, 0.42), face(0.33, 0.41)], // listed in the other order
            [face(0.35, 0.4)],                    // the right-hand person turned away
        ]
        XCTAssertEqual(FaceTracks.matchIndices(frames), [[0, 1, 0], [1, 0, nil]])
    }

    func testIgnoresFacesTooFarOrTooDifferentInSize() {
        let frames = [
            [face(0.3, 0.4)],
            [face(0.8, 0.4)],              // far away: someone else
            [face(0.3, 0.4, 0.3)],         // three times the size: not the same face
        ]
        XCTAssertEqual(FaceTracks.matchIndices(frames), [[0, nil, nil]])
    }

    func testKeepsTheLargestFacesLeftToRight() {
        let frames = [[face(0.1, 0.5, 0.02), face(0.6, 0.5, 0.12), face(0.3, 0.5, 0.1)]]
        XCTAssertEqual(FaceTracks.matchIndices(frames, maxPeople: 2), [[2], [1]])
    }

    func testMatchReturnsFaces() {
        let a = FaceBox(rect: face(0.3, 0.4), eyeOpenness: 0.3), b = FaceBox(rect: face(0.32, 0.41))
        XCTAssertEqual(FaceTracks.match([[a], [], [b]]), [[a, nil, b]])
    }

    func testSmallFacesDontCountForEyes() {
        let small = FaceBox(rect: face(0.5, 0.5, 0.05), eyeOpenness: 0.05)
        let big = FaceBox(rect: face(0.5, 0.5, 0.1), eyeOpenness: 0.05)
        XCTAssertFalse(small.eyesClosed())
        XCTAssertTrue(big.eyesClosed())
        XCTAssertEqual(ShotScore(sharpness: 1, faces: [small, big]).eyeOpenness, 0.05)
        XCTAssertNil(ShotScore(sharpness: 1, faces: [small]).eyeOpenness)
    }

    func testFaceCutOffAtTheEdgeStillCountsForEyes() {
        // Vision's box reaches past the left edge; most of the face is in the frame.
        let edge = FaceBox(rect: CGRect(x: -0.03, y: 0.4, width: 0.08, height: 0.1), eyeOpenness: 0.08)
        XCTAssertTrue(edge.eyesClosed())
    }

    func testEachFaceUsedOnce() {
        // Two people close together; the second frame has only one face, nearest the left one.
        let frames = [[face(0.40, 0.5), face(0.52, 0.5)], [face(0.41, 0.5)]]
        XCTAssertEqual(FaceTracks.matchIndices(frames), [[0, 0], [1, nil]])
    }
}

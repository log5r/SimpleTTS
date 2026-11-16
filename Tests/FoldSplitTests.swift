import CoreGraphics

private enum TestFailure: Error { case failed(String) }

/// iPhone Duo の内側の画面で、折り目を避けて読み上げ画面を分ける計算のテスト。
/// 寸法は iPhone Duo のシミュレータの内側の画面（横向きでおよそ 951×669pt）を目安にしている。
@main
struct FoldSplitTests {
    static func main() throws {
        try testVerticalFoldSplitsSideBySide()
        try testZeroWidthFoldLine()
        try testHorizontalFoldSplitsTopAndBottom()
        try testNoSplitWithoutDivision()
        try testIgnoresDivisionsThatDoNotCross()
        try testIgnoresNarrowPanes()
        try testUsesFirstUsableDivision()
        try testStackedPanesRequireControlWidth()
        try testMinimumBoundary()
        try testZeroHeightFoldLine()
        try testHingeMotion()
        print("PASS: fold split for side-by-side, stacked, zero-width/height, missing, partial, outside, narrow panes, control width, and minimum boundary; hinge motion")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure.failed(message) }
    }

    private static func testVerticalFoldSplitsSideBySide() throws {
        let size = CGSize(width: 951, height: 600)
        let fold = CGRect(x: 465, y: 0, width: 21, height: 600)
        guard let split = FoldSplit(size: size, divisions: [fold]) else {
            throw TestFailure.failed("A vertical fold across the reader was not split")
        }
        try require(split.axis == .horizontal, "Vertical fold should place panes side by side")
        try require(split.first == CGRect(x: 0, y: 0, width: 465, height: 600), "Wrong leading pane: \(split.first)")
        try require(split.gap == CGRect(x: 465, y: 0, width: 21, height: 600), "Wrong gap: \(split.gap)")
        try require(split.second == CGRect(x: 486, y: 0, width: 465, height: 600), "Wrong trailing pane: \(split.second)")
        try require(split.first.width + split.gap.width + split.second.width == size.width, "Panes do not fill the width")
    }

    private static func testZeroWidthFoldLine() throws {
        let size = CGSize(width: 951, height: 600)
        // 領域が画面の外まで延びていても、読み上げ画面の中に切り詰めて使う
        let fold = CGRect(x: 475, y: -40, width: 0, height: 700)
        guard let split = FoldSplit(size: size, divisions: [fold]) else {
            throw TestFailure.failed("A zero-width fold line was ignored")
        }
        try require(split.axis == .horizontal, "Zero-width fold should place panes side by side")
        try require(split.first.width == 475 && split.second.minX == 475 && split.second.width == 476,
                    "Wrong panes for a fold line: \(split.first), \(split.second)")
        try require(split.gap.width == 0 && split.gap.height == 600, "Wrong gap for a fold line: \(split.gap)")
    }

    private static func testHorizontalFoldSplitsTopAndBottom() throws {
        let size = CGSize(width: 669, height: 860)
        let fold = CGRect(x: 0, y: 420, width: 669, height: 20)
        guard let split = FoldSplit(size: size, divisions: [fold]) else {
            throw TestFailure.failed("A horizontal fold across the reader was not split")
        }
        try require(split.axis == .vertical, "Horizontal fold should stack panes")
        try require(split.first == CGRect(x: 0, y: 0, width: 669, height: 420), "Wrong top pane: \(split.first)")
        try require(split.second == CGRect(x: 0, y: 440, width: 669, height: 420), "Wrong bottom pane: \(split.second)")
    }

    private static func testNoSplitWithoutDivision() throws {
        try require(FoldSplit(size: CGSize(width: 380, height: 600), divisions: []) == nil, "Split without a fold")
        try require(FoldSplit(size: .zero, divisions: [CGRect(x: 0, y: 0, width: 1, height: 1)]) == nil, "Split an empty view")
    }

    private static func testIgnoresDivisionsThatDoNotCross() throws {
        let size = CGSize(width: 951, height: 600)
        // 上端から下端まで届いていない（読み上げ画面の一部だけにかかる）
        let partial = CGRect(x: 465, y: 100, width: 21, height: 400)
        try require(FoldSplit(size: size, divisions: [partial]) == nil, "Split on a fold that does not cross the reader")
        // 読み上げ画面の外（サイドバー側など）にある
        let outside = CGRect(x: -300, y: 0, width: 21, height: 600)
        try require(FoldSplit(size: size, divisions: [outside]) == nil, "Split on a fold outside the reader")
        // 端に接しているだけ
        let edge = CGRect(x: 951, y: 0, width: 21, height: 600)
        try require(FoldSplit(size: size, divisions: [edge]) == nil, "Split on a fold at the edge")
    }

    private static func testIgnoresNarrowPanes() throws {
        // サイドバーを出していて、折り目が読み上げ画面の端近くにかかる場合など
        let size = CGSize(width: 630, height: 600)
        let fold = CGRect(x: 150, y: 0, width: 21, height: 600)
        try require(FoldSplit(size: size, divisions: [fold]) == nil, "Split into a pane narrower than the minimum")
        let fitting = FoldSplit(size: size, divisions: [fold], minimumPaneLength: 100)
        try require(fitting?.first.width == 150, "Minimum pane length was not configurable")
    }

    private static func testUsesFirstUsableDivision() throws {
        let size = CGSize(width: 951, height: 600)
        let unusable = CGRect(x: 100, y: 0, width: 10, height: 600)
        let usable = CGRect(x: 465, y: 0, width: 21, height: 600)
        let split = FoldSplit(size: size, divisions: [unusable, usable])
        try require(split?.first.width == 465, "Did not fall back to the next usable fold")
    }
    private static func testStackedPanesRequireControlWidth() throws {
        let size = CGSize(width: 300, height: 860)
        let fold = CGRect(x: 0, y: 420, width: 300, height: 20)
        try require(FoldSplit(size: size, divisions: [fold]) == nil,
                    "Stacked panes must have enough width for the controls")
    }

    private static func testMinimumBoundary() throws {
        let size = CGSize(width: 700, height: 600)
        let fitting = CGRect(x: 340, y: 0, width: 20, height: 600)
        try require(FoldSplit(size: size, divisions: [fitting]) != nil,
                    "Panes exactly at the minimum should fit")
        let tooSmall = CGRect(x: 339.5, y: 0, width: 20, height: 600)
        try require(FoldSplit(size: size, divisions: [tooSmall]) == nil,
                    "A pane below the minimum should not fit")
    }

    private static func testZeroHeightFoldLine() throws {
        let size = CGSize(width: 669, height: 860)
        let fold = CGRect(x: -20, y: 430, width: 710, height: 0)
        let split = FoldSplit(size: size, divisions: [fold])
        try require(split?.axis == .vertical && split?.first.height == 430
                    && split?.second.minY == 430 && split?.gap.height == 0,
                    "A zero-height horizontal fold must split into equal panes")
    }

    /// ヒンジが動いたとみなす条件（開き具合の段階の変化、角度の閾値、最初の通知、情報の有無の変化）
    private static func testHingeMotion() throws {
        typealias Snapshot = HingeMotion.Snapshot
        let half = Snapshot(status: AnyHashable("partiallyOpen"), degrees: 128)
        try require(HingeMotion.hasMoved(from: nil, to: half), "The first notification should count as motion")
        try require(!HingeMotion.hasMoved(from: half, to: half), "An unchanged hinge should not count as motion")
        let jitter = Snapshot(status: half.status, degrees: 128 + HingeMotion.angleThreshold - 0.01)
        try require(!HingeMotion.hasMoved(from: half, to: jitter), "Changes below the threshold should be ignored")
        let jitterDown = Snapshot(status: half.status, degrees: 128 - HingeMotion.angleThreshold + 0.01)
        try require(!HingeMotion.hasMoved(from: half, to: jitterDown), "Decreases below the threshold should be ignored")
        let threshold = Snapshot(status: half.status, degrees: 128 + HingeMotion.angleThreshold)
        try require(HingeMotion.hasMoved(from: half, to: threshold), "A change of exactly the threshold should count")
        let closing = Snapshot(status: half.status, degrees: 121)
        try require(HingeMotion.hasMoved(from: half, to: closing), "Closing by several degrees should count")
        let open = Snapshot(status: AnyHashable("fullyOpen"), degrees: 128)
        try require(HingeMotion.hasMoved(from: half, to: open), "A status change should count even at the same angle")
        let none = Snapshot(status: nil, degrees: nil)
        try require(!HingeMotion.hasMoved(from: none, to: none), "No hinge should never count as motion")
        try require(HingeMotion.hasMoved(from: none, to: half), "A hinge appearing should count as motion")
        let noAngle = Snapshot(status: half.status, degrees: nil)
        try require(HingeMotion.hasMoved(from: half, to: noAngle), "Losing the angle should count as motion")
    }
}

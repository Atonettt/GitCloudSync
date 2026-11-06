import XCTest

final class TextDiffTests: XCTestCase {
    func testIdenticalTextsHaveNoChanges() {
        let lines = TextDiff.compare(old: "一\n二\n", new: "一\n二")
        XCTAssertEqual(lines, [.same("一"), .same("二")])
        XCTAssertEqual(TextDiff.summary(of: lines).total, 0)
    }

    func testAddedAndRemovedParagraphs() {
        let lines = TextDiff.compare(old: "项目概述\n公式 (1)：E = Σ Pi × ti\n总结",
                                     new: "项目概述\n总结\n展望")
        XCTAssertEqual(lines, [.same("项目概述"), .removed("公式 (1)：E = Σ Pi × ti"), .same("总结"), .added("展望")])
        let summary = TextDiff.summary(of: lines)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.removed, 1)
    }

    func testEditedParagraphMarksTheChangedCharacters() {
        let lines = TextDiff.compare(old: "建立了周例会机制", new: "建立了月例会机制")
        guard case .changed(let old, let new) = lines.first, lines.count == 1 else {
            return XCTFail("expected one edited paragraph, got \(lines)")
        }
        XCTAssertEqual(old.filter(\.changed).map(\.text).joined(), "周")
        XCTAssertEqual(new.filter(\.changed).map(\.text).joined(), "月")
        XCTAssertEqual(new.map(\.text).joined(), "建立了月例会机制")
    }

    func testUnrelatedReplacementIsNotPaired() {
        let lines = TextDiff.compare(old: "abc", new: "xyz")
        XCTAssertEqual(lines, [.removed("abc"), .added("xyz")])
    }

    func testWindowsLineEndingsAndTrailingSpacesAreIgnored() {
        XCTAssertEqual(TextDiff.compare(old: "a  \r\nb\r\n", new: "a\nb").filter(\.isChange), [])
    }

    func testBlankLinesAreIgnored() {
        XCTAssertEqual(TextDiff.compare(old: "标题\n\n\n正文", new: "标题\n正文\n\n").filter(\.isChange), [])
    }

    func testSheetChangesAreSortedByRowThenColumn() {
        let changes = SheetDiff.compare(
            old: ["Sheet1": ["B5": "100", "A1": "名称", "C2": "x"]],
            new: ["Sheet1": ["B5": "120", "A1": "名称", "AA1": "新"], "Sheet2": ["A1": "1"]])
        XCTAssertEqual(changes.map(\.id), ["Sheet1!AA1", "Sheet1!C2", "Sheet1!B5", "Sheet2!A1"])
        XCTAssertEqual(changes.first { $0.cell == "B5" }?.old, "100")
        XCTAssertEqual(changes.first { $0.cell == "B5" }?.new, "120")
        XCTAssertNil(changes.first { $0.cell == "C2" }?.new)
    }
}

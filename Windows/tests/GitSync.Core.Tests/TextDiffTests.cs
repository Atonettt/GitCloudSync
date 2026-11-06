using GitSync.Core;

namespace GitSync.Core.Tests;

public sealed class TextDiffTests
{
    [Fact]
    public void IdenticalTextsHaveNoChanges()
    {
        var lines = TextDiff.Compare("一\n二\n", "一\n二");
        Assert.Equal([new TextDiff.Line.Same("一"), new TextDiff.Line.Same("二")], lines);
        Assert.Equal(0, TextDiff.Summarize(lines).Total);
    }

    [Fact]
    public void AddedAndRemovedParagraphs()
    {
        var lines = TextDiff.Compare("项目概述\n公式 (1)：E = Σ Pi × ti\n总结", "项目概述\n总结\n展望");
        Assert.Equal([new TextDiff.Line.Same("项目概述"), new TextDiff.Line.Removed("公式 (1)：E = Σ Pi × ti"),
                      new TextDiff.Line.Same("总结"), new TextDiff.Line.Added("展望")], lines);
        var summary = TextDiff.Summarize(lines);
        Assert.Equal(1, summary.Added);
        Assert.Equal(1, summary.Removed);
    }

    [Fact]
    public void EditedParagraphMarksTheChangedCharacters()
    {
        var lines = TextDiff.Compare("建立了周例会机制", "建立了月例会机制");
        var changed = Assert.IsType<TextDiff.Line.Changed>(Assert.Single(lines));
        Assert.Equal("周", string.Concat(changed.Old.Where(s => s.Changed).Select(s => s.Text)));
        Assert.Equal("月", string.Concat(changed.New.Where(s => s.Changed).Select(s => s.Text)));
        Assert.Equal("建立了月例会机制", string.Concat(changed.New.Select(s => s.Text)));
    }

    [Fact]
    public void UnrelatedReplacementIsNotPaired()
    {
        Assert.Equal([new TextDiff.Line.Removed("abc"), new TextDiff.Line.Added("xyz")], TextDiff.Compare("abc", "xyz"));
    }

    [Fact]
    public void LineEndingsTrailingSpacesAndBlankLinesAreIgnored()
    {
        Assert.DoesNotContain(TextDiff.Compare("a  \r\nb\r\n", "a\nb"), l => l.IsChange);
        Assert.DoesNotContain(TextDiff.Compare("标题\n\n\n正文", "标题\n正文\n\n"), l => l.IsChange);
    }

    [Fact]
    public void MyersFindsMinimalEdits()
    {
        var (removed, inserted) = Myers.Diff("ABCABBA".ToCharArray(), "CBABAC".ToCharArray());
        Assert.Equal(5, removed.Count + inserted.Count);   // the classic example has edit distance 5
    }

    [Fact]
    public void SheetChangesAreSortedByRowThenColumn()
    {
        var changes = SheetDiff.Compare(
            new() { ["Sheet1"] = new() { ["B5"] = "100", ["A1"] = "名称", ["C2"] = "x" } },
            new() { ["Sheet1"] = new() { ["B5"] = "120", ["A1"] = "名称", ["AA1"] = "新" }, ["Sheet2"] = new() { ["A1"] = "1" } });
        Assert.Equal(["Sheet1!AA1", "Sheet1!C2", "Sheet1!B5", "Sheet2!A1"], changes.Select(c => c.Id));
        Assert.Equal("100", changes.Single(c => c.Cell == "B5").Old);
        Assert.Equal("120", changes.Single(c => c.Cell == "B5").New);
        Assert.Null(changes.Single(c => c.Cell == "C2").New);
    }
}

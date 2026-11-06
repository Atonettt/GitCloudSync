using GitSync.Core;

namespace GitSync.Core.Tests;

public sealed class SyncEngineTests : IAsyncLifetime
{
    readonly GitSandbox sandbox = new();
    public Task InitializeAsync() => sandbox.InitializeAsync();
    public Task DisposeAsync() => sandbox.DisposeAsync();

    [Fact]
    public async Task FirstUploadToEmptyRemotePublishesBranch()
    {
        await sandbox.CreateEmptyRemote();
        var pc = await sandbox.Clone("pc");
        GitSandbox.Write("报告.docx-binary", "文档/报告.docx", pc);

        var report = await sandbox.Engine(pc).SyncAsync();

        Assert.True(report.Summary != null, report.DebugText);
        Assert.Equal(1, report.Summary!.CommittedFiles);
        Assert.Equal(["文档/报告.docx"], await sandbox.RemoteFiles());
        Assert.Equal("origin/main", report.Info?.Upstream);
    }

    [Fact]
    public async Task LocalChangesAreUploaded()
    {
        await sandbox.CreateRemote();
        var pc = await sandbox.Clone("pc");
        GitSandbox.Write("new content", "notes.txt", pc);
        GitSandbox.Write("changed\n", "README.md", pc);

        var report = await sandbox.Engine(pc).SyncAsync();

        Assert.True(report.Summary?.CommittedFiles == 2, report.DebugText);
        Assert.Equal(1, report.Summary!.UploadedCommits);
        Assert.Equal("new content", await sandbox.RemoteContent("notes.txt"));
        Assert.Equal(0, report.Info?.ChangedFiles);
        Assert.Equal(0, report.Info?.Ahead);
    }

    [Fact]
    public async Task RemoteChangesAreDownloaded()
    {
        await sandbox.CreateRemote();
        var pc = await sandbox.Clone("pc");
        var other = await sandbox.Clone("other");
        await sandbox.CommitAndPush(new() { ["from-other.txt"] = "hi from the other computer" }, other);

        var report = await sandbox.Engine(pc).SyncAsync();

        Assert.True(report.Summary?.DownloadedCommits == 1, report.DebugText);
        Assert.Equal("hi from the other computer", GitSandbox.Read("from-other.txt", pc));
        Assert.Equal(["from-other.txt"], report.DownloadedFiles);
    }

    [Fact]
    public async Task NoChangesReportsNoChanges()
    {
        await sandbox.CreateRemote();
        var pc = await sandbox.Clone("pc");
        var report = await sandbox.Engine(pc).SyncAsync();
        Assert.True(report.IsNoChanges, report.DebugText);
        Assert.Equal(SyncStatus.NoChanges, report.Status);
    }

    [Fact]
    public async Task EmptyRepositoryAdoptsGitHubDefaultBranch()
    {
        await sandbox.CreateEmptyRemote();
        var seed = await sandbox.Clone("seed");
        GitSandbox.Write("from GitHub\n", "a.txt", seed);
        await sandbox.Run(["add", "-A"], seed);
        await sandbox.Run(["commit", "-qm", "work"], seed);
        await sandbox.Run(["push", "-q", "origin", "HEAD:feature"], seed);
        await sandbox.Run(["symbolic-ref", "HEAD", "refs/heads/feature"], sandbox.Bare);

        var local = Path.Combine(sandbox.Root, "local");
        Directory.CreateDirectory(local);
        await sandbox.Run(["init", "-q", "-b", "main"], local);
        await sandbox.Configure(local);
        await sandbox.Run(["remote", "add", "origin", sandbox.Bare], local);
        GitSandbox.Write("mine\n", "mine.txt", local);

        var report = await sandbox.Engine(local).SyncAsync();

        Assert.True(report.Summary?.DownloadedCommits == 1, report.DebugText);
        Assert.Equal("feature", report.Info?.Branch);
        Assert.Equal("from GitHub\n", GitSandbox.Read("a.txt", local));
        Assert.Equal(["a.txt", "mine.txt"], (await sandbox.RemoteFiles("feature")).Order());
    }

    [Fact]
    public async Task NonConflictingChangesOnBothSidesAreMerged()
    {
        await sandbox.CreateRemote(new() { ["a.txt"] = "a\n", ["b.txt"] = "b\n" });
        var pc = await sandbox.Clone("pc");
        var other = await sandbox.Clone("other");
        await sandbox.CommitAndPush(new() { ["b.txt"] = "b changed remotely\n" }, other);
        GitSandbox.Write("a changed locally\n", "a.txt", pc);

        var report = await sandbox.Engine(pc).SyncAsync();

        Assert.True(report.Summary != null, report.DebugText);
        Assert.Equal("a changed locally\n", GitSandbox.Read("a.txt", pc));
        Assert.Equal("b changed remotely\n", GitSandbox.Read("b.txt", pc));
        Assert.Equal("a changed locally\n", await sandbox.RemoteContent("a.txt"));
        Assert.Equal(["b.txt"], report.DownloadedFiles);
    }

    [Fact]
    public async Task SameFileConflictIsDetectedAndNothingIsOverwritten()
    {
        await sandbox.CreateRemote(new() { ["合同.docx"] = "v1" });
        var pc = await sandbox.Clone("pc");
        var other = await sandbox.Clone("other");
        await sandbox.CommitAndPush(new() { ["合同.docx"] = "edited on the other computer" }, other);
        GitSandbox.Write("edited here", "合同.docx", pc);

        var report = await sandbox.Engine(pc).SyncAsync();

        var conflict = Assert.IsType<SyncOutcome.Conflict>(report.Outcome);
        Assert.Equal(["合同.docx"], conflict.Files.Select(f => f.Path));
        Assert.Equal("edited here", GitSandbox.Read("合同.docx", pc));
        Assert.Null(report.Info?.InProgressOperation);
        Assert.Equal(1, report.Info?.Ahead);
        Assert.Equal("edited on the other computer", await sandbox.RemoteContent("合同.docx"));
    }

    [Fact]
    public async Task ResolveConflictKeepBothSavesRemoteCopyAndPushes()
    {
        L.Language = "zh";
        await sandbox.CreateRemote(new() { ["plan.xlsx"] = "v1" });
        var pc = await sandbox.Clone("pc");
        var other = await sandbox.Clone("other");
        await sandbox.CommitAndPush(new() { ["plan.xlsx"] = "remote" }, other);
        GitSandbox.Write("local", "plan.xlsx", pc);
        await sandbox.Engine(pc).SyncAsync();

        var report = await sandbox.Engine(pc).ResolveConflictsAsync(new Dictionary<string, ConflictChoice> { ["plan.xlsx"] = ConflictChoice.KeepBoth });

        Assert.True(report.Summary != null, report.DebugText);
        Assert.Equal("local", GitSandbox.Read("plan.xlsx", pc));
        var copy = Directory.GetFiles(pc).Select(Path.GetFileName).Single(n => n!.StartsWith("plan (远程版本") && n.EndsWith(".xlsx"))!;
        Assert.Equal("remote", GitSandbox.Read(copy, pc));
        Assert.Contains(copy, await sandbox.RemoteFiles());
        Assert.Equal("local", await sandbox.RemoteContent("plan.xlsx"));
        Assert.NotEmpty((await sandbox.Run(["for-each-ref", "refs/gitcloud-sync/backup"], pc)).Stdout);
    }

    [Fact]
    public async Task ResolveConflictKeepRemote()
    {
        await sandbox.CreateRemote(new() { ["photo.jpg"] = "v1" });
        var pc = await sandbox.Clone("pc");
        var other = await sandbox.Clone("other");
        await sandbox.CommitAndPush(new() { ["photo.jpg"] = "remote" }, other);
        GitSandbox.Write("local", "photo.jpg", pc);
        await sandbox.Engine(pc).SyncAsync();

        var report = await sandbox.Engine(pc).ResolveConflictsAsync(new Dictionary<string, ConflictChoice> { ["photo.jpg"] = ConflictChoice.KeepRemote });

        Assert.True(report.Summary != null, report.DebugText);
        Assert.Equal("remote", GitSandbox.Read("photo.jpg", pc));
        Assert.Equal(0, report.Info?.Ahead);
        Assert.Equal(0, report.Info?.Behind);
    }

    [Fact]
    public async Task ResolveWithMissingChoiceReturnsConflictsAgain()
    {
        await sandbox.CreateRemote(new() { ["x.txt"] = "1", ["y.txt"] = "1" });
        var pc = await sandbox.Clone("pc");
        var other = await sandbox.Clone("other");
        await sandbox.CommitAndPush(new() { ["x.txt"] = "r", ["y.txt"] = "r" }, other);
        GitSandbox.Write("l", "x.txt", pc);
        GitSandbox.Write("l", "y.txt", pc);
        await sandbox.Engine(pc).SyncAsync();

        var report = await sandbox.Engine(pc).ResolveConflictsAsync(new Dictionary<string, ConflictChoice> { ["x.txt"] = ConflictChoice.KeepLocal });

        var conflict = Assert.IsType<SyncOutcome.Conflict>(report.Outcome);
        Assert.Equal(["x.txt", "y.txt"], conflict.Files.Select(f => f.Path).Order());
        Assert.Null(report.Info?.InProgressOperation);
        Assert.Equal("l", GitSandbox.Read("y.txt", pc));
    }

    [Fact]
    public async Task UnfinishedMergeIsNotTouched()
    {
        await sandbox.CreateRemote(new() { ["f.txt"] = "1" });
        var pc = await sandbox.Clone("pc");
        var other = await sandbox.Clone("other");
        await sandbox.CommitAndPush(new() { ["f.txt"] = "remote" }, other);
        GitSandbox.Write("local", "f.txt", pc);
        await sandbox.Run(["commit", "-am", "local"], pc);
        await sandbox.Run(["fetch"], pc);
        try { await sandbox.Run(["merge", "origin/main"], pc); } catch { /* leaves conflict markers */ }

        var report = await sandbox.Engine(pc).SyncAsync();

        Assert.True(report.Failure?.Kind == FailureKind.OperationInProgress, report.DebugText);
        Assert.Equal(InProgressOperation.Merge, report.Info?.InProgressOperation);
    }

    [Fact]
    public async Task IndexLockBlocksSync()
    {
        await sandbox.CreateRemote();
        var pc = await sandbox.Clone("pc");
        File.WriteAllBytes(Path.Combine(pc, ".git", "index.lock"), []);
        var report = await sandbox.Engine(pc).SyncAsync();
        Assert.True(report.Failure?.Kind == FailureKind.IndexLocked, report.DebugText);
    }

    [Fact]
    public async Task MissingFolderAndNonRepositoryAndNoOriginFail()
    {
        var missing = await sandbox.Engine(Path.Combine(sandbox.Root, "does-not-exist")).SyncAsync();
        Assert.Equal(FailureKind.FolderMissing, missing.Failure?.Kind);

        var plain = Path.Combine(sandbox.Root, "plain");
        Directory.CreateDirectory(plain);
        var notRepo = await sandbox.Engine(plain).SyncAsync();
        Assert.True(notRepo.Failure?.Kind == FailureKind.NotARepository, notRepo.DebugText);

        var localOnly = Path.Combine(sandbox.Root, "local-only");
        await sandbox.Run(["init", "-b", "main", localOnly], sandbox.Root);
        var noRemote = await sandbox.Engine(localOnly).SyncAsync();
        Assert.True(noRemote.Failure?.Kind == FailureKind.NoRemote, noRemote.DebugText);
    }

    [Fact]
    public async Task IgnoredFilesAreNotCommitted()
    {
        await sandbox.CreateRemote();
        var pc = await sandbox.Clone("pc");
        GitSandbox.Write("x", "Thumbs.db", pc);
        GitSandbox.Write("lock", "~$报告.docx", pc);
        GitSandbox.Write("real", "报告.docx", pc);

        var report = await sandbox.Engine(pc).SyncAsync();

        Assert.True(report.Summary?.CommittedFiles == 1, report.DebugText);
        var files = await sandbox.RemoteFiles();
        Assert.Contains("报告.docx", files);
        Assert.DoesNotContain("Thumbs.db", files);
        Assert.DoesNotContain("~$报告.docx", files);
    }

    [Fact]
    public async Task OversizedFilesAreSkippedWithWarning()
    {
        await sandbox.CreateRemote();
        var pc = await sandbox.Clone("pc");
        GitSandbox.WriteBytes(Enumerable.Repeat((byte)7, 4096).ToArray(), "big file.bin", pc);
        GitSandbox.Write("small", "small.txt", pc);

        var report = await sandbox.Engine(pc, new SyncOptions { LargeFileLimitBytes = 1024, LargeFileWarningBytes = 512 }).SyncAsync();

        Assert.True(report.Summary?.CommittedFiles == 1, report.DebugText);
        var files = await sandbox.RemoteFiles();
        Assert.Contains("small.txt", files);
        Assert.DoesNotContain("big file.bin", files);
        Assert.True(GitSandbox.Exists("big file.bin", pc));
        Assert.Contains(report.Warnings, w => w.Contains("big file.bin"));
    }

    [Fact]
    public async Task NetworkFailureIsClassifiedAndChangesStayLocal()
    {
        await sandbox.CreateRemote();
        var pc = await sandbox.Clone("pc");
        await sandbox.Run(["remote", "set-url", "origin", "https://gitcloud-sync-test.invalid/user/repo.git"], pc);
        GitSandbox.Write("offline edit", "offline.txt", pc);

        var report = await sandbox.Engine(pc).SyncAsync();

        Assert.True(report.Failure?.Kind == FailureKind.Network, report.DebugText);
        Assert.Equal(SyncStage.Fetch, report.Failure!.Stage);
        Assert.Equal(SyncStatus.NetworkUnavailable, report.Status);
        Assert.Equal("offline edit", GitSandbox.Read("offline.txt", pc));
    }

    [Fact]
    public async Task RevertToRemoteUndoesUnsyncedEditsAndKeepsLocalOnlyFiles()
    {
        await sandbox.CreateRemote(new() { ["docs/a.txt"] = "a\n", ["docs/b.txt"] = "b\n", ["c.txt"] = "c\n" });
        var pc = await sandbox.Clone("pc");
        GitSandbox.Write("broken\n", "docs/a.txt", pc);
        File.Delete(Path.Combine(pc, "docs", "b.txt"));
        GitSandbox.Write("new\n", "docs/new.txt", pc);
        GitSandbox.Write("c edited\n", "c.txt", pc);

        var report = await sandbox.Engine(pc).RevertToRemoteAsync(["docs"]);

        Assert.True(report.Summary?.RestoredFiles == 2, report.DebugText);
        Assert.Equal("a\n", GitSandbox.Read("docs/a.txt", pc));
        Assert.Equal("b\n", GitSandbox.Read("docs/b.txt", pc));
        Assert.Equal("new\n", GitSandbox.Read("docs/new.txt", pc));
        Assert.Equal("c edited\n", GitSandbox.Read("c.txt", pc));
        var backup = (await sandbox.Run(["for-each-ref", "--format=%(refname)", "refs/gitcloud-sync/backup/"], pc)).Stdout.Trim();
        Assert.Equal("broken\n", (await sandbox.Run(["show", $"{backup}:docs/a.txt"], pc)).Stdout);
    }

    [Fact]
    public async Task RestoreFileCreatesNewCommit()
    {
        await sandbox.CreateRemote(new() { ["a.txt"] = "v1" });
        var pc = await sandbox.Clone("pc");
        var first = (await sandbox.Run(["rev-parse", "HEAD"], pc)).Stdout.Trim();
        GitSandbox.Write("v2", "a.txt", pc);
        await sandbox.Engine(pc).SyncAsync();

        var report = await sandbox.Engine(pc).RestoreAsync(new RestoreTarget.File("a.txt", "a.txt", first), "a.txt");

        Assert.True(report.Summary?.RestoredFiles == 1, report.DebugText);
        Assert.Equal("v1", GitSandbox.Read("a.txt", pc));
        Assert.Equal("v1", await sandbox.RemoteContent("a.txt"));
    }

    [Fact]
    public async Task ExportRemoteVersionDoesNotModifyRepository()
    {
        await sandbox.CreateRemote(new() { ["doc.txt"] = "1" });
        var pc = await sandbox.Clone("pc");
        var other = await sandbox.Clone("other");
        await sandbox.CommitAndPush(new() { ["doc.txt"] = "remote" }, other);
        GitSandbox.Write("local", "doc.txt", pc);
        await sandbox.Engine(pc).SyncAsync();

        var path = await sandbox.Engine(pc).ExportRemoteVersionAsync("doc.txt");

        Assert.Equal("remote", File.ReadAllText(path));
        Assert.Equal("local", GitSandbox.Read("doc.txt", pc));
    }
}

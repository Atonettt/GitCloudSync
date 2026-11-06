using GitSync.Core;

namespace GitSync.Core.Tests;

public sealed class HistoryAndCreatorTests : IAsyncLifetime
{
    readonly GitSandbox sandbox = new();
    public Task InitializeAsync() => sandbox.InitializeAsync();
    public Task DisposeAsync() => sandbox.DisposeAsync();

    HistoryBrowser Browser(string repo) => new(new GitClient(repo, sandbox.Git));

    async Task SyncVersions(string[] contents, string path, string repo)
    {
        foreach (var content in contents)
        {
            GitSandbox.Write(content, path, repo);
            var report = await sandbox.Engine(repo, new SyncOptions { MachineName = "PC-A" }).SyncAsync();
            Assert.True(report.Summary != null, report.DebugText);
        }
    }

    [Fact]
    public async Task FileVersionsAreListedNewestFirstAndParsed()
    {
        L.Language = "en";
        await sandbox.CreateRemote();
        var pc = await sandbox.Clone("pc");
        await SyncVersions(["v1", "v2 longer", "v3"], "文档/合同.txt", pc);

        var versions = await Browser(pc).VersionsAsync("文档/合同.txt");

        Assert.Equal([2L, 9L, 2L], versions.Select(v => v.Size ?? -1));
        Assert.All(versions, v => Assert.Equal(CommitKind.AutoSync, v.Commit.Kind));
        Assert.All(versions, v => Assert.Equal("PC-A", v.Commit.Machine));
        Assert.Equal("v1", System.Text.Encoding.UTF8.GetString(await Browser(pc).ContentAsync(versions[2].Path, versions[2].Commit.Id)));
    }

    [Fact]
    public void CommitMessagesFromBothLanguagesAreParsed()
    {
        var zh = new HistoryCommit("a", [], DateTimeOffset.Now, "x", "GitSync：MacBook Pro 自动同步 2026-11-06 10:00");
        var en = new HistoryCommit("b", [], DateTimeOffset.Now, "x", "GitSync: Office PC auto-sync 2026-11-06 10:00");
        var merge = new HistoryCommit("c", [], DateTimeOffset.Now, "x", "GitSync: merged updates from GitHub (Office PC)");
        var restore = new HistoryCommit("d", [], DateTimeOffset.Now, "x", "GitSync：MacBook 恢复「a.txt」到 11月1日");
        Assert.Equal(("MacBook Pro", CommitKind.AutoSync), (zh.Machine, zh.Kind));
        Assert.Equal(("Office PC", CommitKind.AutoSync), (en.Machine, en.Kind));
        Assert.Equal(("Office PC", CommitKind.Merge), (merge.Machine, merge.Kind));
        Assert.Equal(("MacBook", CommitKind.Restore), (restore.Machine, restore.Kind));
        Assert.Equal("恢复「a.txt」到 11月1日", restore.Title);
    }

    [Fact]
    public async Task DeletedFilesPreviousSyncPointAndLastSyncChanges()
    {
        await sandbox.CreateRemote(new() { ["a.txt"] = "a", ["gone.txt"] = "x" });
        var pc = await sandbox.Clone("pc");
        GitSandbox.Write("a2", "a.txt", pc);
        GitSandbox.Write("new", "docs/b.txt", pc);
        File.Delete(Path.Combine(pc, "gone.txt"));
        await sandbox.Engine(pc).SyncAsync();

        var deleted = await Browser(pc).DeletedFilesAsync();
        Assert.Equal(["gone.txt"], deleted.Select(d => d.Path));

        var last = await Browser(pc).LastSyncChangesAsync();
        Assert.Equal(new Dictionary<string, char> { ["a.txt"] = 'M', ["docs/b.txt"] = 'A' }, last.Changes);

        var point = await Browser(pc).PreviousSyncPointAsync("HEAD", "a.txt");
        Assert.True(point?.HasFile);
        Assert.Equal("a", System.Text.Encoding.UTF8.GetString(await Browser(pc).ContentAsync("a.txt", point!.Value.Commit)));
        Assert.False((await Browser(pc).PreviousSyncPointAsync("HEAD", "docs/b.txt"))?.HasFile);
    }

    [Fact]
    public void SuggestedNamesIncludingPinyin()
    {
        Assert.Equal("research-notes", RepositoryNaming.SuggestedName("research-notes"));
        Assert.Equal("My-Thesis-2026", RepositoryNaming.SuggestedName("My Thesis 2026"));
        Assert.Equal("Cafe-notes", RepositoryNaming.SuggestedName("Café notes"));
        Assert.Equal("", RepositoryNaming.SuggestedName("★"));
        Assert.Equal("notes", RepositoryNaming.SuggestedName("notes.git"));
        Assert.Equal(100, RepositoryNaming.SuggestedName(new string('a', 150)).Length);
        if (OperatingSystem.IsMacOS() || OperatingSystem.IsWindows())
        {
            Assert.Equal("yan-jiu-zi-liao", RepositoryNaming.SuggestedName("研究资料"));
            Assert.Equal("lun-wen-draft-v2", RepositoryNaming.SuggestedName("论文 draft v2"));
        }
        Assert.Null(RepositoryNaming.Problem("my_repo.v2"));
        Assert.NotNull(RepositoryNaming.Problem("研究资料"));
        Assert.NotNull(RepositoryNaming.Problem("x.git"));
    }

    [Fact]
    public async Task PlainFolderBecomesRepositoryAndFirstSyncUploadsEverything()
    {
        await sandbox.CreateEmptyRemote();
        var folder = Path.Combine(sandbox.Root, "研究资料");
        GitSandbox.Write("hello", "笔记.md", folder);
        GitSandbox.Write("a", "图片/a.txt", folder);
        GitSandbox.Write("junk", "Thumbs.db", folder);
        var identity = new GitIdentity("Octo", "1+octo@users.noreply.github.com");

        Assert.True(await new RepositoryCreator(sandbox.Git).PrepareAsync(folder, sandbox.Bare, identity, IgnoreRules.DefaultPatterns));
        var report = await sandbox.Engine(folder).SyncAsync();

        Assert.True(report.Summary?.CommittedFiles == 2, report.DebugText);
        Assert.Equal(["图片/a.txt", "笔记.md"], (await sandbox.RemoteFiles()).Order(StringComparer.Ordinal));
        Assert.Equal(identity.Email, (await sandbox.Run(["log", "-1", "--format=%ae", "main"], sandbox.Bare)).Stdout.Trim());
    }

    [Fact]
    public async Task DownloadRestoresFolderAndNeverReplacesFiles()
    {
        await sandbox.CreateRemote(new() { ["笔记.md"] = "hello" });
        var creator = new RepositoryCreator(sandbox.Git);
        var folder = Path.Combine(sandbox.Root, "deleted", "研究资料");

        await creator.DownloadAsync(sandbox.Bare, folder, null, null, IgnoreRules.DefaultPatterns);
        Assert.Equal("hello", GitSandbox.Read("笔记.md", folder));
        Assert.Equal(["研究资料"], Directory.GetFileSystemEntries(Path.GetDirectoryName(folder)!).Select(Path.GetFileName));

        var busy = Path.Combine(sandbox.Root, "busy");
        GitSandbox.Write("mine", "keep.txt", busy);
        await Assert.ThrowsAsync<SyncFailure>(() => creator.DownloadAsync(sandbox.Bare, busy, null, null, []));
        Assert.Equal("mine", GitSandbox.Read("keep.txt", busy));
        Assert.False(GitSandbox.Exists(".git", busy));
    }

    [Fact]
    public async Task DeletionCheckCountsLocalOnlyWork()
    {
        await sandbox.CreateRemote();
        var pc = await sandbox.Clone("pc");
        GitSandbox.Write("x", "local.txt", pc);
        var check = await new RepositoryRemoval(new GitClient(pc, sandbox.Git)).CheckAsync(fetch: true);
        Assert.Equal(1, check.UncommittedFiles);
        Assert.True(check.HasLocalOnlyWork);
        Assert.Equal(("octo", "notes"), RepositoryRemoval.GitHubFullName("git@github.com:octo/notes.git"));
        Assert.Null(RepositoryRemoval.GitHubFullName("https://gitlab.com/octo/notes.git"));
    }

    [Fact]
    public void ProxyFromWindowsSettings()
    {
        var single = SystemProxy.Environment(true, "127.0.0.1:7897", "localhost;127.*;*.local;<local>");
        Assert.Equal("http://127.0.0.1:7897", single["https_proxy"]);
        Assert.Equal("localhost,127.0.0.1,::1,.local", single["no_proxy"]);
        var perProtocol = SystemProxy.Environment(true, "http=127.0.0.1:8080;https=127.0.0.1:8443;socks=127.0.0.1:1080", null);
        Assert.Equal("http://127.0.0.1:8443", perProtocol["HTTPS_PROXY"]);
        Assert.Equal("http://127.0.0.1:8080", perProtocol["HTTP_PROXY"]);
        Assert.Equal("socks5h://127.0.0.1:1080", SystemProxy.Environment(true, "socks=127.0.0.1:1080", null)["ALL_PROXY"]);
        Assert.Empty(SystemProxy.Environment(false, "127.0.0.1:7897", null));
        var kept = SystemProxy.Applying(new Dictionary<string, string> { ["HTTPS_PROXY"] = "http://corp:8080" }, (true, "127.0.0.1:1", null));
        Assert.Equal("http://corp:8080", kept["HTTPS_PROXY"]);
    }

    [Fact]
    public void CountObjectsAndIgnoreRules()
    {
        Assert.Equal((10 + 2048 + 1) * 1024L, RepositoryUsageScanner.ParseCountObjects("count: 3\nsize: 10\nin-pack: 50\nsize-pack: 2048\nsize-garbage: 1\n"));
        var rendered = IgnoreRules.Render("user rule\n", ["*.tmp", "~$*"]);
        Assert.StartsWith("user rule\n\n# >>> GitCloud Sync", rendered);
        Assert.Equal(rendered, IgnoreRules.Render(rendered, ["*.tmp", "~$*"]));
        Assert.True(IgnoreRules.IsIgnored("~$报告.docx", IgnoreRules.DefaultPatterns));
        Assert.False(IgnoreRules.IsIgnored("报告.docx", IgnoreRules.DefaultPatterns));
    }
}

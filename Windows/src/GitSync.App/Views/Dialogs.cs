using GitSync.App.Services;
using GitSync.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitSync.App.Views;

/// <summary>Turns a dropped folder into a GitHub repository: name (pinyin for Chinese), private, what will be uploaded.</summary>
public sealed class CreateRepositoryDialog(AppModel model, string folder)
{
    public async Task ShowAsync(XamlRoot root)
    {
        var name = new TextBox { Header = L.T("仓库名", "Repository name"), Text = RepositoryNaming.SuggestedName(Path.GetFileName(folder.TrimEnd('\\', '/'))),
                                 PlaceholderText = L.T("例如 research-notes", "for example research-notes") };
        var nameProblem = Ui.Text("", 12, brush: Ui.Red, wrap: true);
        var isPrivate = new CheckBox { Content = L.T("私有仓库（只有你能看到，推荐）", "Private (only you can see it; recommended)"), IsChecked = true };
        var description = new TextBox { Header = L.T("简介（可选）", "Description (optional)") };
        var summary = Ui.Caption(L.T("正在查看文件夹…", "Looking at the folder…"), wrap: true);
        var error = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Error, IsClosable = false };
        var signedIn = model.Auth.State.IsUsable;

        var content = Ui.Column(12,
            Ui.Caption(folder, wrap: true),
            summary, name, nameProblem, isPrivate, description, error);
        if (!signedIn)
            content.Children.Insert(0, new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning,
                Title = L.T("需要先登录 GitHub", "Sign in to GitHub first"),
                ActionButton = Ui.Button(L.T("打开设置", "Open Settings"), () => SettingsWindow.Show(model)) });

        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = L.T("在 GitHub 上创建仓库", "Create a Repository on GitHub"),
            Content = new ScrollViewer { Content = content, MaxHeight = 560 },
            PrimaryButtonText = L.T("创建并同步", "Create and Sync"),
            CloseButtonText = L.T("取消", "Cancel"),
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = signedIn,
        };
        void Validate()
        {
            nameProblem.Text = RepositoryNaming.Problem(name.Text.Trim()) ?? "";
            dialog.IsPrimaryButtonEnabled = signedIn && nameProblem.Text.Length == 0;
        }
        name.TextChanged += (_, _) => Validate();
        Validate();

        _ = Task.Run(async () =>
        {
            var preview = await model.PreviewFolderAsync(folder);
            DispatcherQueueExtensions.RunOnUi(() =>
            {
                if (preview == null) { summary.Text = ""; return; }
                var text = L.T($"{preview.FileCount} 个文件，共 {Ui.Bytes(preview.TotalBytes)}{(preview.Truncated ? "（文件很多，只统计了一部分）" : "")}。",
                               $"{preview.FileCount} files, {Ui.Bytes(preview.TotalBytes)} in all{(preview.Truncated ? " (counted partly; the folder is large)" : "")}.");
                if (preview.Kind == FolderKind.RepositoryWithoutRemote)
                    text += L.T($" 这已经是一个 Git 仓库（{preview.Commits} 个提交），历史会一起上传。", $" It's already a Git repository ({preview.Commits} commits); its history is uploaded too.");
                if (preview.Oversized.Count > 0)
                    text += L.T($"\n有 {preview.Oversized.Count} 个文件超过上传上限，会留在本机：", $"\n{preview.Oversized.Count} file(s) are over the upload limit and stay here: ")
                            + string.Join(L.ListSeparator, preview.Oversized.Take(5).Select(o => $"{o.Path} ({Ui.Bytes(o.Bytes)})"));
                if (preview.IsInOneDrive)
                    text += L.T("\n这个文件夹在 OneDrive 中。两个同步工具同时处理同一个文件夹可能产生冲突，建议换到 OneDrive 以外的位置。",
                                "\nThis folder is in OneDrive. Two sync tools on one folder may clash; a folder outside OneDrive works best.");
                summary.Text = text;
            });
        });

        var linkExisting = false;
        dialog.PrimaryButtonClick += async (sender, args) =>
        {
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            error.IsOpen = false;
            var outcome = await model.CreateGitHubRepositoryAsync(folder, name.Text.Trim(), isPrivate.IsChecked == true, description.Text.Trim(), linkExisting);
            switch (outcome)
            {
                case CreationOutcome.Created:
                    break;
                case CreationOutcome.NameTakenButEmpty taken:
                    args.Cancel = true;
                    linkExisting = true;
                    error.Severity = InfoBarSeverity.Informational;
                    error.Title = L.T($"GitHub 上已有空仓库「{taken.FullName}」", $"“{taken.FullName}” already exists on GitHub and is empty");
                    error.Message = L.T("再点一次「创建并同步」，就会把这个文件夹关联到它。", "Click Create and Sync again to link the folder to it.");
                    error.IsOpen = true;
                    break;
                case CreationOutcome.Failed failed:
                    args.Cancel = true;
                    error.Severity = InfoBarSeverity.Error;
                    error.Title = L.T("没有创建成功", "Couldn't create it");
                    error.Message = failed.Message;
                    error.IsOpen = true;
                    break;
            }
            dialog.IsPrimaryButtonEnabled = true;
            deferral.Complete();
        };
        await dialog.ShowAsync();
    }
}

/// <summary>Deletes the GitHub repository, the local folder (to the Recycle Bin), or both — after showing what would be lost.</summary>
public sealed class DeleteRepositoryDialog(AppModel model, Guid id)
{
    const string ScopeCommand = "gh auth refresh -h github.com -s delete_repo";

    public async Task ShowAsync(XamlRoot root)
    {
        if (model.Repository(id) is not { } repo) return;
        var remote = model.State(id).Info?.RemoteUrl ?? repo.KnownRemote;
        var fullName = remote == null ? null : RepositoryRemoval.GitHubFullName(remote);
        var github = new CheckBox { Content = fullName is { } n ? L.T($"删除 GitHub 上的仓库 {n.Owner}/{n.Name}（无法恢复）", $"Delete {n.Owner}/{n.Name} on GitHub (can't be undone)")
                                                                : L.T("删除 GitHub 上的仓库", "Delete the repository on GitHub"), IsEnabled = fullName != null };
        var local = new CheckBox { Content = L.T($"把本地文件夹移到回收站（{repo.Path}）", $"Move the folder to the Recycle Bin ({repo.Path})") };
        var check = Ui.Caption(L.T("正在检查是否有只存在一边的内容…", "Checking for anything that exists on one side only…"), wrap: true);
        var error = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Error, IsClosable = false };
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = L.T($"删除「{repo.DisplayName}」", $"Delete “{repo.DisplayName}”"),
            Content = Ui.Column(12, Ui.Caption(L.T("两边可以分别删除，互不影响。", "Each side can be deleted on its own."), wrap: true), github, local, check, error),
            PrimaryButtonText = L.T("删除", "Delete"),
            CloseButtonText = L.T("取消", "Cancel"),
            DefaultButton = ContentDialogButton.Close,
            IsPrimaryButtonEnabled = false,
        };
        void Validate() => dialog.IsPrimaryButtonEnabled = github.IsChecked == true || local.IsChecked == true;
        github.Click += (_, _) => Validate();
        local.Click += (_, _) => Validate();

        _ = Task.Run(async () =>
        {
            var result = await model.DeletionCheckAsync(id, fetch: true);
            DispatcherQueueExtensions.RunOnUi(() =>
            {
                if (result == null) { check.Text = ""; return; }
                var lines = new List<string>();
                if (result.HasLocalOnlyWork)
                    lines.Add(L.T($"⚠ 本机有 {result.UncommittedFiles} 个未同步的文件和 {result.UnpushedCommits} 个未上传的提交，删除本地文件夹会让它们只剩回收站里的一份。",
                                  $"⚠ {result.UncommittedFiles} unsynced file(s) and {result.UnpushedCommits} unuploaded commit(s) exist only here; deleting the folder leaves them only in the Recycle Bin."));
                if (result.RemoteOnlyCommits is > 0)
                    lines.Add(L.T($"⚠ GitHub 上有 {result.RemoteOnlyCommits} 个这台电脑还没下载的提交，删除 GitHub 仓库会永久丢失它们。",
                                  $"⚠ GitHub has {result.RemoteOnlyCommits} commit(s) not downloaded here; deleting it on GitHub loses them for good."));
                if (lines.Count == 0) lines.Add(L.T("两边内容一致，没有只存在一边的内容。", "Both sides match; nothing exists on one side only."));
                check.Text = string.Join("\n", lines);
            });
        });

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            var outcome = await model.DeleteRepositoryAsync(id, github.IsChecked == true, local.IsChecked == true);
            if (outcome is not DeletionOutcome.Done)
            {
                args.Cancel = true;
                error.Title = outcome is DeletionOutcome.NeedsDeleteScope
                    ? L.T("GitHub 拒绝了删除：当前登录的令牌没有删除仓库的权限（delete_repo）", "GitHub refused: the signed-in token can't delete repositories (delete_repo)")
                    : L.T("没有删除成功", "Couldn't delete it");
                error.Message = outcome is DeletionOutcome.Failed failed ? failed.Message
                    : L.T($"使用 GitHub CLI 登录时，在终端执行下面的命令授权一次再试：\n{ScopeCommand}", $"If you use GitHub CLI, run this once in a terminal, then try again:\n{ScopeCommand}");
                error.IsOpen = true;
            }
            deferral.Complete();
        };
        await dialog.ShowAsync();
    }
}

/// <summary>Choose, per conflicting file, what to keep.</summary>
public sealed class ConflictsDialog(AppModel model, Guid id)
{
    public async Task ShowAsync(XamlRoot root)
    {
        if (model.Repository(id) is not { } repo) return;
        var choices = new Dictionary<string, ComboBox>();
        var rows = Ui.Column(10);
        foreach (var file in repo.ConflictFiles)
        {
            var combo = new ComboBox { MinWidth = 150 };
            foreach (var choice in Enum.GetValues<ConflictChoice>()) combo.Items.Add(new ComboBoxItem { Content = choice.DisplayName(), Tag = choice });
            combo.SelectedIndex = 2;   // Keep Both
            choices[file.Path] = combo;
            var compare = Ui.Link(L.T("查看远程版本", "Open GitHub's version"), async () =>
            {
                if (model.Git is { } git)
                {
                    try { Shell.Open(await new SyncEngine(new GitClient(repo.Path, git)).ExportRemoteVersionAsync(file.Path)); } catch { }
                }
            });
            var grid = Ui.Grid("*,auto");
            grid.Children.Add(Ui.Column(2, Ui.Text(file.Path, 13, FontWeights.SemiBold), Ui.Caption(file.Description), compare).At(0, 0));
            grid.Children.Add(combo.At(0, 1));
            rows.Children.Add(grid);
        }
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = L.T("解决冲突", "Resolve Conflicts"),
            Content = new ScrollViewer
            {
                Content = Ui.Column(12, Ui.Caption(L.T("「保留两者」会保留你的版本，并把 GitHub 上的版本另存为「文件名 (远程版本 日期)」。解决前会创建备份。",
                                                         "Keep Both keeps yours and saves GitHub's as “name (GitHub version date)”. A backup is made first."), wrap: true), rows),
                MaxHeight = 520,
            },
            PrimaryButtonText = L.T("按所选方式解决", "Resolve"),
            CloseButtonText = L.T("取消", "Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var selected = choices.ToDictionary(c => c.Key, c => (ConflictChoice)((ComboBoxItem)c.Value.SelectedItem).Tag);
        await model.ResolveConflictsAsync(id, selected);
    }
}

/// <summary>How much space files and history take, and which files take most of the history.</summary>
public sealed class StorageDialog(AppModel model, Guid id)
{
    public async Task ShowAsync(XamlRoot root)
    {
        var state = model.State(id);
        var body = Ui.Column(10);
        if (state.Usage is { } usage)
        {
            body.Children.Add(Ui.Text(L.T($"文件 {Ui.Bytes(usage.FileBytes)} · 历史 {Ui.Bytes(usage.HistoryBytes)}", $"Files {Ui.Bytes(usage.FileBytes)} · history {Ui.Bytes(usage.HistoryBytes)}"), 15, FontWeights.SemiBold));
            body.Children.Add(Ui.Caption(usage.Level switch
            {
                UsageLevel.VeryLarge => L.T("历史超过 5 GB，GitHub 可能会发出警告。考虑把大文件移出仓库。", "History is over 5 GB; GitHub may warn. Consider moving large files out."),
                UsageLevel.Large => L.T("历史超过 GitHub 推荐的 1 GB。Word、PPT、图片每次修改都会多存一份。", "History is over GitHub's recommended 1 GB. Word, PowerPoint and images add a full copy per change."),
                _ => L.T("大小正常。历史会随修改次数慢慢增加，每个版本都可以在「历史版本」中找回。", "The size is fine. History grows with every change; each version can be restored."),
            }, wrap: true));
        }
        var list = Ui.Column(4, Ui.Caption(L.T("正在统计历史中占用最多的文件…", "Finding the files that take the most history…")));
        body.Children.Add(list);
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = L.T("空间占用", "Disk Usage"),
            Content = new ScrollViewer { Content = body, MaxHeight = 520 },
            CloseButtonText = L.T("好", "OK"),
        };
        _ = Task.Run(async () =>
        {
            List<HistoryFileUsage> largest = [];
            if (model.Git is { } git && model.Repository(id) is { } repo)
            {
                try { largest = await new RepositoryUsageScanner(new GitClient(repo.Path, git)).LargestFilesAsync(); } catch { }
            }
            DispatcherQueueExtensions.RunOnUi(() =>
            {
                list.Children.Clear();
                list.Children.Add(Ui.Text(L.T("历史中占用最多的文件", "Largest in history"), 13, FontWeights.SemiBold));
                foreach (var file in largest)
                {
                    var row = Ui.Grid("*,auto");
                    row.Children.Add(Ui.Text(file.Path, 12).Tooltip(file.Path).At(0, 0));
                    row.Children.Add(Ui.Caption(L.T($"{file.Versions} 个版本 · {Ui.Bytes(file.StoredBytes)}", $"{file.Versions} versions · {Ui.Bytes(file.StoredBytes)}")).At(0, 1));
                    list.Children.Add(row);
                }
            });
        });
        await model.RefreshUsageAsync(id, force: true);
        await dialog.ShowAsync();
    }
}

public static class ErrorDetailDialog
{
    public static async Task ShowAsync(XamlRoot root, SyncFailure failure)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = failure.Explanation,
            Content = new ScrollViewer { Content = Ui.Text(failure.FullReport, 12, wrap: true, selectable: true), MaxHeight = 480 },
            PrimaryButtonText = L.T("复制", "Copy"),
            CloseButtonText = L.T("关闭", "Close"),
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) Shell.CopyText(failure.FullReport);
    }
}

/// <summary>
/// The account's repositories on GitHub, including ones with no folder here: download one as a
/// synced folder, open it on GitHub, or delete one that is no longer needed.
/// </summary>
public sealed class GitHubRepositoriesDialog(AppModel model)
{
    List<GitHubRepositorySummary> repositories = [];

    public async Task ShowAsync(XamlRoot root)
    {
        var search = new TextBox { PlaceholderText = L.T("搜索仓库名或简介", "Search names and descriptions") };
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, Height = 330 };
        var status = Ui.Caption(L.T("正在读取 GitHub 上的仓库…", "Loading your GitHub repositories…"));
        var parent = model.DefaultDownloadFolder;
        var destination = Ui.Caption("", wrap: true);
        var autoSync = new CheckBox { Content = L.T("下载后开启自动同步", "Turn on Auto Sync after downloading"), IsChecked = true };
        var message = new InfoBar { IsOpen = false, IsClosable = true };
        var confirmDelete = new InfoBar { IsOpen = false, IsClosable = false, Severity = InfoBarSeverity.Error };
        var openOnGitHub = Ui.Button(L.T("在 GitHub 打开", "Open on GitHub"), () => { if (Selected(list) is { } r) Shell.Open(r.HtmlUrl); }, Glyph.Globe);
        var delete = Ui.Button(L.T("删除…", "Delete…"), () => { }, Glyph.Delete);
        var change = Ui.Button(L.T("更改…", "Change…"), () => { }, Glyph.Folder);

        void Render()
        {
            var query = search.Text.Trim();
            list.Items.Clear();
            foreach (var repo in repositories.Where(r => query.Length == 0 || r.FullName.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
                                                         (r.Description?.Contains(query, StringComparison.CurrentCultureIgnoreCase) ?? false)))
            {
                var existing = model.ExistingRepository(repo);
                var details = new List<string>();
                if (repo.PushedAt is { } pushed) details.Add(L.T($"{Ui.Relative(pushed)}更新", $"Updated {Ui.Relative(pushed)}"));
                details.Add(Ui.Bytes(repo.Size * 1024));
                if (repo.IsArchived) details.Add(L.T("已归档", "Archived"));
                if (!string.IsNullOrEmpty(repo.Description)) details.Add(repo.Description);
                var row = Ui.Grid("24,*,auto");
                row.Children.Add(Ui.Icon(repo.IsPrivate ? Glyph.Lock : Glyph.Globe, 13, Ui.Secondary).At(0, 0));
                row.Children.Add(Ui.Column(0, Ui.Text(repo.FullName, 13), Ui.Caption(string.Join(" · ", details))).At(0, 1));
                row.Children.Add(Ui.Caption(existing != null ? L.T("已在列表中", "In the list") : L.T("不在本机", "Not on this PC")).At(0, 2));
                row.Opacity = existing == null ? 1 : 0.55;
                list.Items.Add(new ListViewItem { Content = row, Tag = repo });
            }
            status.Text = repositories.Count == 0 ? L.T("这个账号在 GitHub 上还没有仓库", "This account has no repositories yet")
                        : list.Items.Count == 0 ? L.T("没有匹配的仓库", "No matching repositories") : "";
            UpdateSelection();
        }

        void UpdateSelection()
        {
            var selected = Selected(list);
            var listed = selected != null && model.ExistingRepository(selected) != null;
            destination.Text = selected == null ? L.T($"下载到 {parent}\\…", $"Download to {parent}\\…") : L.T($"下载到 {Path.Combine(parent, selected.Name)}", $"Download to {Path.Combine(parent, selected.Name)}");
            openOnGitHub.IsEnabled = selected != null;
            delete.IsEnabled = selected != null && !listed;
            confirmDelete.IsOpen = false;
        }

        search.TextChanged += (_, _) => Render();
        list.SelectionChanged += (_, _) => UpdateSelection();

        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = L.T("GitHub 上的仓库", "Repositories on GitHub"),
            PrimaryButtonText = L.T("下载", "Download"),
            CloseButtonText = L.T("完成", "Done"),
            DefaultButton = ContentDialogButton.Primary,
        };

        change.Click += async (_, _) =>
        {
            var picker = new Windows.Storage.Pickers.FolderPicker();
            picker.FileTypeFilter.Add("*");
            if (root.ContentIslandEnvironment?.AppWindowId is { } windowId)
                WinRT.Interop.InitializeWithWindow.Initialize(picker, Microsoft.UI.Win32Interop.GetWindowFromWindowId(windowId));
            if (await picker.PickSingleFolderAsync() is { } folder) { parent = folder.Path; UpdateSelection(); }
        };
        delete.Click += (_, _) =>
        {
            if (Selected(list) is not { } repo) return;
            confirmDelete.Title = L.T($"永久删除 GitHub 上的「{repo.FullName}」？", $"Permanently delete “{repo.FullName}” on GitHub?");
            confirmDelete.Message = L.T("仓库里的所有文件和历史版本都会被删除，无法恢复。这台电脑上没有它的文件夹，删除后就再也找不回来了；如果还想保留，请先下载。",
                                        "All its files and history are deleted for good. There's no folder for it here; to keep it, download it first.");
            confirmDelete.ActionButton = Ui.Button(L.T("永久删除", "Delete Permanently"), async () =>
            {
                var outcome = await model.DeleteGitHubRepositoryAsync(repo);
                confirmDelete.IsOpen = false;
                if (outcome is DeletionOutcome.Done) { repositories.Remove(repo); Render(); return; }
                message.Severity = InfoBarSeverity.Error;
                message.Title = outcome is DeletionOutcome.NeedsDeleteScope ? L.T("当前登录的令牌没有删除仓库的权限（delete_repo）", "The signed-in token can't delete repositories")
                                                                             : L.T("没有删除成功", "Couldn't delete it");
                message.Message = outcome is DeletionOutcome.Failed f ? f.Message : "gh auth refresh -h github.com -s delete_repo";
                message.IsOpen = true;
            }, accent: true);
            confirmDelete.IsOpen = true;
        };

        dialog.Content = Ui.Column(10,
            Ui.Caption(L.T("下载到这台电脑开始同步，或删除不再需要的仓库。", "Download one to this PC to start syncing, or delete ones you no longer need."), wrap: true),
            search, status, list, confirmDelete, message,
            Ui.Row(8, openOnGitHub, delete),
            Ui.Grid().Also(g => { g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); g.Children.Add(destination.At(0, 0)); g.Children.Add(change.At(0, 1)); }),
            autoSync);
        ((StackPanel)dialog.Content).Width = 560;

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (Selected(list) is not { } repo) return;
            if (model.ExistingRepository(repo) is { } existing)
            {
                message.Severity = InfoBarSeverity.Informational;
                message.Title = L.T($"已经在列表中：「{existing.DisplayName}」", $"Already in the list as “{existing.DisplayName}”");
                message.IsOpen = true;
                return;
            }
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            message.Severity = InfoBarSeverity.Informational;
            message.Title = L.T("正在下载…", "Downloading…");
            message.IsOpen = true;
            var problem = await model.DownloadFromGitHubAsync(repo, Path.Combine(parent, repo.Name), autoSync.IsChecked == true);
            dialog.IsPrimaryButtonEnabled = true;
            if (problem == null) { deferral.Complete(); dialog.Hide(); return; }
            message.Severity = InfoBarSeverity.Error;
            message.Title = L.T("下载失败", "Download failed");
            message.Message = problem;
            deferral.Complete();
        };

        _ = Task.Run(async () =>
        {
            try
            {
                var loaded = await model.GitHubRepositoriesAsync();
                DispatcherQueueExtensions.RunOnUi(() => { repositories = loaded; Render(); });
            }
            catch (Exception error)
            {
                DispatcherQueueExtensions.RunOnUi(() => status.Text = L.T($"无法读取 GitHub 上的仓库：{error.Message}", $"Couldn't load your GitHub repositories: {error.Message}"));
            }
        });
        UpdateSelection();
        await dialog.ShowAsync();
    }

    static GitHubRepositorySummary? Selected(ListView list) => (list.SelectedItem as ListViewItem)?.Tag as GitHubRepositorySummary;
}

static class FluentExtensions
{
    public static T Also<T>(this T value, Action<T> configure)
    {
        configure(value);
        return value;
    }
}

using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.Text;

namespace GitSync.App.Views;

/// <summary>Segoe Fluent Icons glyphs used across the app.</summary>
public static class Glyph
{
    public const string Sync = "", Refresh = "", Settings = "", Logs = "", History = "",
        Folder = "", FolderOpen = "", Globe = "", More = "", Add = "", Delete = "",
        Download = "", Upload = "", Pause = "", Play = "", Check = "", Error = "",
        Warning = "", Info = "", Search = "", Filter = "", Back = "", ChevronDown = "",
        Copy = "", Open = "", Cloud = "", Power = "", Window = "", Document = "",
        Undo = "", Compare = "", Lock = "", Clock = "", Storage = "", Account = "",
        Save = "", Eye = "", Restore = "", Merge = "", Question = "", List = "";
}

/// <summary>Small builders that keep the C#-built interface readable.</summary>
public static class Ui
{
    public static FontIcon Icon(string glyph, double size = 16, Brush? brush = null)
    {
        var icon = new FontIcon { Glyph = glyph, FontSize = size };
        if (brush != null) icon.Foreground = brush;
        return icon;
    }

    public static TextBlock Text(string text, double size = 14, FontWeight? weight = null, Brush? brush = null,
                                 bool wrap = false, bool selectable = false)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            TextWrapping = wrap ? TextWrapping.WrapWholeWords : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
            IsTextSelectionEnabled = selectable,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (weight is { } w) block.FontWeight = w;
        if (brush != null) block.Foreground = brush;
        return block;
    }

    public static TextBlock Caption(string text, bool wrap = false) => Text(text, 12, brush: Secondary, wrap: wrap);
    public static TextBlock Title(string text, double size = 20) => Text(text, size, FontWeights.SemiBold);

    public static Brush Secondary => Resource("TextFillColorSecondaryBrush");
    public static Brush Tertiary => Resource("TextFillColorTertiaryBrush");
    public static Brush Accent => Resource("AccentTextFillColorPrimaryBrush");
    public static Brush CardBackground => Resource("CardBackgroundFillColorDefaultBrush");
    public static Brush CardStroke => Resource("CardStrokeColorDefaultBrush");
    public static Brush SubtleFill => Resource("SubtleFillColorSecondaryBrush");
    public static Brush Divider => Resource("DividerStrokeColorDefaultBrush");

    public static SolidColorBrush Solid(Color color) => new(color);
    public static readonly SolidColorBrush Green = new(Color.FromArgb(255, 16, 137, 62));
    public static readonly SolidColorBrush Orange = new(Color.FromArgb(255, 202, 80, 16));
    public static readonly SolidColorBrush Red = new(Color.FromArgb(255, 196, 43, 28));
    public static readonly SolidColorBrush Blue = new(Color.FromArgb(255, 0, 103, 192));
    public static readonly SolidColorBrush Gray = new(Color.FromArgb(255, 128, 128, 128));

    public static SolidColorBrush Tint(SolidColorBrush brush, byte alpha) =>
        new(Color.FromArgb(alpha, brush.Color.R, brush.Color.G, brush.Color.B));

    static Brush Resource(string key) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush ? brush : new SolidColorBrush(Colors.Gray);

    public static StackPanel Row(double spacing = 8, params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing, VerticalAlignment = VerticalAlignment.Center };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    public static StackPanel Column(double spacing = 8, params UIElement[] children)
    {
        var panel = new StackPanel { Spacing = spacing };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    /// <summary>Content with a glyph in front, for buttons.</summary>
    public static StackPanel Label(string glyph, string text, double iconSize = 14) =>
        Row(8, Icon(glyph, iconSize), new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });

    public static Button Button(string text, Action onClick, string? glyph = null, bool accent = false, string? tooltip = null)
    {
        var button = new Button { Content = glyph == null ? text : Label(glyph, text) };
        if (accent) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        button.Click += (_, _) => onClick();
        if (tooltip != null) ToolTipService.SetToolTip(button, tooltip);
        return button;
    }

    public static Button IconButton(string glyph, string tooltip, Action onClick, double size = 16)
    {
        var button = new Button
        {
            Content = Icon(glyph, size),
            Padding = new Thickness(8, 6, 8, 6),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(button, tooltip);
        AutomationProperties(button, tooltip);
        button.Click += (_, _) => onClick();
        return button;
    }

    public static HyperlinkButton Link(string text, Action onClick)
    {
        var link = new HyperlinkButton { Content = text, Padding = new Thickness(0), FontSize = 12, MinHeight = 0 };
        link.Click += (_, _) => onClick();
        return link;
    }

    public static void AutomationProperties(UIElement element, string name) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, name);

    /// <summary>A rounded card in the system style.</summary>
    public static Border Card(UIElement child, Thickness? padding = null) => new()
    {
        Child = child,
        Padding = padding ?? new Thickness(12, 8, 12, 8),
        CornerRadius = new CornerRadius(8),
        Background = CardBackground,
        BorderBrush = CardStroke,
        BorderThickness = new Thickness(1),
    };

    /// <summary>A small coloured capsule, like "未同步" or "已修改".</summary>
    public static Border Badge(string text, SolidColorBrush color) => new()
    {
        Child = new TextBlock { Text = text, FontSize = 11, Foreground = color },
        Padding = new Thickness(6, 1, 6, 1),
        CornerRadius = new CornerRadius(8),
        Background = Tint(color, 32),
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static Grid Grid(string columns = "", string rows = "")
    {
        var grid = new Grid();
        foreach (var c in columns.Split(',', StringSplitOptions.RemoveEmptyEntries)) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Length(c) });
        foreach (var r in rows.Split(',', StringSplitOptions.RemoveEmptyEntries)) grid.RowDefinitions.Add(new RowDefinition { Height = Length(r) });
        return grid;
    }

    static GridLength Length(string spec)
    {
        spec = spec.Trim();
        if (spec == "auto") return GridLength.Auto;
        if (spec.EndsWith('*')) return new GridLength(spec.Length == 1 ? 1 : double.Parse(spec[..^1]), GridUnitType.Star);
        return new GridLength(double.Parse(spec));
    }

    public static T At<T>(this T element, int row = 0, int column = 0, int columnSpan = 1, int rowSpan = 1) where T : FrameworkElement
    {
        Microsoft.UI.Xaml.Controls.Grid.SetRow(element, row);
        Microsoft.UI.Xaml.Controls.Grid.SetColumn(element, column);
        if (columnSpan > 1) Microsoft.UI.Xaml.Controls.Grid.SetColumnSpan(element, columnSpan);
        if (rowSpan > 1) Microsoft.UI.Xaml.Controls.Grid.SetRowSpan(element, rowSpan);
        return element;
    }

    public static T Margin<T>(this T element, double left, double top, double right, double bottom) where T : FrameworkElement
    {
        element.Margin = new Thickness(left, top, right, bottom);
        return element;
    }

    public static T Tooltip<T>(this T element, string text) where T : FrameworkElement
    {
        ToolTipService.SetToolTip(element, text);
        return element;
    }

    public static MenuFlyoutItem MenuItem(string text, Action onClick, string? glyph = null, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        if (glyph != null) item.Icon = Icon(glyph);
        item.Click += (_, _) => onClick();
        return item;
    }

    /// <summary>A message box with up to three buttons; returns the button pressed.</summary>
    public static async Task<ContentDialogResult> Ask(XamlRoot root, string title, string message, string primary,
                                                      string? secondary = null, string close = "", bool destructive = false)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = title,
            Content = new ScrollViewer { Content = Text(message, wrap: true, selectable: true), MaxHeight = 420 },
            PrimaryButtonText = primary,
            SecondaryButtonText = secondary ?? "",
            CloseButtonText = close.Length > 0 ? close : GitSync.Core.L.T("取消", "Cancel"),
            DefaultButton = destructive ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        return await dialog.ShowAsync();
    }

    public static Task Inform(XamlRoot root, string title, string message) =>
        Ask(root, title, message, GitSync.Core.L.T("好", "OK"), close: "").ContinueWith(_ => { }, TaskScheduler.Current);

    public static string Bytes(long bytes) => GitSync.Core.SyncEngine.FormatBytes(bytes);

    /// <summary>"3 分钟前" / "3 minutes ago".</summary>
    public static string Relative(DateTimeOffset? date)
    {
        if (date is not { } value) return GitSync.Core.L.T("从未", "never");
        var span = DateTimeOffset.Now - value;
        if (span.TotalSeconds < 60) return GitSync.Core.L.T("刚刚", "just now");
        if (span.TotalMinutes < 60) return GitSync.Core.L.T($"{(int)span.TotalMinutes} 分钟前", $"{(int)span.TotalMinutes} min ago");
        if (span.TotalHours < 24) return GitSync.Core.L.T($"{(int)span.TotalHours} 小时前", $"{(int)span.TotalHours} h ago");
        if (span.TotalDays < 7) return GitSync.Core.L.T($"{(int)span.TotalDays} 天前", $"{(int)span.TotalDays} days ago");
        return Date(value);
    }

    public static string Date(DateTimeOffset date) => date.ToLocalTime().ToString(GitSync.Core.L.IsChinese ? "M月d日 HH:mm" : "MMM d, HH:mm",
                                                                                   System.Globalization.CultureInfo.CurrentCulture);
}

public static class DispatcherQueueExtensions
{
    public static DispatcherQueue? Queue { get; set; }

    /// <summary>Runs on the UI thread (immediately when already there).</summary>
    public static void RunOnUi(Action action)
    {
        var queue = Queue ?? DispatcherQueue.GetForCurrentThread();
        if (queue == null || queue.HasThreadAccess) action();
        else queue.TryEnqueue(() => action());
    }
}

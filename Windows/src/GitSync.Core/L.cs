namespace GitSync.Core;

/// <summary>
/// Interface language. Every user-visible string is written as <c>L.T("中文", "English")</c>,
/// so both languages live next to each other and nothing can be left untranslated.
/// </summary>
public static class L
{
    /// <summary>"zh" or "en". Set once at startup from the user's setting or the system language.</summary>
    public static string Language { get; set; } = DetectSystemLanguage();

    public static bool IsChinese => Language == "zh";

    public static string T(string chinese, string english) => IsChinese ? chinese : english;

    public static string DetectSystemLanguage()
    {
        var name = System.Globalization.CultureInfo.CurrentUICulture.Name;
        return name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh" : "en";
    }

    /// <summary>Joins parts with the separator of the current language ("，" or ", ").</summary>
    public static string Join(IEnumerable<string> parts) => string.Join(T("，", ", "), parts);

    /// <summary>"、" in Chinese, ", " in English.</summary>
    public static string ListSeparator => T("、", ", ");
}

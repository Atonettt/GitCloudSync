using System.Runtime.Versioning;
using Microsoft.Win32;

namespace GitSync.Core;

/// <summary>
/// The proxy set in Windows settings (by Clash, v2rayN…) as the environment variables git
/// understands. git ignores the system setting on its own, so without this GitSync would connect
/// to GitHub directly even when every other app goes through the proxy.
/// </summary>
public static class SystemProxy
{
    static readonly string[] VariableNames = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"];

    /// <summary>Adds the system proxy to <paramref name="baseEnvironment"/> unless it already names a proxy.</summary>
    public static Dictionary<string, string> Applying(IReadOnlyDictionary<string, string> baseEnvironment,
                                                      (bool Enabled, string? Server, string? Override)? settings = null)
    {
        var env = new Dictionary<string, string>(baseEnvironment, StringComparer.OrdinalIgnoreCase);
        if (VariableNames.Any(name => !string.IsNullOrEmpty(env.GetValueOrDefault(name)))) return env;
        var proxy = settings ?? Read();
        foreach (var (key, value) in Environment(proxy.Enabled, proxy.Server, proxy.Override))
            env.TryAdd(key, value);
        return env;
    }

    static (bool Enabled, string? Server, string? Override) Read()
    {
        if (!OperatingSystem.IsWindows()) return (false, null, null);
        return ReadWindows();
    }

    [SupportedOSPlatform("windows")]
    static (bool, string?, string?) ReadWindows()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
            if (key == null) return (false, null, null);
            var enabled = Convert.ToInt32(key.GetValue("ProxyEnable") ?? 0) != 0;
            return (enabled, key.GetValue("ProxyServer") as string, key.GetValue("ProxyOverride") as string);
        }
        catch
        {
            return (false, null, null);
        }
    }

    /// <summary>
    /// Maps the Windows proxy setting. <paramref name="server"/> is "host:port" for every protocol,
    /// or "http=host:port;https=host:port;socks=host:port".
    /// </summary>
    public static Dictionary<string, string> Environment(bool enabled, string? server, string? overrideList)
    {
        var env = new Dictionary<string, string>();
        if (!enabled || string.IsNullOrWhiteSpace(server)) return env;

        string? http = null, https = null, socks = null;
        if (server.Contains('='))
        {
            foreach (var part in server.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                var pair = part.Split('=', 2);
                if (pair.Length != 2) continue;
                switch (pair[0].ToLowerInvariant())
                {
                    case "http": http = pair[1]; break;
                    case "https": https = pair[1]; break;
                    case "socks": socks = pair[1]; break;
                }
            }
        }
        else
        {
            http = https = server.Trim();
        }

        static string Url(string value, string scheme) => value.Contains("://") ? value : $"{scheme}://{value}";
        if ((https ?? http) is { } secure) env["https_proxy"] = env["HTTPS_PROXY"] = Url(secure, "http");
        if ((http ?? https) is { } plain) env["http_proxy"] = env["HTTP_PROXY"] = Url(plain, "http");
        if (env.Count == 0 && socks != null) env["all_proxy"] = env["ALL_PROXY"] = Url(socks, "socks5h");
        if (env.Count == 0) return env;

        var bypass = new List<string> { "localhost", "127.0.0.1", "::1" };
        foreach (var entry in (overrideList ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            // curl matches a bare domain and its subdomains; "*.local" becomes ".local".
            var item = entry.StartsWith("*.") ? entry[1..] : entry;
            if (item.Length > 0 && !item.Contains('*') && !item.Contains('<') && !bypass.Contains(item)) bypass.Add(item);
        }
        env["no_proxy"] = env["NO_PROXY"] = string.Join(",", bypass);
        return env;
    }
}

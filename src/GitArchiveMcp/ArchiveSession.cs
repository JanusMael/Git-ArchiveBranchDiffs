using System.Collections.Concurrent;
using Microsoft.Extensions.DependencyInjection;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace GitArchiveMcp;

public record ArchiveRecord(
    string ArchivePath,
    string LeftRef,
    string RightRef,
    bool ThreeWay,
    string Mode,
    long SizeBytes,
    int FileCount,
    DateTimeOffset CreatedAt);

public sealed class ArchiveSession
{
    private readonly IServiceProvider _services;
    private readonly ConcurrentBag<ArchiveRecord> _archives = [];
    private readonly ConcurrentDictionary<string, ConcurrentDictionary<string, string>> _annotations = new(StringComparer.OrdinalIgnoreCase);

    public ArchiveSession(IServiceProvider services)
    {
        _services = services;
    }

    public void Add(ArchiveRecord record)
    {
        _archives.Add(record);
        // Fire a best-effort resource-list-changed notification so clients
        // that subscribe to MCP resources learn about the new archive.
        _ = NotifyResourceListChangedAsync();
    }

    private async Task NotifyResourceListChangedAsync()
    {
        try
        {
            var server = _services.GetService<McpServer>();
            if (server is null)
                return;
            await server.SendNotificationAsync(
                NotificationMethods.ResourceListChangedNotification,
                CancellationToken.None).ConfigureAwait(false);
        }
        catch
        {
            // Notifications are best-effort. Never fail Add() because of
            // a transport hiccup or a client that does not handle them.
        }
    }

    public IReadOnlyList<ArchiveRecord> List() => [.. _archives];

    public void Annotate(string archivePath, string key, string value)
    {
        var dict = _annotations.GetOrAdd(archivePath, _ => new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase));
        dict[key] = value;
    }

    public IReadOnlyDictionary<string, string> GetAnnotations(string archivePath)
    {
        if (_annotations.TryGetValue(archivePath, out var dict))
            return dict.ToDictionary(kv => kv.Key, kv => kv.Value);
        return new Dictionary<string, string>();
    }
}

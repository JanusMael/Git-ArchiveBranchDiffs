using System.Collections.Concurrent;

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
    private readonly ConcurrentBag<ArchiveRecord> _archives = [];
    private readonly ConcurrentDictionary<string, ConcurrentDictionary<string, string>> _annotations = new(StringComparer.OrdinalIgnoreCase);

    public void Add(ArchiveRecord record) => _archives.Add(record);

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

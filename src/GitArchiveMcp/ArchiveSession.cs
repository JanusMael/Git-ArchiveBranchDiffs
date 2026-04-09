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

    public void Add(ArchiveRecord record) => _archives.Add(record);

    public IReadOnlyList<ArchiveRecord> List() => [.. _archives];
}

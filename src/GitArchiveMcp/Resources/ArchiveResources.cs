using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.DependencyInjection;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace GitArchiveMcp.Resources;

/// <summary>
/// Exposes diff archives created during the session as MCP resources.
///
/// Each archive in <see cref="ArchiveSession"/> becomes a resource under the
/// <c>archive:///</c> URI scheme. Reading a resource returns the lightweight
/// <see cref="ArchiveSummary"/> as JSON — NOT the full contents — so clients
/// can discover and scope archives without flooding their context. For full
/// contents, clients should call the <c>git_archive_read</c> tool instead.
/// </summary>
public static class ArchiveResources
{
    private const string UriScheme = "archive:///";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static ValueTask<ListResourcesResult> ListResourcesAsync(
        RequestContext<ListResourcesRequestParams> request,
        CancellationToken cancellationToken)
    {
        var session = request.Services!.GetRequiredService<ArchiveSession>();
        var archives = session.List();

        var resources = archives
            .Select(record => new Resource
            {
                Uri = BuildUri(record.ArchivePath),
                Name = Path.GetFileName(record.ArchivePath),
                Description = BuildDescription(record),
                MimeType = "application/json",
            })
            .ToList();

        return ValueTask.FromResult(new ListResourcesResult { Resources = resources });
    }

    public static ValueTask<ReadResourceResult> ReadResourceAsync(
        RequestContext<ReadResourceRequestParams> request,
        CancellationToken cancellationToken)
    {
        var uri = request.Params?.Uri
            ?? throw new InvalidOperationException("Resource URI is required.");

        if (!uri.StartsWith(UriScheme, StringComparison.Ordinal))
            throw new InvalidOperationException($"Unsupported resource URI: {uri}");

        var session = request.Services!.GetRequiredService<ArchiveSession>();
        var archiveService = request.Services!.GetRequiredService<ArchiveService>();

        var fileName = Uri.UnescapeDataString(uri[UriScheme.Length..]);
        var record = session.List()
            .FirstOrDefault(r => string.Equals(
                Path.GetFileName(r.ArchivePath), fileName, StringComparison.OrdinalIgnoreCase));

        if (record is null)
            throw new FileNotFoundException($"Archive resource not found: {fileName}");

        var summary = archiveService.GetSummary(record.ArchivePath);
        var annotations = session.GetAnnotations(record.ArchivePath);

        var payload = new
        {
            record.ArchivePath,
            record.LeftRef,
            record.RightRef,
            record.ThreeWay,
            record.Mode,
            record.SizeBytes,
            record.FileCount,
            record.CreatedAt,
            Summary = summary,
            Annotations = annotations,
        };

        var json = JsonSerializer.Serialize(payload, JsonOptions);

        return ValueTask.FromResult(new ReadResourceResult
        {
            Contents =
            [
                new TextResourceContents
                {
                    Uri = uri,
                    MimeType = "application/json",
                    Text = json,
                }
            ],
        });
    }

    private static string BuildUri(string archivePath)
    {
        var fileName = Path.GetFileName(archivePath);
        return UriScheme + Uri.EscapeDataString(fileName);
    }

    private static string BuildDescription(ArchiveRecord record)
    {
        var refs = record.Mode switch
        {
            "workingTree" => $"{record.LeftRef} vs working tree",
            "staged" => $"{record.LeftRef} vs staged index",
            _ => record.ThreeWay
                ? $"{record.LeftRef} ↔ {record.RightRef} (three-way)"
                : $"{record.LeftRef} → {record.RightRef}",
        };
        return $"Diff archive: {refs} ({record.FileCount} files, {record.SizeBytes} bytes)";
    }
}

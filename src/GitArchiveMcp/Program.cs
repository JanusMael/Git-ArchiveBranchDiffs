using GitArchiveMcp;
using GitArchiveMcp.Resources;
using GitArchiveMcp.Tools;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using ModelContextProtocol;

var builder = Host.CreateApplicationBuilder(args);

builder.Logging.AddConsole(options =>
{
    options.LogToStandardErrorThreshold = LogLevel.Trace;
});

builder.Services.AddSingleton<ArchiveSession>();
builder.Services.AddSingleton<ArchiveService>();

builder.Services
    .AddMcpServer()
    .WithStdioServerTransport()
    .WithToolsFromAssembly()
    .WithPromptsFromAssembly()
    .WithListResourcesHandler(ArchiveResources.ListResourcesAsync)
    .WithReadResourceHandler(ArchiveResources.ReadResourceAsync);

await builder.Build().RunAsync();

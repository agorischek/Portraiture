using Microsoft.Extensions.Logging;

namespace Portraiture;

/// <summary>Event ids used for capture lifecycle and stream logging.</summary>
public static class CaptureLogEvents
{
    /// <summary>A capture is starting. Logged at Information.</summary>
    public static readonly EventId Started = new(1000, nameof(Started));

    /// <summary>A stdout chunk was read. Logged at Trace.</summary>
    public static readonly EventId Stdout = new(1001, nameof(Stdout));

    /// <summary>A stderr chunk was read. Logged at Trace.</summary>
    public static readonly EventId Stderr = new(1002, nameof(Stderr));

    /// <summary>A capture completed successfully. Logged at Information.</summary>
    public static readonly EventId Succeeded = new(1003, nameof(Succeeded));

    /// <summary>A capture failed. Logged at Warning.</summary>
    public static readonly EventId Failed = new(1004, nameof(Failed));
}

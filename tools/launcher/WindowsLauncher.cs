using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;

internal static class Program
{
    private static readonly byte[] Marker = Encoding.ASCII.GetBytes("NETRAY_PAYLOAD_V1\0");

    private static int Main(string[] args)
    {
        string executablePath = Process.GetCurrentProcess().MainModule != null
            ? Process.GetCurrentProcess().MainModule.FileName
            : null;
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            Console.Error.WriteLine("Could not determine launcher path.");
            return 1;
        }

        string tempRoot = Path.Combine(Path.GetTempPath(), "netray-cli", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);

        try
        {
            string payloadZipPath = Path.Combine(tempRoot, "payload.zip");
            ExtractEmbeddedPayload(executablePath, payloadZipPath);

            string payloadDir = Path.Combine(tempRoot, "payload");
            ZipFile.ExtractToDirectory(payloadZipPath, payloadDir);

            string lunePath = Path.Combine(payloadDir, "lune.exe");
            string scriptPath = Path.Combine(payloadDir, "cli", "netray.luau");
            if (!File.Exists(lunePath))
            {
                Console.Error.WriteLine("Embedded payload is missing lune.exe.");
                return 1;
            }

            if (!File.Exists(scriptPath))
            {
                Console.Error.WriteLine("Embedded payload is missing cli/netray.luau.");
                return 1;
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = lunePath,
                Arguments = BuildArguments(scriptPath, args),
                WorkingDirectory = Environment.CurrentDirectory,
                UseShellExecute = false,
            };

            if (Environment.GetEnvironmentVariable("NETRAY_DEBUG_LAUNCHER") == "1")
            {
                Console.Error.WriteLine("launcher exe: " + executablePath);
                Console.Error.WriteLine("payload dir: " + payloadDir);
                Console.Error.WriteLine("lune path: " + lunePath);
                Console.Error.WriteLine("script path: " + scriptPath);
                Console.Error.WriteLine("working dir: " + startInfo.WorkingDirectory);
                Console.Error.WriteLine("arguments: " + startInfo.Arguments);
            }

            using (Process child = Process.Start(startInfo))
            {
                if (child == null)
                {
                    Console.Error.WriteLine("Failed to start the embedded Lune runtime.");
                    return 1;
                }

                child.WaitForExit();
                return child.ExitCode;
            }
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
        finally
        {
            try
            {
                if (Directory.Exists(tempRoot))
                {
                    Directory.Delete(tempRoot, true);
                }
            }
            catch
            {
                // Best-effort cleanup only.
            }
        }
    }

    private static void ExtractEmbeddedPayload(string executablePath, string outputZipPath)
    {
        byte[] exeBytes = File.ReadAllBytes(executablePath);
        int markerIndex = FindMarkerIndex(exeBytes);
        if (markerIndex < 0)
        {
            throw new InvalidOperationException("No embedded payload was found in the launcher.");
        }

        int payloadOffset = markerIndex + Marker.Length;
        int payloadLength = exeBytes.Length - payloadOffset;
        if (payloadLength <= 0)
        {
            throw new InvalidOperationException("The embedded payload is empty.");
        }

        using (var output = new FileStream(outputZipPath, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            output.Write(exeBytes, payloadOffset, payloadLength);
        }
    }

    private static int FindMarkerIndex(byte[] data)
    {
        for (int index = data.Length - Marker.Length; index >= 0; index--)
        {
            bool matched = true;
            for (int markerOffset = 0; markerOffset < Marker.Length; markerOffset++)
            {
                if (data[index + markerOffset] != Marker[markerOffset])
                {
                    matched = false;
                    break;
                }
            }

            if (matched)
            {
                return index;
            }
        }

        return -1;
    }

    private static string BuildArguments(string scriptPath, string[] args)
    {
        var rendered = new[] { "run", scriptPath }
            .Concat(args)
            .Select(QuoteArgument);
        return string.Join(" ", rendered);
    }

    private static string QuoteArgument(string argument)
    {
        if (argument.Length == 0)
        {
            return "\"\"";
        }

        bool needsQuotes = argument.Any(character => char.IsWhiteSpace(character) || character == '"');
        if (!needsQuotes)
        {
            return argument;
        }

        var builder = new StringBuilder();
        builder.Append('"');

        int backslashCount = 0;
        foreach (char character in argument)
        {
            if (character == '\\')
            {
                backslashCount++;
                continue;
            }

            if (character == '"')
            {
                builder.Append('\\', backslashCount * 2 + 1);
                builder.Append('"');
                backslashCount = 0;
                continue;
            }

            if (backslashCount > 0)
            {
                builder.Append('\\', backslashCount);
                backslashCount = 0;
            }

            builder.Append(character);
        }

        if (backslashCount > 0)
        {
            builder.Append('\\', backslashCount * 2);
        }

        builder.Append('"');
        return builder.ToString();
    }
}

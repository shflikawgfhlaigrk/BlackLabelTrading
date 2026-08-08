// Black Label Trading — MSIX entry-point launcher.
//
// MSIX requires Application/@Executable to be a real PE image; launch-trading.cmd cannot be it.
// This is the smallest honest bridge: resolve our own directory inside the installed package,
// start the BUNDLED pythonw.exe on supervise.py, and stay alive for exactly as long as the
// supervisor does so Windows sees one process that represents the running app.
//
// It adds no behaviour of its own. It reads no configuration, opens no network socket, and
// resolves nothing outside the package directory. Black Label Trading is SIGNALS-ONLY; nothing
// here can place, route, modify or cancel an order.
//
// Compiled on the Windows runner with the in-box .NET Framework compiler:
//   csc.exe /nologo /target:winexe /platform:x64 /out:BlackLabelTrading.exe Launcher.cs

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

internal static class Launcher
{
    // Exit codes are distinct from any the supervisor uses so a packaging fault is
    // never read as an application fault.
    private const int ExitRuntimeMissing = 90;
    private const int ExitSupervisorMissing = 91;
    private const int ExitSpawnFailed = 92;

    private static int Main(string[] args)
    {
        string here = Path.GetDirectoryName(new Uri(Assembly.GetExecutingAssembly().CodeBase).LocalPath);

        // pythonw.exe first: it is the windowless host, so the packaged app does not flash a
        // console. python.exe is the fallback for a stage assembled without it.
        string python = Path.Combine(here, "python", "pythonw.exe");
        if (!File.Exists(python))
        {
            python = Path.Combine(here, "python", "python.exe");
        }
        if (!File.Exists(python))
        {
            Fail("Bundled Python runtime is missing from this installation.\n\n"
                 + "Expected: " + Path.Combine(here, "python") + "\n\n"
                 + "Reinstall Black Label Trading.");
            return ExitRuntimeMissing;
        }

        string supervisor = Path.Combine(here, "supervise.py");
        if (!File.Exists(supervisor))
        {
            Fail("supervise.py is missing from this installation.\n\n"
                 + "Expected: " + supervisor + "\n\n"
                 + "Reinstall Black Label Trading.");
            return ExitSupervisorMissing;
        }

        ProcessStartInfo psi = new ProcessStartInfo(python);
        psi.Arguments = BuildArguments(supervisor, args);
        psi.WorkingDirectory = here;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;

        try
        {
            using (Process child = Process.Start(psi))
            {
                if (child == null)
                {
                    Fail("Black Label Trading could not start its backend process.");
                    return ExitSpawnFailed;
                }
                child.WaitForExit();
                return child.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Fail("Black Label Trading could not start its backend process.\n\n" + ex.Message);
            return ExitSpawnFailed;
        }
    }

    // Windows command lines are a single string; quote every argument so a package path
    // containing spaces (the normal case under WindowsApps) is passed through intact.
    private static string BuildArguments(string script, string[] args)
    {
        StringBuilder sb = new StringBuilder();
        sb.Append(Quote(script));
        foreach (string a in args)
        {
            sb.Append(' ').Append(Quote(a));
        }
        return sb.ToString();
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static void Fail(string message)
    {
        // WinExe has no console, so a startup fault must be visible or it is silent.
        try
        {
            MessageBox(IntPtr.Zero, message, "Black Label Trading", 0x00000010 /* MB_ICONERROR */);
        }
        catch
        {
            // If even the message box is unavailable there is nothing further to do;
            // the non-zero exit code is the remaining signal.
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int MessageBox(IntPtr hWnd, string text, string caption, uint type);
}

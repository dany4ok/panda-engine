using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Panda Engine")]
[assembly: AssemblyProduct("Panda Engine")]
[assembly: AssemblyDescription("Local model library and unified AI engine launcher")]

internal static class PandaLauncher
{
    [STAThread]
    private static void Main(string[] args)
    {
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            bool console = false;
            string extras = "";
            foreach (string arg in args)
            {
                if (string.Equals(arg, "--console", StringComparison.OrdinalIgnoreCase))
                    console = true;
                else
                    extras += " \"" + arg.Replace("\"", "\\\"") + "\"";
            }
            // gui.ps1 has no model/runtime switches. Any extra flag belongs to the
            // console manager, so route there instead of silently discarding it.
            if (!string.IsNullOrWhiteSpace(extras))
                console = true;

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.WorkingDirectory = root;
            psi.UseShellExecute = false;

            if (console)
            {
                string script = Path.Combine(root, "panda", "panda.ps1");
                if (!File.Exists(script))
                    throw new FileNotFoundException("Panda Engine console script not found", script);
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -File \"" + script + "\"" + extras;
                psi.CreateNoWindow = false;
            }
            else
            {
                string vbs = Path.Combine(root, "panda", "launch-gui.vbs");
                if (!File.Exists(vbs))
                    throw new FileNotFoundException("Panda Engine GUI launcher not found", vbs);
                psi.FileName = "wscript.exe";
                psi.Arguments = "//B //Nologo \"" + vbs + "\"";
                psi.CreateNoWindow = true;
            }

            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Panda Engine could not start:\r\n" + ex.Message,
                "Panda Engine",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }
}

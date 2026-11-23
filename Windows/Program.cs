// Wiggle for Windows: a portable tray app that nudges the cursor so the system
// and chat apps do not flag the session as idle.
//
// This file is deliberately limited to C# 5 syntax and .NET Framework 4.x APIs so
// it can be compiled with the csc.exe that ships inside Windows (see build.cmd),
// with nothing to install.
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;

[assembly: AssemblyTitle("Wiggle")]
[assembly: AssemblyProduct("Wiggle")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace Wiggle
{
    internal static class Native
    {
        public const uint InputMouse = 0;
        public const uint MouseEventMove = 0x0001;

        public const uint EsContinuous = 0x80000000;
        public const uint EsSystemRequired = 0x00000001;
        public const uint EsDisplayRequired = 0x00000002;

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        // MOUSEINPUT is the largest member of the native INPUT union, so declaring
        // only that member yields the correct size on both x86 and x64.
        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT
        {
            public uint type;
            public MOUSEINPUT mi;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct LASTINPUTINFO
        {
            public uint cbSize;
            public uint dwTime;
        }

        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT point);

        [DllImport("user32.dll")]
        public static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        public static extern uint SendInput(uint count, INPUT[] inputs, int size);

        [DllImport("user32.dll")]
        public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr handle);

        [DllImport("kernel32.dll")]
        public static extern uint SetThreadExecutionState(uint flags);

        /// <summary>Seconds since the last keyboard or mouse input in this session.</summary>
        public static double IdleSeconds()
        {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref info))
            {
                return 0;
            }
            // Both values are 32-bit tick counts; unsigned subtraction survives wraparound.
            uint elapsed = unchecked((uint)Environment.TickCount - info.dwTime);
            return elapsed / 1000.0;
        }

        public static void MoveRelative(int dx)
        {
            INPUT[] inputs = new INPUT[1];
            inputs[0].type = InputMouse;
            inputs[0].mi.dx = dx;
            inputs[0].mi.dwFlags = MouseEventMove;
            SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));
        }
    }

    /// <summary>
    /// Settings stored as key=value lines in wiggle.ini next to the executable.
    /// If the folder is read-only the settings simply do not persist.
    /// </summary>
    internal sealed class Settings
    {
        public int Interval = 30;        // seconds
        public int Distance = 2;         // pixels
        public bool OnlyWhenIdle = true;
        public bool KeepAwake = true;
        public bool Running = false;     // restored on the next launch

        private static string FilePath
        {
            get
            {
                string dir = Path.GetDirectoryName(Application.ExecutablePath);
                return Path.Combine(dir, "wiggle.ini");
            }
        }

        public static Settings Load()
        {
            Settings s = new Settings();
            try
            {
                foreach (string line in File.ReadAllLines(FilePath))
                {
                    int eq = line.IndexOf('=');
                    if (eq <= 0)
                    {
                        continue;
                    }
                    string key = line.Substring(0, eq).Trim();
                    string value = line.Substring(eq + 1).Trim();
                    int number;
                    bool flag;
                    if (key == "interval" && int.TryParse(value, out number) && number > 0)
                    {
                        s.Interval = number;
                    }
                    else if (key == "distance" && int.TryParse(value, out number) && number > 0)
                    {
                        s.Distance = number;
                    }
                    else if (key == "onlyWhenIdle" && bool.TryParse(value, out flag))
                    {
                        s.OnlyWhenIdle = flag;
                    }
                    else if (key == "keepDisplayAwake" && bool.TryParse(value, out flag))
                    {
                        s.KeepAwake = flag;
                    }
                    else if (key == "running" && bool.TryParse(value, out flag))
                    {
                        s.Running = flag;
                    }
                }
            }
            catch (Exception)
            {
                // Missing or unreadable file: keep the defaults.
            }
            return s;
        }

        public void Save()
        {
            try
            {
                File.WriteAllLines(FilePath, new string[]
                {
                    "interval=" + Interval.ToString(CultureInfo.InvariantCulture),
                    "distance=" + Distance.ToString(CultureInfo.InvariantCulture),
                    "onlyWhenIdle=" + OnlyWhenIdle,
                    "keepDisplayAwake=" + KeepAwake,
                    "running=" + Running
                });
            }
            catch (Exception)
            {
                // Read-only location: run with in-memory settings.
            }
        }
    }

    internal sealed class WiggleContext : ApplicationContext
    {
        // The idle state is checked on this short period; the user-facing "interval"
        // is the idle time after which the cursor is nudged.
        private const int PollSeconds = 2;

        private static readonly int[] IntervalChoices = { 10, 30, 60, 120, 300 };
        private static readonly int[] DistanceChoices = { 1, 2, 5, 10, 25 };

        private static readonly bool Spanish =
            CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "es";

        private readonly Settings settings;
        private readonly NotifyIcon tray;
        private readonly ContextMenuStrip menu;
        private readonly Timer timer;
        private readonly Icon iconOn;
        private readonly Icon iconOff;
        private readonly Stopwatch sinceJiggle = new Stopwatch();
        private bool running;

        public WiggleContext()
        {
            settings = Settings.Load();
            iconOn = MakeIcon(Color.FromArgb(46, 204, 113));
            iconOff = MakeIcon(Color.FromArgb(150, 150, 150));

            menu = new ContextMenuStrip();
            menu.Opening += delegate(object sender, System.ComponentModel.CancelEventArgs e)
            {
                BuildMenu();
                // An empty strip cancels its own opening; it has items now.
                e.Cancel = false;
            };

            tray = new NotifyIcon();
            tray.ContextMenuStrip = menu;
            tray.MouseUp += OnTrayMouseUp;

            timer = new Timer();
            timer.Interval = PollSeconds * 1000;
            timer.Tick += OnTick;

            SetRunning(settings.Running, false);
            tray.Visible = true;
        }

        private static string L(string english, string spanish)
        {
            return Spanish ? spanish : english;
        }

        private static string IntervalLabel(int seconds)
        {
            if (seconds < 60)
            {
                return seconds + L(" seconds", " segundos");
            }
            int minutes = seconds / 60;
            if (minutes == 1)
            {
                return L("1 minute", "1 minuto");
            }
            return minutes + L(" minutes", " minutos");
        }

        // ----- Engine -----

        private void SetRunning(bool value, bool persist)
        {
            running = value;
            if (running)
            {
                sinceJiggle.Restart();
                timer.Start();
            }
            else
            {
                timer.Stop();
            }
            ApplyKeepAwake();
            UpdateTray();
            if (persist)
            {
                settings.Running = running;
                settings.Save();
            }
        }

        private void ApplyKeepAwake()
        {
            uint flags = Native.EsContinuous;
            if (running && settings.KeepAwake)
            {
                flags |= Native.EsDisplayRequired | Native.EsSystemRequired;
            }
            Native.SetThreadExecutionState(flags);
        }

        private void OnTick(object sender, EventArgs e)
        {
            // Our own nudge may or may not reset the system idle counter, so the
            // time since the last nudge is tracked separately and the smaller wins.
            double idle = sinceJiggle.Elapsed.TotalSeconds;
            if (settings.OnlyWhenIdle)
            {
                idle = Math.Min(idle, Native.IdleSeconds());
            }
            // Fire one poll early so the idle time never exceeds the chosen interval.
            if (idle >= settings.Interval - PollSeconds)
            {
                Jiggle();
                sinceJiggle.Restart();
            }
        }

        private void Jiggle()
        {
            Native.POINT origin;
            bool havePosition = Native.GetCursorPos(out origin);
            Native.MoveRelative(settings.Distance);
            Native.MoveRelative(-settings.Distance);
            // Relative moves are clipped at screen edges and scaled by pointer
            // settings, so put the cursor back exactly where it was.
            if (havePosition)
            {
                Native.SetCursorPos(origin.X, origin.Y);
            }
        }

        // ----- Tray icon and menu -----

        private void UpdateTray()
        {
            tray.Icon = running ? iconOn : iconOff;
            tray.Text = running ? L("Wiggle: active", "Wiggle: activo")
                                : L("Wiggle: paused", "Wiggle: pausado");
        }

        private void OnTrayMouseUp(object sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left)
            {
                return; // right click is handled by ContextMenuStrip itself
            }
            // NotifyIcon only opens its menu on right click; reuse its own
            // (non-public) routine so a left click positions the menu identically.
            MethodInfo show = typeof(NotifyIcon).GetMethod(
                "ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic);
            if (show != null)
            {
                show.Invoke(tray, null);
            }
        }

        private void BuildMenu()
        {
            menu.Items.Clear();

            ToolStripMenuItem status = new ToolStripMenuItem(
                running ? L("● Active", "● Activo") : L("○ Paused", "○ Pausado"));
            status.Enabled = false;
            menu.Items.Add(status);

            menu.Items.Add(new ToolStripMenuItem(
                running ? L("Stop", "Detener") : L("Start", "Iniciar"), null,
                delegate { SetRunning(!running, true); }));

            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem intervalMenu = new ToolStripMenuItem(L("Interval", "Intervalo"));
            foreach (int choice in IntervalChoices)
            {
                int seconds = choice;
                ToolStripMenuItem item = new ToolStripMenuItem(IntervalLabel(seconds), null,
                    delegate { settings.Interval = seconds; settings.Save(); });
                item.Checked = settings.Interval == seconds;
                intervalMenu.DropDownItems.Add(item);
            }
            menu.Items.Add(intervalMenu);

            ToolStripMenuItem distanceMenu = new ToolStripMenuItem(
                L("Movement distance", "Distancia del movimiento"));
            foreach (int choice in DistanceChoices)
            {
                int pixels = choice;
                ToolStripMenuItem item = new ToolStripMenuItem(pixels + " px", null,
                    delegate { settings.Distance = pixels; settings.Save(); });
                item.Checked = settings.Distance == pixels;
                distanceMenu.DropDownItems.Add(item);
            }
            menu.Items.Add(distanceMenu);

            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem idleItem = new ToolStripMenuItem(
                L("Move only when I am idle", "Mover solo si estoy inactivo"), null,
                delegate { settings.OnlyWhenIdle = !settings.OnlyWhenIdle; settings.Save(); });
            idleItem.Checked = settings.OnlyWhenIdle;
            menu.Items.Add(idleItem);

            ToolStripMenuItem awakeItem = new ToolStripMenuItem(
                L("Keep display awake", "Mantener pantalla encendida"), null,
                delegate
                {
                    settings.KeepAwake = !settings.KeepAwake;
                    settings.Save();
                    ApplyKeepAwake();
                });
            awakeItem.Checked = settings.KeepAwake;
            menu.Items.Add(awakeItem);

            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add(new ToolStripMenuItem(
                L("Check for Updates…", "Buscar actualizaciones…"), null,
                delegate { CheckForUpdates(); }));

            menu.Items.Add(new ToolStripMenuItem(
                L("Quit Wiggle", "Salir de Wiggle"), null, delegate { Quit(); }));
        }

        // ----- Update check -----
        // Asks GitHub for the latest published release. This is the only network
        // request the app makes, and it only happens when the user asks for it.

        private const string Repository = "danielsolano/wiggle";
        private bool checkingForUpdates;

        /// <summary>Turns "v1.2.3" into {1, 2, 3}; missing or non-numeric parts count as 0.</summary>
        private static int[] VersionParts(string version)
        {
            int[] parts = new int[3];
            string[] pieces = version.TrimStart('v', 'V').Split('.');
            for (int i = 0; i < parts.Length && i < pieces.Length; i++)
            {
                int.TryParse(pieces[i], out parts[i]);
            }
            return parts;
        }

        private static bool IsNewer(string candidate, string current)
        {
            int[] a = VersionParts(candidate);
            int[] b = VersionParts(current);
            for (int i = 0; i < a.Length; i++)
            {
                if (a[i] != b[i])
                {
                    return a[i] > b[i];
                }
            }
            return false;
        }

        private void CheckForUpdates()
        {
            if (checkingForUpdates)
            {
                return;
            }
            checkingForUpdates = true;

            // GitHub requires TLS 1.2, which .NET Framework does not enable by
            // default for programs built with the compiler bundled with Windows.
            ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072;

            WebClient client = new WebClient();
            client.Headers[HttpRequestHeader.UserAgent] = "Wiggle";
            client.Headers[HttpRequestHeader.Accept] = "application/vnd.github+json";
            client.DownloadStringCompleted += OnUpdateResponse;
            try
            {
                client.DownloadStringAsync(
                    new Uri("https://api.github.com/repos/" + Repository + "/releases/latest"));
            }
            catch (Exception)
            {
                client.Dispose();
                checkingForUpdates = false;
                ShowUpdateFailure();
            }
        }

        private void OnUpdateResponse(object sender, DownloadStringCompletedEventArgs e)
        {
            ((WebClient)sender).Dispose();
            checkingForUpdates = false;

            Match tag = null;
            if (e.Error == null && !e.Cancelled)
            {
                tag = Regex.Match(e.Result, "\"tag_name\"\\s*:\\s*\"([^\"]+)\"");
            }
            if (tag == null || !tag.Success)
            {
                ShowUpdateFailure();
                return;
            }

            string latest = tag.Groups[1].Value;
            string current = Application.ProductVersion;
            if (!IsNewer(latest, current))
            {
                MessageBox.Show(
                    L("You have the latest version (", "Tienes la versión más reciente (") + current + ").",
                    L("Wiggle is up to date", "Wiggle está actualizado"),
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            DialogResult answer = MessageBox.Show(
                L("You have ", "Tienes la ") + current
                    + L(" and ", " y está disponible la ") + latest + L(" is available.", ".") + "\n\n"
                    + L("If you built Wiggle from the repository, pull the latest changes and build again.",
                        "Si compilaste Wiggle desde el repositorio, baja los últimos cambios y vuelve a compilar.")
                    + "\n\n" + L("Open the download page?", "¿Abrir la página de descarga?"),
                L("A newer version of Wiggle is available", "Hay una versión más nueva de Wiggle"),
                MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (answer == DialogResult.Yes)
            {
                try
                {
                    Process.Start("https://github.com/" + Repository + "/releases/latest");
                }
                catch (Exception)
                {
                    // No default browser available; nothing else to do.
                }
            }
        }

        private static void ShowUpdateFailure()
        {
            MessageBox.Show(
                L("GitHub could not be reached, or no release has been published yet.",
                  "No se pudo contactar a GitHub, o todavía no hay ninguna versión publicada."),
                L("Could not check for updates", "No se pudo buscar actualizaciones"),
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        private void Quit()
        {
            timer.Stop();
            Native.SetThreadExecutionState(Native.EsContinuous);
            tray.Visible = false;
            tray.Dispose();
            Native.DestroyIcon(iconOn.Handle);
            Native.DestroyIcon(iconOff.Handle);
            ExitThread();
        }

        // ----- Tray icon drawn in memory (no resource files needed) -----

        // The Wiggle "W" outline from assets/wiggle-menu.svg: a start point followed
        // by cubic segments (control 1, control 2, end point), y pointing down.
        private static readonly float[] GlyphStart = { 208, 541 };
        private static readonly float[][] GlyphSegments =
        {
            new float[] { 195, 483, 227, 444, 273, 434 }, new float[] { 327, 422, 373, 453, 382, 512 },
            new float[] { 403, 640, 397, 700, 429, 737 }, new float[] { 458, 732, 470, 671, 496, 606 },
            new float[] { 520, 542, 545, 512, 592, 512 }, new float[] { 592, 512, 657, 512, 657, 512 },
            new float[] { 728, 512, 747, 575, 771, 664 }, new float[] { 785, 720, 797, 737, 813, 737 },
            new float[] { 846, 737, 852, 631, 869, 525 }, new float[] { 879, 462, 910, 432, 960, 432 },
            new float[] { 1015, 432, 1054, 476, 1044, 536 }, new float[] { 1037, 576, 1004, 672, 977, 739 },
            new float[] { 938, 837, 884, 879, 810, 879 }, new float[] { 702, 879, 657, 787, 615, 644 },
            new float[] { 599, 683, 584, 727, 564, 766 }, new float[] { 527, 844, 480, 879, 419, 879 },
            new float[] { 342, 879, 294, 815, 259, 721 }, new float[] { 241, 671, 221, 597, 208, 541 }
        };

        private static Icon MakeIcon(Color fill)
        {
            // Where the glyph sits inside the 32x32 icon (it is wider than tall).
            RectangleF target = new RectangleF(1, 7, 30, 18);
            using (Bitmap bitmap = new Bitmap(32, 32, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bitmap))
                using (GraphicsPath path = new GraphicsPath())
                using (SolidBrush brush = new SolidBrush(fill))
                {
                    PointF current = new PointF(GlyphStart[0], GlyphStart[1]);
                    foreach (float[] s in GlyphSegments)
                    {
                        PointF end = new PointF(s[4], s[5]);
                        path.AddBezier(current, new PointF(s[0], s[1]), new PointF(s[2], s[3]), end);
                        current = end;
                    }
                    path.CloseFigure();
                    // Flatten first so the bounds follow the curve, not its control points.
                    path.Flatten();
                    PointF[] corners =
                    {
                        new PointF(target.Left, target.Top),
                        new PointF(target.Right, target.Top),
                        new PointF(target.Left, target.Bottom)
                    };
                    using (Matrix fit = new Matrix(path.GetBounds(), corners))
                    {
                        path.Transform(fit);
                    }
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.FillPath(brush, path);
                }
                // The HICON is an independent copy; it is destroyed in Quit().
                return Icon.FromHandle(bitmap.GetHicon());
            }
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            bool createdNew;
            using (System.Threading.Mutex mutex = new System.Threading.Mutex(
                true, "Local\\WiggleSingleInstance", out createdNew))
            {
                if (!createdNew)
                {
                    return; // another instance already owns the tray icon
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new WiggleContext());
            }
        }
    }
}

import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GUI_PATH = ROOT / "panda" / "gui.ps1"
MANAGER_PATH = ROOT / "panda" / "panda.ps1"
XAML_NS = {
    "x": "http://schemas.microsoft.com/winfx/2006/xaml",
    "p": "http://schemas.microsoft.com/winfx/2006/xaml/presentation",
}


def extract_xaml(source: str) -> str:
    match = re.search(r"\[xml\]\$xaml\s*=\s*@'\s*(.*?)\s*'@", source, re.DOTALL)
    if not match:
        raise AssertionError("Could not find the embedded WPF XAML document")
    return match.group(1)


def extract_braced_block(source: str, marker: str) -> str:
    marker_start = source.index(marker)
    open_brace = source.index("{", marker_start)
    depth = 0
    for index in range(open_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[open_brace + 1 : index]
    raise AssertionError(f"Unclosed block after {marker!r}")


class PandaGuiContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gui = GUI_PATH.read_text(encoding="utf-8-sig")
        cls.manager = MANAGER_PATH.read_text(encoding="utf-8-sig")
        cls.xaml = ET.fromstring(extract_xaml(cls.gui))

    def test_library_remains_default_and_settings_monitor_exist(self):
        tabs = self.xaml.findall(".//p:TabControl/p:TabItem", XAML_NS)
        self.assertGreaterEqual(len(tabs), 3)
        self.assertEqual(tabs[0].attrib["Header"], "Model Library")
        self.assertEqual(tabs[1].attrib["Header"], "Settings")
        self.assertEqual(tabs[2].attrib["Header"], "Monitor")

    def test_gui_launcher_does_not_depend_on_console(self):
        launcher = (ROOT / "panda" / "panda-launcher.cs").read_text(encoding="utf-8-sig")
        wrapper = (ROOT / "START.bat").read_text(encoding="utf-8-sig")
        helper = (ROOT / "panda" / "launch-gui.vbs").read_text(encoding="utf-8-sig")
        self.assertIn('--console', launcher)
        self.assertIn('wscript.exe', launcher)
        self.assertIn('powershell.exe', launcher)
        self.assertIn('panda.exe', wrapper.lower())
        self.assertIn('shell.Run command, 0, False', helper)
        self.assertIn('[PandaGuiConsole]::FreeConsole()', self.gui)

    def test_model_progress_reports_real_download_bytes_and_indeterminate_loading(self):
        names = {element.attrib.get(f"{{{XAML_NS['x']}}}Name") for element in self.xaml.iter()}
        self.assertTrue({"ActionProgress", "ActionProgressText"}.issubset(names))
        self.assertIn("PANDA_DOWNLOAD", self.manager)
        self.assertIn("100.0 * $downloaded / $total", self.gui)
        self.assertIn("the backend does not report a percentage", self.gui)

    def test_failed_action_includes_launcher_diagnostics(self):
        reader = extract_braced_block(self.gui, "function Read-ManagerResult")
        self.assertIn("ERROR|WARNING", reader)
        self.assertIn("$result.message", reader)

    def test_panda_inspired_controls_are_present(self):
        names = {element.attrib.get(f"{{{XAML_NS['x']}}}Name") for element in self.xaml.iter()}
        self.assertTrue(
            {
                "SettingsModelBox",
                "ContextBox",
                "GameModeToggle",
                "SaveSettingsButton",
                "HardwareRefreshButton",
                "MetricGpu",
                "MetricVram",
                "MetricTemperature",
                "MetricCpuRam",
                "ContextFillValue",
            }.issubset(names)
        )

    def test_speed_metric_is_explicitly_unreported_by_default(self):
        speed_metric = next(element for element in self.xaml.iter() if element.attrib.get(f"{{{XAML_NS['x']}}}Name") == "MetricSpeed")
        self.assertEqual(speed_metric.attrib["Text"], "Not reported")
        context_fill = next(element for element in self.xaml.iter() if element.attrib.get(f"{{{XAML_NS['x']}}}Name") == "ContextFillValue")
        self.assertEqual(context_fill.attrib["Text"], "Not reported")

    def test_page_badge_tracks_the_selected_section(self):
        names = {element.attrib.get(f"{{{XAML_NS['x']}}}Name") for element in self.xaml.iter()}
        self.assertTrue({"PageBadge", "CurrentPageLabel"}.issubset(names))
        self.assertIn("MainTabs.Add_SelectionChanged", self.gui)
        self.assertIn("$script:CurrentPageLabel.Text = $pageName.ToUpperInvariant()", self.gui)
        for name in ("MainTabs", "PageBadge", "CurrentPageLabel"):
            self.assertIn(f"$script:{name} = $script:Window.FindName('{name}')", self.gui)

    def test_demo_preview_does_not_dispatch_live_actions(self):
        start = self.gui.index("elseif ($script:PreviewState -in @('Demo','DemoLoading','DemoDownload'))")
        end = self.gui.index("elseif ($SkipInitialize)", start)
        preview_branch = self.gui[start:end]
        self.assertIn("Get-DemoStatus", preview_branch)
        self.assertIn("no live API query", preview_branch)
        self.assertNotIn("Start-ManagerAction", preview_branch)

    def test_demo_preview_blocks_status_and_hardware_sampling(self):
        manager_action = extract_braced_block(self.gui, "function Start-ManagerAction(")
        hardware_refresh = extract_braced_block(self.gui, "function Update-HardwareMetrics {")
        self.assertIn("if ($script:PreviewState)", manager_action)
        self.assertNotIn("$Action -ne 'Status'", manager_action)
        self.assertIn("if ($script:PreviewState)", hardware_refresh)
        demo_start = self.gui.index("elseif ($script:PreviewState -in @('Demo','DemoLoading','DemoDownload'))")
        demo_end = self.gui.index("elseif ($SkipInitialize)", demo_start)
        demo_branch = self.gui[demo_start:demo_end]
        for control in ("RefreshButton", "StopButton", "HardwareRefreshButton"):
            self.assertIn(f"$script:{control}.IsEnabled = $false", demo_branch)
        self.assertIn("ActionEnabled = ([bool]$actionEnabled -and (-not [bool]$script:PreviewState))", self.gui)

    def test_context_and_game_mode_setters_are_next_start_preferences_only(self):
        context_block = extract_braced_block(self.manager, "'setcontext' {")
        game_mode_block = extract_braced_block(self.manager, "'setgamemode' {")
        forbidden = ("Start-Model", "Stop-PandaEngine", "Stop-CurrentEngine", "Toggle-GameMode", "Start-Router")
        for action_block in (context_block, game_mode_block):
            for operation in forbidden:
                self.assertNotIn(operation, action_block)
            self.assertIn("Save-State", action_block)
        self.assertIn("$Context -notin @(65536, 98304, 131072)", context_block)
        self.assertIn("$m.kind -ne 'mini'", game_mode_block)
        self.assertIn("no backend was stopped or restarted", game_mode_block)
        self.assertIn("if ([int]$s.context -notin @(65536, 98304, 131072))", self.manager)
        self.assertIn("$modeValue -eq 'true' -and -not (Test-GameGuard)", game_mode_block)

    def test_gyro_stop_requires_explicit_manager_authorization(self):
        stop_block = extract_braced_block(self.manager, "function Stop-CurrentEngine(")
        start_block = extract_braced_block(self.manager, "function Start-Model(")
        self.assertIn("function Get-GyroBackendOwners($Owners)", self.manager)
        self.assertNotIn("Get-BackendOwnerValidationState $owner", extract_braced_block(self.manager, "function Get-GyroBackendOwners("))
        self.assertIn("$gyroOwners.Count -gt 0 -and -not $AuthorizeGyroStop", stop_block)
        self.assertIn("$gyroOwners.Count -gt 0 -and -not $AuthorizeGyroStop", start_block)
        self.assertIn("requiresGyroStopAuthorization = $true", self.manager)
        self.assertIn("[switch]$AuthorizeGyroStop", self.manager)
        self.assertIn("-AuthorizeGyroStop", self.gui)
        self.assertIn("Continue only if you explicitly authorize stopping Gyro-S.", self.gui)
        self.assertIn("If a Gyro-S ownership record exists", self.gui)

    def test_failed_gyro_start_does_not_terminate_without_authorization(self):
        start_block = extract_braced_block(self.manager, "function Start-Model(")
        preserve_block = extract_braced_block(self.manager, "function Preserve-GyroAfterStartFailure(")
        self.assertGreaterEqual(start_block.count("Preserve-GyroAfterStartFailure"), 5)
        self.assertIn("$AuthorizeGyroStop -or -not $Process", preserve_block)
        self.assertIn("was not terminated because no stop authorization was given", preserve_block)
        self.assertIn("Gyro-S did not pass startup checks", self.manager)

    def test_start_stop_timeout_does_not_kill_child_process_tree(self):
        timeout_start = self.gui.index("$timedOut = $script:PendingAction")
        timeout_end = self.gui.index("Start-ManagerAction 'Status'", timeout_start)
        timeout_block = self.gui[timeout_start:timeout_end]
        taskkill_guard = extract_braced_block(self.gui, "if ($timedOut.Action -notin @('Start','Stop'))")
        self.assertIn("taskkill.exe", taskkill_guard)
        self.assertIn("Stop-Process -Id $timedOut.Process.Id", timeout_block)
        self.assertIn("Only the manager process was stopped; child backend processes were left untouched.", timeout_block)

    def test_game_mode_never_silently_falls_back_to_standard_start(self):
        start_block = extract_braced_block(self.manager, "function Start-Model(")
        self.assertIn("$m.kind -eq 'mini' -and $s.gameMode -and -not (Test-GameGuard)", start_block)
        self.assertIn("MiniCPM was not started in standard mode.", start_block)
        self.assertNotIn("starting MiniCPM in normal mode instead", start_block)

    def test_console_game_mode_toggle_is_next_start_only(self):
        toggle_block = extract_braced_block(self.manager, "function Toggle-GameMode(")
        self.assertNotIn("Stop-MiniBackend", toggle_block)
        self.assertIn("running backend was not changed", toggle_block)
        self.assertIn("next MiniCPM START", toggle_block)


if __name__ == "__main__":
    unittest.main()

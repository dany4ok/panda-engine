param(
    [switch]$SkipInitialize,
    [ValidateSet('', 'RefreshError','EmptyCatalog','Demo','DemoLoading','DemoDownload')]
    [string]$PreviewState = ''
)

Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class PandaGuiConsole {
    [DllImport("kernel32.dll")] public static extern bool FreeConsole();
}
'@
[void][PandaGuiConsole]::FreeConsole()

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
public static class PandaGpuProbe {
    public static Task<string> GetAsync(string file, string arguments, int timeoutMs) {
        var completion = new TaskCompletionSource<string>();
        var start = new ProcessStartInfo(file) {
            Arguments = arguments, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true
        };
        var process = new Process();
        process.StartInfo = start;
        process.EnableRaisingEvents = true;
        Timer guard = null;
        guard = new Timer(_ => {
            try { if (!process.HasExited) process.Kill(); } catch {}
            if (guard != null) guard.Dispose();
            process.Dispose();
            completion.TrySetResult("");
        }, null, timeoutMs, Timeout.Infinite);
        process.OutputDataReceived += (sender, args) => {
            if (args.Data != null) completion.TrySetResult(args.Data);
        };
        process.Exited += (sender, args) => {
            guard.Dispose();
            process.Dispose();
            if (!completion.Task.IsCompleted) completion.TrySetResult("");
        };
        try {
            if (!process.Start()) {
                guard.Dispose();
                process.Dispose();
                completion.TrySetResult("");
            } else process.BeginOutputReadLine();
        } catch (Exception error) {
            guard.Dispose();
            try { if (!process.HasExited) process.Kill(); } catch {}
            process.Dispose();
            completion.TrySetException(error);
        }
        return completion.Task;
    }
}
public static class PandaTelemetryProbe {
    public static Task<string> GetAsync(string url, int timeoutMs) {
        var completion = new TaskCompletionSource<string>();
        var request = (HttpWebRequest)WebRequest.Create(url);
        request.Timeout = timeoutMs;
        request.ReadWriteTimeout = timeoutMs;
        Timer watchdog = null;
        watchdog = new Timer(_ => {
            try { request.Abort(); } catch {}
        }, null, timeoutMs + 500, Timeout.Infinite);
        request.BeginGetResponse(result => {
            try {
                using (var response = (HttpWebResponse)request.EndGetResponse(result))
                using (var reader = new StreamReader(response.GetResponseStream())) {
                    completion.TrySetResult(reader.ReadToEnd());
                }
            } catch (Exception error) {
                completion.TrySetException(error);
            } finally {
                if (watchdog != null) watchdog.Dispose();
            }
        }, null);
        return completion.Task;
    }
}
'@

$ErrorActionPreference = 'Stop'
$script:PandaDir = $PSScriptRoot
$script:ManagerScript = Join-Path $script:PandaDir 'panda.ps1'
$script:CatalogPath = Join-Path $script:PandaDir 'catalog.json'
$script:PowerShellExe = Join-Path $PSHOME 'powershell.exe'
$script:Catalog = Get-Content -LiteralPath $script:CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:ApiBase = 'http://127.0.0.1:' + [string]$script:Catalog.ports.api
$script:MonitorTick = 0
$script:LiveMetricsFailures = 0
$script:MetricsTask = $null
$script:GpuProbeTask = $null
$script:PromHistory = @{}
$script:IsNinferFeed = $false
$script:LastRequestTime = 0
$script:LastRequestCount = -1
$script:Models = @()
$script:ApiStatus = $null
$script:PendingAction = $null
$script:Busy = $false
$script:StatusUnavailable = $false
$script:AfterStatusMessage = ''
$script:SettingsActionPending = $false
$script:PreviewState = $PreviewState

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Give the GUI its own taskbar identity so Windows shows the Panda Engine icon
# instead of grouping it under the generic powershell.exe button.
try {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PandaAppIdentity {
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  public static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appID);
}
'@
  $appId = 'PandaEngine.GUI.v2'
  $appKey = "HKCU:\Software\Classes\AppUserModelId\$appId"
  if (-not (Test-Path -LiteralPath $appKey)) { $null = New-Item -Path $appKey -Force }
  Set-ItemProperty -LiteralPath $appKey -Name DisplayName -Value 'Panda Engine'
  Set-ItemProperty -LiteralPath $appKey -Name Description -Value 'Panda Engine - Local model library'
  Set-ItemProperty -LiteralPath $appKey -Name 'AppUserModel.RelaunchDisplayNameResource' -Value 'Panda Engine'
  Set-ItemProperty -LiteralPath $appKey -Name 'AppUserModel.RelaunchCommand' -Value ('"{0}" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{1}"' -f $script:PowerShellExe, (Join-Path $script:PandaDir 'gui.ps1'))
  Set-ItemProperty -LiteralPath $appKey -Name 'AppUserModel.RelaunchIconResource' -Value (Join-Path (Split-Path -Parent $script:PandaDir) 'panda.ico')
  [PandaAppIdentity]::SetCurrentProcessExplicitAppUserModelID($appId)
} catch {
  # Non-fatal: the window icon is still set below.
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Panda Engine" Width="1240" Height="780" MinWidth="980" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#F2F5F9" FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Height" Value="44"/>
      <Setter Property="Padding" Value="15,8"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Background" Value="#2E68E8"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Foreground" Value="#687386"/>
          <Setter Property="Cursor" Value="Arrow"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Height" Value="42"/>
      <Setter Property="Padding" Value="13,7"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Background" Value="#E9EEF5"/>
      <Setter Property="Foreground" Value="#27354B"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="DangerButton" TargetType="Button">
      <Setter Property="Height" Value="42"/>
      <Setter Property="Padding" Value="13,7"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Background" Value="#FCEBED"/>
      <Setter Property="Foreground" Value="#9B2434"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Foreground" Value="#687386"/>
          <Setter Property="Cursor" Value="Arrow"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="ModelActionButton" TargetType="Button">
      <Setter Property="Height" Value="38"/>
      <Setter Property="MinWidth" Value="148"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Background" Value="#2E68E8"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#2E68E8"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ActionSurface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ActionSurface" Property="Opacity" Value="0.9"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="ActionSurface" Property="BorderBrush" Value="#17243A"/>
                <Setter TargetName="ActionSurface" Property="BorderThickness" Value="2"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="ActionSurface" Property="Background" Value="#EEF2F7"/>
                <Setter TargetName="ActionSurface" Property="BorderBrush" Value="#DDE3EC"/>
                <Setter Property="Foreground" Value="#59677B"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
              <DataTrigger Binding="{Binding ActionKind}" Value="SetActive">
                <Setter TargetName="ActionSurface" Property="Background" Value="#E9EEF5"/>
                <Setter TargetName="ActionSurface" Property="BorderBrush" Value="#DDE3EC"/>
                <Setter Property="Foreground" Value="#27354B"/>
              </DataTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SwitchToggle" TargetType="{x:Type ToggleButton}">
      <Setter Property="Width" Value="54"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ToggleButton}">
            <Border x:Name="SwitchTrack" Width="54" Height="30" CornerRadius="15" Background="#DCE3EC">
              <Ellipse x:Name="SwitchThumb" Width="22" Height="22" Fill="#FFFFFF" Margin="4"
                       HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="SwitchTrack" Property="Background" Value="#26B983"/>
                <Setter TargetName="SwitchThumb" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="SwitchTrack" Property="Opacity" Value="0.55"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="{x:Type TabItem}">
      <Setter Property="Padding" Value="17,10"/>
      <Setter Property="Margin" Value="0,0,7,0"/>
      <Setter Property="Foreground" Value="#69768A"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type TabItem}">
            <Border x:Name="TabSurface" Background="Transparent" BorderBrush="Transparent" BorderThickness="0,0,0,2"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="TabSurface" Property="Background" Value="#FFFFFF"/>
                <Setter TargetName="TabSurface" Property="BorderBrush" Value="#27B985"/>
                <Setter Property="Foreground" Value="#17243A"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="TabSurface" Property="Background" Value="#F8FAFC"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#F5F7FA"/>
      <Setter Property="Foreground" Value="#5A687D"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="10,12"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="BorderBrush" Value="#E7EBF1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#26344A"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="MinHeight" Value="58"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#EEF1F5"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#EAF1FF"/>
          <Setter Property="Foreground" Value="#1C3970"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Sparkline" TargetType="Polyline">
      <Setter Property="Stroke" Value="#27B985"/>
      <Setter Property="StrokeThickness" Value="1.5"/>
      <Setter Property="StrokeLineJoin" Value="Round"/>
      <Setter Property="Stretch" Value="Fill"/>
      <Setter Property="HorizontalAlignment" Value="Stretch"/>
      <Setter Property="VerticalAlignment" Value="Bottom"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Margin" Value="0,7,0,0"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
    </Style>
    <Style x:Key="SparklineMuted" TargetType="Polyline" BasedOn="{StaticResource Sparkline}">
      <Setter Property="Stroke" Value="#A9B4C4"/>
      <Setter Property="StrokeDashArray" Value="3 2"/>
    </Style>
    <Style x:Key="RequestRow" TargetType="DataGridRow">
      <Setter Property="MinHeight" Value="24"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#EEF1F5"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
  </Window.Resources>
  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#F8F9FB" BorderBrush="#E1E6ED" BorderThickness="1"
            CornerRadius="14" Padding="14,12" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Image x:Name="LogoImage" Width="42" Height="42" Stretch="Uniform"
                 AutomationProperties.Name="Panda Engine logo"/>
          <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Panda Engine" FontSize="20" FontWeight="SemiBold" Foreground="#17243A"/>
            <TextBlock Text="Local model library" FontSize="12" Foreground="#69768A" Margin="0,2,0,0"/>
          </StackPanel>
        </StackPanel>
        <Border x:Name="PageBadge" Grid.Column="1" Background="#E9EEF5" BorderBrush="#DDE3EC" BorderThickness="1"
                CornerRadius="9" Padding="13,8" Margin="24,0,0,0" VerticalAlignment="Center"
                HorizontalAlignment="Left" AutomationProperties.Name="Current page: Model Library">
          <TextBlock x:Name="CurrentPageLabel" Text="MODEL LIBRARY" FontSize="11" FontWeight="Bold" Foreground="#34445D"/>
        </Border>
        <Border x:Name="ApiBadge" Grid.Column="2" Background="#EEF2F7" BorderBrush="#E1E6ED" BorderThickness="1"
                CornerRadius="10" Padding="12,9" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="ApiDot" Width="9" Height="9" Fill="#8793A5" Margin="0,0,9,0" VerticalAlignment="Center"/>
            <StackPanel Orientation="Vertical" VerticalAlignment="Center">
              <TextBlock x:Name="ApiState" Text="Checking local API..." FontSize="12" FontWeight="SemiBold" Foreground="#526174"/>
              <TextBlock x:Name="ApiEndpoint" Text="http://127.0.0.1:8081/v1" FontSize="10" Foreground="#748196" Margin="0,2,0,0"
                         AutomationProperties.Name="Panda Engine local API endpoint"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Grid>
    </Border>
    <TabControl x:Name="MainTabs" Grid.Row="2" Margin="0,0,0,10" Background="Transparent"
                BorderThickness="0" AutomationProperties.Name="Panda Engine sections">
      <TabItem Header="Model Library" AutomationProperties.Name="Model Library">
        <Grid Margin="0,8,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#F8F9FB" BorderBrush="#E1E6ED" BorderThickness="1"
            CornerRadius="11" Padding="10" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="185"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Grid Grid.Column="0" Margin="0,0,10,0">
          <TextBox x:Name="SearchBox" Height="42" Padding="12,8" FontSize="13" VerticalContentAlignment="Center"
                   BorderBrush="#DDE3EC" BorderThickness="1" Background="#FFFFFF" AutomationProperties.Name="Search models"
                   AutomationProperties.HelpText="Search model name, ID or provider"/>
          <TextBlock x:Name="SearchPlaceholder" Text="Search model name, ID or provider" Margin="13,0,0,0"
                     VerticalAlignment="Center" FontSize="13" Foreground="#748196" IsHitTestVisible="False"/>
        </Grid>
        <ComboBox x:Name="FilterBox" Grid.Column="1" Height="42" Padding="9,5" FontSize="12" SelectedIndex="0"
                  BorderBrush="#DDE3EC" Background="#FFFFFF" AutomationProperties.Name="Filter models">
          <ComboBoxItem Content="All models"/>
          <ComboBoxItem Content="Installed"/>
          <ComboBoxItem Content="Not installed"/>
        </ComboBox>
        <TextBlock x:Name="CountText" Grid.Column="2" Text="0 of 0 models" VerticalAlignment="Center"
                   Foreground="#69768A" FontSize="12" Margin="13,0,6,0"/>
      </Grid>
    </Border>
    <Border Grid.Row="1" Background="#F8F9FB" BorderBrush="#DFE5ED" BorderThickness="1"
            CornerRadius="12" Padding="14" Margin="0,0,0,10">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="SELECTED MODEL" FontSize="10" FontWeight="Bold" Foreground="#77849A"/>
            <TextBlock x:Name="DetailsTitle" Text="Choose a model" FontSize="18" FontWeight="SemiBold"
                       Foreground="#17243A" Margin="0,4,0,0" TextWrapping="Wrap"/>
            <TextBlock x:Name="DetailsId" Text="Select a card to inspect its catalog details."
                       FontSize="11" Foreground="#69768A" Margin="0,3,0,0" TextWrapping="Wrap"/>
          </StackPanel>
          <TextBlock Grid.Column="1" Text="Selection does not start a model" FontSize="11" Foreground="#69768A"
                     VerticalAlignment="Center" Margin="16,0,0,0"/>
        </Grid>
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,11,0,10">
          <Border Background="#EEF2F7" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="8" Padding="10,6" Margin="0,0,8,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Install  " FontSize="10" Foreground="#69768A"/>
              <TextBlock x:Name="InstallValue" Text="-" FontSize="11" FontWeight="SemiBold" Foreground="#26344A"/>
            </StackPanel>
          </Border>
          <Border Background="#EEF2F7" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="8" Padding="10,6" Margin="0,0,8,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Next start  " FontSize="10" Foreground="#69768A"/>
              <TextBlock x:Name="ActiveValue" Text="-" FontSize="11" FontWeight="SemiBold" Foreground="#26344A"/>
            </StackPanel>
          </Border>
          <Border Background="#EEF2F7" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="8" Padding="10,6">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Service  " FontSize="10" Foreground="#69768A"/>
              <TextBlock x:Name="ServiceValue" Text="-" FontSize="11" FontWeight="SemiBold" Foreground="#26344A"/>
            </StackPanel>
          </Border>
        </StackPanel>
        <Expander x:Name="DetailsExpander" Grid.Row="2" Header="Provider and files" IsExpanded="False"
                  IsEnabled="False" Foreground="#526174" FontSize="11" AutomationProperties.Name="Selected model provider and files">
          <Grid Margin="4,8,4,2">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="0.8*"/>
              <ColumnDefinition Width="1.2*"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Margin="0,0,12,0">
              <TextBlock Text="Provider" FontSize="10" FontWeight="SemiBold" Foreground="#6A778A"/>
              <TextBlock x:Name="ProviderValue" Text="-" FontSize="11" Foreground="#26344A" Margin="0,3,0,0" TextWrapping="Wrap"/>
            </StackPanel>
            <StackPanel Grid.Column="1">
              <TextBlock Text="Files" FontSize="10" FontWeight="SemiBold" Foreground="#6A778A"/>
              <TextBlock x:Name="FilesValue" Text="-" FontSize="11" Foreground="#526174" Margin="0,3,0,0" TextWrapping="Wrap"/>
            </StackPanel>
          </Grid>
        </Expander>
        <StackPanel Grid.Row="3" Margin="0,8,0,0">
          <TextBlock x:Name="GyroHint" Text="Gyro-S is bundled. If its local files are missing, Panda Engine has no catalog download action for it."
                     FontSize="11" Foreground="#8B5B14" Background="#FFF6E5" Padding="9" TextWrapping="Wrap" Visibility="Collapsed"/>
          <TextBlock x:Name="UnknownRouteHint" Text="The API route cannot be matched to this workspace's catalog. No listed model is marked Running; stop the API from its owning workspace if it is not yours."
                     FontSize="11" Foreground="#8B5B14" Background="#FFF6E5" Padding="9" TextWrapping="Wrap" Visibility="Collapsed"/>
          <TextBlock x:Name="MissingHint" Text="Bundled files are missing. No installer is available for this model."
                     FontSize="11" Foreground="#8B5B14" Background="#FFF6E5" Padding="9" TextWrapping="Wrap" Visibility="Collapsed"/>
        </StackPanel>
      </Grid>
    </Border>
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="168"/>
      </Grid.ColumnDefinitions>
      <Border Grid.Column="0" Background="#F8F9FB" BorderBrush="#E1E6ED" BorderThickness="1"
              CornerRadius="12" Padding="11" Margin="0,0,10,0">
        <Grid>
          <ListBox x:Name="ModelsList" Background="Transparent" BorderThickness="0" Padding="0"
                   ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                   HorizontalContentAlignment="Stretch" AlternationCount="2" AutomationProperties.Name="Model catalog">
            <ListBox.ItemContainerStyle>
              <Style TargetType="ListBoxItem">
                <Setter Property="Padding" Value="0"/>
                <Setter Property="Margin" Value="0,0,0,8"/>
                <Setter Property="Background" Value="#FFFFFF"/>
                <Setter Property="BorderThickness" Value="0"/>
                <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                <Setter Property="Focusable" Value="True"/>
                <Style.Triggers>
                  <Trigger Property="ItemsControl.AlternationIndex" Value="1">
                    <Setter Property="Background" Value="#F4F7FB"/>
                  </Trigger>
                  <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#EEF4FF"/>
                  </Trigger>
                </Style.Triggers>
              </Style>
            </ListBox.ItemContainerStyle>
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Border x:Name="ModelCard" Background="{Binding RelativeSource={RelativeSource AncestorType={x:Type ListBoxItem}}, Path=Background}"
                        BorderBrush="#E2E7EF" BorderThickness="1" CornerRadius="10" Padding="10">
                  <Grid MinHeight="62">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="58"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Border Width="52" Height="52" CornerRadius="9" Background="#EEF2F7"
                            BorderBrush="#E1E6ED" BorderThickness="1" VerticalAlignment="Center">
                      <TextBlock Text="{Binding RuntimeGlyph}" FontSize="14" FontWeight="Bold" Foreground="#61718A"
                                 HorizontalAlignment="Center" VerticalAlignment="Center"
                                 AutomationProperties.Name="{Binding Runtime}"/>
                    </Border>
                    <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="10,0,12,0">
                      <TextBlock Text="{Binding Name}" FontSize="13" FontWeight="SemiBold" Foreground="#17243A"
                                 TextWrapping="Wrap"/>
                      <TextBlock Text="{Binding Id}" FontSize="10" Foreground="#748196" Margin="0,2,0,0"/>
                      <TextBlock Text="{Binding StatusSummary}" FontSize="10" Foreground="#526174" Margin="0,4,0,0"
                                 TextWrapping="Wrap"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2" VerticalAlignment="Center" HorizontalAlignment="Right">
                      <TextBlock Text="{Binding Runtime}" FontSize="10" Foreground="#69768A"
                                 HorizontalAlignment="Center" Margin="0,0,0,5"/>
                      <Button Content="{Binding ActionLabel}" Tag="ModelAction" Style="{StaticResource ModelActionButton}"
                              IsEnabled="{Binding ActionEnabled}" ToolTip="{Binding ActionAccessibleName}"
                              AutomationProperties.Name="{Binding ActionAccessibleName}"/>
                    </StackPanel>
                  </Grid>
                </Border>
                <DataTemplate.Triggers>
                  <DataTrigger Binding="{Binding IsSelected, RelativeSource={RelativeSource AncestorType={x:Type ListBoxItem}}}" Value="True">
                    <Setter TargetName="ModelCard" Property="BorderBrush" Value="#9BB7EE"/>
                    <Setter TargetName="ModelCard" Property="Background" Value="#EEF4FF"/>
                  </DataTrigger>
                </DataTemplate.Triggers>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
          <Border x:Name="EmptyState" Background="#F8F9FB" Visibility="Collapsed" CornerRadius="10">
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Margin="24">
              <TextBlock x:Name="EmptyStateTitle" Text="No models match this search" FontSize="16" FontWeight="SemiBold"
                         Foreground="#26344A" HorizontalAlignment="Center"/>
              <TextBlock x:Name="EmptyStateMessage" Text="Try another name or filter." FontSize="12" Foreground="#69768A"
                         Margin="0,6,0,0" HorizontalAlignment="Center"/>
            </StackPanel>
          </Border>
        </Grid>
      </Border>
      <Border Grid.Column="1" Background="#F8F9FB" BorderBrush="#E1E6ED" BorderThickness="1"
              CornerRadius="12" Padding="12">
        <StackPanel>
          <TextBlock Text="ENGINE" FontSize="10" FontWeight="Bold" Foreground="#77849A" Margin="2,2,0,10"/>
          <Button x:Name="RefreshButton" Content="Refresh" Style="{StaticResource SecondaryButton}" Margin="0,0,0,8"
                  AutomationProperties.Name="Refresh API and model status"/>
          <Button x:Name="StopButton" Content="Stop engine" Style="{StaticResource DangerButton}" IsEnabled="False"
                  AutomationProperties.Name="Stop Panda Engine API and model backends"/>
          <Separator Margin="0,14,0,12" Background="#E2E7EF"/>
          <TextBlock Text="ACTION STATUS" FontSize="10" FontWeight="Bold" Foreground="#77849A" Margin="2,0,0,7"/>
          <TextBlock x:Name="ActionMessage" Text="Select a card to inspect it. Selection alone does not start or switch a model."
                     FontSize="11" Foreground="#5D6B80" TextWrapping="Wrap"/>
          <ProgressBar x:Name="ActionProgress" Height="8" Margin="0,10,0,0" Minimum="0" Maximum="100"
                       IsIndeterminate="True" Visibility="Collapsed" AutomationProperties.Name="Model action progress"/>
          <TextBlock x:Name="ActionProgressText" FontSize="10" Foreground="#69768A" Margin="0,5,0,0"
                     TextWrapping="Wrap" Visibility="Collapsed"/>
          <TextBlock Text="Installed files stay on disk when a catalog entry is removed."
                     FontSize="10" Foreground="#748196" TextWrapping="Wrap" Margin="0,14,0,0"/>
        </StackPanel>
      </Border>
    </Grid>
        </Grid>
      </TabItem>
      <TabItem Header="Settings" AutomationProperties.Name="Model settings">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <Grid Margin="10,18,10,12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="1.45*"/>
              <ColumnDefinition Width="0.95*"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Margin="0,0,12,0">
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="14" Padding="22">
                <StackPanel>
                  <TextBlock Text="Model settings" FontSize="21" FontWeight="SemiBold" Foreground="#17243A"/>
                  <TextBlock Text="Choose a model and save runtime settings for its next start. Saving does not stop or restart a running model."
                             FontSize="12" Foreground="#69768A" Margin="0,5,0,20" TextWrapping="Wrap"/>
                  <TextBlock Text="MODEL VERSION" FontSize="10" FontWeight="Bold" Foreground="#77849A" Margin="0,0,0,6"/>
                  <ComboBox x:Name="SettingsModelBox" Height="42" Padding="10,6" FontSize="13"
                            BorderBrush="#DDE3EC" Background="#FFFFFF" DisplayMemberPath="label"
                            AutomationProperties.Name="Model version"/>
                  <Grid Margin="0,18,0,0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,8,0">
                      <TextBlock Text="CONVERSATION CONTEXT" FontSize="10" FontWeight="Bold" Foreground="#77849A" Margin="0,0,0,6"/>
                      <ComboBox x:Name="ContextBox" Height="42" Padding="10,6" FontSize="13"
                                BorderBrush="#DDE3EC" Background="#FFFFFF" AutomationProperties.Name="Conversation context">
                        <ComboBoxItem Content="16K tokens" Tag="16384"/>
                        <ComboBoxItem Content="32K tokens" Tag="32768"/>
                        <ComboBoxItem Content="64K tokens" Tag="65536"/>
                        <ComboBoxItem Content="128K tokens" Tag="131072"/>
                      </ComboBox>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Margin="8,0,0,0">
                      <TextBlock Text="DRAFTING" FontSize="10" FontWeight="Bold" Foreground="#77849A" Margin="0,0,0,6"/>
                      <ComboBox x:Name="DraftingBox" Height="42" Padding="10,6" FontSize="13" SelectedIndex="0"
                                BorderBrush="#DDE3EC" Background="#FFFFFF" IsEnabled="False"
                                AutomationProperties.Name="Drafting mode">
                        <ComboBoxItem Content="Auto (managed by runtime)"/>
                      </ComboBox>
                    </StackPanel>
                  </Grid>
                  <StackPanel Margin="0,14,0,0">
                    <TextBlock Text="READ PICTURES" FontSize="10" FontWeight="Bold" Foreground="#77849A" Margin="0,0,0,6"/>
                    <ComboBox x:Name="ReadPicturesBox" Height="42" Padding="10,6" FontSize="13"
                              BorderBrush="#DDE3EC" Background="#F4F7FB" IsEnabled="False"
                              AutomationProperties.Name="Image reading capability">
                      <ComboBoxItem Content="Automatic - MiniCPM vision runtime"/>
                      <ComboBoxItem Content="Managed by selected runtime"/>
                    </ComboBox>
                  </StackPanel>
                  <TextBlock x:Name="ContextHelp" Text="Context applies on the next model start; it never restarts the active service."
                             FontSize="11" Foreground="#69768A" Margin="0,7,0,16" TextWrapping="Wrap"/>
                  <Border Background="#F4F7FB" BorderBrush="#E4EAF2" BorderThickness="1" CornerRadius="11" Padding="15">
                    <StackPanel>
                      <TextBlock Text="GPU PERFORMANCE" FontSize="10" FontWeight="Bold" Foreground="#77849A" Margin="0,0,0,7"/>
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel>
                          <TextBlock Text="MiniCPM Game Mode" FontSize="14" FontWeight="SemiBold" Foreground="#26344A"/>
                          <TextBlock Text="Uses the adaptive VRAM guard on the next MiniCPM start. Does not stop or change Gyro-S."
                                     FontSize="11" Foreground="#69768A" Margin="0,4,12,0" TextWrapping="Wrap"/>
                        </StackPanel>
                        <ToggleButton x:Name="GameModeToggle" Grid.Column="1" Style="{StaticResource SwitchToggle}" VerticalAlignment="Center"
                                      IsEnabled="False" AutomationProperties.Name="MiniCPM Game Mode"/>
                      </Grid>
                      <TextBlock x:Name="GameModeState" Text="Select MiniCPM to configure Game Mode."
                                 FontSize="11" Foreground="#748196" Margin="0,10,0,0"/>
                    </StackPanel>
                  </Border>
                  <Grid Margin="0,18,0,0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="SettingsSaveMessage" Text="Settings are local and apply on a future start."
                               VerticalAlignment="Center" FontSize="11" Foreground="#69768A" TextWrapping="Wrap"/>
                    <Button x:Name="SaveSettingsButton" Grid.Column="1" Content="Save for next start"
                            Style="{StaticResource PrimaryButton}" Height="42" Margin="12,0,0,0"
                            AutomationProperties.Name="Save model settings for next start"/>
                  </Grid>
                </StackPanel>
              </Border>
            </StackPanel>
            <StackPanel Grid.Column="1">
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="14" Padding="20">
                <StackPanel>
                  <TextBlock Text="This computer" FontSize="18" FontWeight="SemiBold" Foreground="#17243A"/>
                  <TextBlock x:Name="ComputerSummary" Text="Hardware telemetry is opt-in and is not sampled automatically."
                             FontSize="12" Foreground="#69768A" Margin="0,9,0,16" TextWrapping="Wrap"/>
                  <TextBlock Text="MODEL FILES" FontSize="10" FontWeight="Bold" Foreground="#77849A" Margin="0,0,0,6"/>
                  <TextBlock x:Name="SettingsFiles" Text="Choose a model to view its configured files."
                             FontSize="11" Foreground="#526174" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="14" Padding="20" Margin="0,12,0,0">
                <StackPanel>
                  <TextBlock Text="Availability" FontSize="16" FontWeight="SemiBold" Foreground="#17243A"/>
                  <TextBlock Text="Context and Game Mode are the supported Panda Engine settings. Drafting, image-reading policy, and computer-use permissions remain controlled by the selected runtime or OpenCode."
                             FontSize="11" Foreground="#69768A" Margin="0,8,0,0" TextWrapping="Wrap"/>
                  <Border Background="#EAF7F1" CornerRadius="8" Padding="10" Margin="0,14,0,0">
                    <TextBlock Text="No setting on this page issues a stop or model-switch command."
                               FontSize="11" FontWeight="SemiBold" Foreground="#26734F" TextWrapping="Wrap"/>
                  </Border>
                </StackPanel>
              </Border>
            </StackPanel>
          </Grid>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="Monitor" AutomationProperties.Name="Hardware and model monitor">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="10,18,10,12">
            <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="14" Padding="20" Margin="0,0,0,12">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="Model state" FontSize="17" FontWeight="SemiBold" Foreground="#17243A" VerticalAlignment="Center"/>
                    <Border x:Name="MonitorStateBadge" Background="#EEF2F7" CornerRadius="12" Padding="10,4" Margin="12,0,0,0">
                      <TextBlock x:Name="MonitorStateText" Text="Not sampled" FontSize="11" FontWeight="SemiBold" Foreground="#526174"/>
                    </Border>
                  </StackPanel>
                  <TextBlock x:Name="MonitorStateHint" Text="Open Monitor to view the current library state; no model action is performed here."
                             FontSize="12" Foreground="#69768A" Margin="0,7,0,0"/>
                  <ProgressBar x:Name="ModelProgress" Height="7" Minimum="0" Maximum="100" Value="0"
                               IsIndeterminate="False" Foreground="#27B985" Background="#EEF2F7" Margin="0,12,0,0"/>
                </StackPanel>
                <Button x:Name="HardwareRefreshButton" Grid.Column="1" Content="Sample hardware"
                        Style="{StaticResource SecondaryButton}" Height="38" VerticalAlignment="Top"
                        AutomationProperties.Name="Sample local hardware telemetry only"/>
              </Grid>
            </Border>
            <UniformGrid Columns="4" Rows="2" Margin="0,0,0,12">
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,8">
                <StackPanel><TextBlock Text="Speed" FontSize="11" Foreground="#69768A"/><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="MetricSpeed" Text="Not reported" FontSize="20" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock x:Name="MetricSpeedDetail" Text="Decode" FontSize="10" Foreground="#748196"/></StackPanel><StackPanel Grid.Column="1"><TextBlock x:Name="MetricPrefill" Text="-" FontSize="20" FontWeight="Bold" Foreground="#7B879B" Margin="0,11,0,0"/><TextBlock Text="Prefill" FontSize="10" Foreground="#748196"/></StackPanel></Grid><Grid><Polyline x:Name="SparkDecode" Style="{StaticResource Sparkline}"/><Polyline x:Name="SparkPrefill" Style="{StaticResource SparklineMuted}"/></Grid></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,8">
                <StackPanel><TextBlock Text="GPU load" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricGpu" Text="Not sampled" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock x:Name="MetricGpuName" Text="Hardware only" FontSize="10" Foreground="#748196"/><Polyline x:Name="SparkGpu" Style="{StaticResource Sparkline}"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,8">
                <StackPanel><TextBlock Text="VRAM" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricVram" Text="Not sampled" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock x:Name="MetricVramDetail" Text="Device total / used" FontSize="10" Foreground="#748196"/><Polyline x:Name="SparkVram" Style="{StaticResource Sparkline}"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,0,8">
                <StackPanel><TextBlock Text="GPU temperature" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricTemperature" Text="Not sampled" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock x:Name="MetricTempDetail" Text="Read-only device telemetry" FontSize="10" Foreground="#748196"/><Polyline x:Name="SparkTemp" Style="{StaticResource Sparkline}"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,0">
                <StackPanel><TextBlock Text="Power" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricPower" Text="Not sampled" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock x:Name="MetricPowerDetail" Text="GPU draw / limit" FontSize="10" Foreground="#748196"/><Polyline x:Name="SparkPower" Style="{StaticResource Sparkline}"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,0">
                <StackPanel><TextBlock Text="PCIe" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricPcie" Text="Not reported" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock x:Name="MetricPcieDetail" Text="No link telemetry adapter" FontSize="10" Foreground="#748196"/><Polyline x:Name="SparkPcie" Style="{StaticResource Sparkline}"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,0">
                <StackPanel><TextBlock Text="CPU / memory" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricCpuRam" Text="Not sampled" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock x:Name="MetricCpuDetail" Text="Host-level only" FontSize="10" Foreground="#748196"/><Polyline x:Name="SparkCpu" Style="{StaticResource Sparkline}"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,0,0">
                <StackPanel><TextBlock Text="Disk read" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricDisk" Text="Not reported" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock x:Name="MetricDiskDetail" Text="Read throughput" FontSize="10" Foreground="#748196"/><Polyline x:Name="SparkDisk" Style="{StaticResource Sparkline}"/></StackPanel>
              </Border>
            </UniformGrid>
            <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,0,12">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Energy since start" FontSize="10" Foreground="#69768A"/><TextBlock x:Name="MetricEnergy" Text="Not reported" FontSize="14" FontWeight="SemiBold" Foreground="#26344A" Margin="0,4,0,0"/></StackPanel>
                <StackPanel Grid.Column="1"><TextBlock Text="GPU fan" FontSize="10" Foreground="#69768A"/><TextBlock x:Name="MetricFan" Text="Not sampled" FontSize="14" FontWeight="SemiBold" Foreground="#26344A" Margin="0,4,0,0"/></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="GPU clock" FontSize="10" Foreground="#69768A"/><TextBlock x:Name="MetricClock" Text="Not sampled" FontSize="14" FontWeight="SemiBold" Foreground="#26344A" Margin="0,4,0,0"/></StackPanel>
              </Grid>
            </Border>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="0.75*"/><ColumnDefinition Width="1.5*"/></Grid.ColumnDefinitions>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,0">
                <StackPanel>
                  <TextBlock Text="Context fill" FontSize="15" FontWeight="SemiBold" Foreground="#17243A"/>
                  <Grid Width="120" Height="120" HorizontalAlignment="Center" Margin="0,12,0,2">
                    <Ellipse Width="108" Height="108" Stroke="#EEF2F7" StrokeThickness="12" Fill="Transparent" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Path x:Name="ContextArc" Stroke="#27B985" StrokeThickness="12" Fill="Transparent"
                          StrokeStartLineCap="Round" StrokeEndLineCap="Round" HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
                    <TextBlock x:Name="ContextGaugeText" Text="0%" FontSize="24" FontWeight="Bold" Foreground="#26344A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Grid>
                  <TextBlock x:Name="ContextFillValue" Text="Not reported" FontSize="17" FontWeight="Bold" Foreground="#26344A" HorizontalAlignment="Center" Margin="0,2,0,0"/>
                  <TextBlock x:Name="ContextFillHint" Text="No token-usage feed is exposed by the current backend." FontSize="10" Foreground="#748196" TextWrapping="Wrap" HorizontalAlignment="Center" Margin="0,4,0,4"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="1" Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="8,0,0,0">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Recent requests" FontSize="15" FontWeight="SemiBold" Foreground="#17243A"/>
                    <TextBlock x:Name="RequestCount" Grid.Column="1" Text="API request history unavailable" FontSize="10" Foreground="#748196" VerticalAlignment="Center"/>
                  </Grid>
                  <Border Background="#F7F9FC" CornerRadius="8" Padding="6" Margin="0,14,0,0">
                    <Grid>
                      <TextBlock x:Name="RequestsEmpty" Text="No request telemetry has been collected." FontSize="11" Foreground="#69768A" Margin="6,8"/>
                      <DataGrid x:Name="RequestsGrid" IsReadOnly="True" AutoGenerateColumns="False" HeadersVisibility="Column"
                                RowStyle="{StaticResource RequestRow}" CanUserResizeRows="False" CanUserSortColumns="False"
                                GridLinesVisibility="None" Background="Transparent" RowBackground="Transparent"
                                AlternatingRowBackground="#FFFFFF" BorderThickness="0" FontSize="10" Foreground="#526174"
                                MaxHeight="186" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
                        <DataGrid.Columns>
                          <DataGridTextColumn Header="TIME" Binding="{Binding Time}" Width="62"/>
                          <DataGridTextColumn Header="STATUS" Binding="{Binding Status}" Width="66"/>
                          <DataGridTextColumn Header="PROMPT" Binding="{Binding Prompt}" Width="66"/>
                          <DataGridTextColumn Header="REUSED" Binding="{Binding Reused}" Width="66"/>
                          <DataGridTextColumn Header="OUTPUT" Binding="{Binding Output}" Width="62"/>
                          <DataGridTextColumn Header="PREFILL" Binding="{Binding Prefill}" Width="64"/>
                          <DataGridTextColumn Header="TOK/S" Binding="{Binding TokS}" Width="58"/>
                          <DataGridTextColumn Header="HIT" Binding="{Binding Hit}" Width="56"/>
                          <DataGridTextColumn Header="DURATION" Binding="{Binding Duration}" Width="70"/>
                        </DataGrid.Columns>
                      </DataGrid>
                    </Grid>
                  </Border>
                  <TextBlock x:Name="RequestsTotals" Text="" FontSize="10" Foreground="#748196" Margin="0,8,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </Grid>
            <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,12,0,0">
              <StackPanel>
                <TextBlock Text="Conversation cache" FontSize="15" FontWeight="SemiBold" Foreground="#17243A"/>
                <TextBlock x:Name="ConversationCacheText" Text="Cache reuse details appear when the selected runtime reports them; Panda Engine does not fabricate token or request measurements."
                           FontSize="11" Foreground="#69768A" Margin="0,7,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
            <TextBlock x:Name="MonitorMessage" Text="Hardware sampling reads host telemetry only; it does not query or manage a model."
                       FontSize="10" Foreground="#748196" Margin="2,10,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>
    </TabControl>
    <TextBlock Grid.Row="3" Text="Panda Engine - Local control panel" FontSize="10" Foreground="#8390A3" Margin="2,8,0,0"/>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Window = [Windows.Markup.XamlReader]::Load($reader)
$script:LogoPath = Join-Path (Split-Path -Parent $script:PandaDir) 'panda.png'
if (Test-Path -LiteralPath $script:LogoPath) {
  $logoSource = [Windows.Media.Imaging.BitmapImage]::new()
  $logoSource.BeginInit()
  $logoSource.UriSource = [Uri]::new($script:LogoPath)
  $logoSource.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
  $logoSource.EndInit()
  $script:LogoControl = $script:Window.FindName('LogoImage')
  $script:LogoControl.Source = $logoSource
  $script:Window.Icon = $logoSource
}
$script:MainTabs = $script:Window.FindName('MainTabs')
$script:PageBadge = $script:Window.FindName('PageBadge')
$script:CurrentPageLabel = $script:Window.FindName('CurrentPageLabel')
$script:ApiBadge = $script:Window.FindName('ApiBadge')
$script:ApiDot = $script:Window.FindName('ApiDot')
$script:ApiState = $script:Window.FindName('ApiState')
$script:RefreshButton = $script:Window.FindName('RefreshButton')
$script:StopButton = $script:Window.FindName('StopButton')
$script:SearchBox = $script:Window.FindName('SearchBox')
$script:SearchPlaceholder = $script:Window.FindName('SearchPlaceholder')
$script:FilterBox = $script:Window.FindName('FilterBox')
$script:CountText = $script:Window.FindName('CountText')
$script:ModelsList = $script:Window.FindName('ModelsList')
$script:EmptyState = $script:Window.FindName('EmptyState')
$script:EmptyStateTitle = $script:Window.FindName('EmptyStateTitle')
$script:EmptyStateMessage = $script:Window.FindName('EmptyStateMessage')
$script:DetailsExpander = $script:Window.FindName('DetailsExpander')
$script:DetailsTitle = $script:Window.FindName('DetailsTitle')
$script:DetailsId = $script:Window.FindName('DetailsId')
$script:InstallValue = $script:Window.FindName('InstallValue')
$script:ActiveValue = $script:Window.FindName('ActiveValue')
$script:ServiceValue = $script:Window.FindName('ServiceValue')
$script:ProviderValue = $script:Window.FindName('ProviderValue')
$script:FilesValue = $script:Window.FindName('FilesValue')
$script:GyroHint = $script:Window.FindName('GyroHint')
$script:UnknownRouteHint = $script:Window.FindName('UnknownRouteHint')
$script:MissingHint = $script:Window.FindName('MissingHint')
$script:ActionMessage = $script:Window.FindName('ActionMessage')
$script:ActionProgress = $script:Window.FindName('ActionProgress')
$script:ActionProgressText = $script:Window.FindName('ActionProgressText')
$script:SettingsModelBox = $script:Window.FindName('SettingsModelBox')
$script:ContextBox = $script:Window.FindName('ContextBox')
$script:ReadPicturesBox = $script:Window.FindName('ReadPicturesBox')
$script:ContextHelp = $script:Window.FindName('ContextHelp')
$script:GameModeToggle = $script:Window.FindName('GameModeToggle')
$script:GameModeState = $script:Window.FindName('GameModeState')
$script:SettingsFiles = $script:Window.FindName('SettingsFiles')
$script:SettingsSaveMessage = $script:Window.FindName('SettingsSaveMessage')
$script:SaveSettingsButton = $script:Window.FindName('SaveSettingsButton')
$script:HardwareRefreshButton = $script:Window.FindName('HardwareRefreshButton')
$script:MonitorStateBadge = $script:Window.FindName('MonitorStateBadge')
$script:MonitorStateText = $script:Window.FindName('MonitorStateText')
$script:MonitorStateHint = $script:Window.FindName('MonitorStateHint')
$script:ModelProgress = $script:Window.FindName('ModelProgress')
$script:MonitorMessage = $script:Window.FindName('MonitorMessage')
$script:MetricSpeed = $script:Window.FindName('MetricSpeed')
$script:MetricGpu = $script:Window.FindName('MetricGpu')
$script:MetricGpuName = $script:Window.FindName('MetricGpuName')
$script:MetricVram = $script:Window.FindName('MetricVram')
$script:MetricTemperature = $script:Window.FindName('MetricTemperature')
$script:MetricPower = $script:Window.FindName('MetricPower')
$script:MetricPcie = $script:Window.FindName('MetricPcie')
$script:MetricCpuRam = $script:Window.FindName('MetricCpuRam')
$script:MetricDisk = $script:Window.FindName('MetricDisk')
$script:MetricFan = $script:Window.FindName('MetricFan')
$script:MetricClock = $script:Window.FindName('MetricClock')
$script:ContextFillValue = $script:Window.FindName('ContextFillValue')
$script:ContextGaugeText = $script:Window.FindName('ContextGaugeText')
$script:ContextArc = $script:Window.FindName('ContextArc')
$script:ContextFillHint = $script:Window.FindName('ContextFillHint')
$script:MetricEnergy = $script:Window.FindName('MetricEnergy')
$script:MetricSpeedDetail = $script:Window.FindName('MetricSpeedDetail')
$script:MetricPrefill = $script:Window.FindName('MetricPrefill')
$script:MetricVramDetail = $script:Window.FindName('MetricVramDetail')
$script:MetricTempDetail = $script:Window.FindName('MetricTempDetail')
$script:MetricPowerDetail = $script:Window.FindName('MetricPowerDetail')
$script:MetricPcieDetail = $script:Window.FindName('MetricPcieDetail')
$script:MetricCpuDetail = $script:Window.FindName('MetricCpuDetail')
$script:MetricDiskDetail = $script:Window.FindName('MetricDiskDetail')
$script:SparkDecode = $script:Window.FindName('SparkDecode')
$script:SparkPrefill = $script:Window.FindName('SparkPrefill')
$script:SparkGpu = $script:Window.FindName('SparkGpu')
$script:SparkVram = $script:Window.FindName('SparkVram')
$script:SparkTemp = $script:Window.FindName('SparkTemp')
$script:SparkPower = $script:Window.FindName('SparkPower')
$script:SparkPcie = $script:Window.FindName('SparkPcie')
$script:SparkCpu = $script:Window.FindName('SparkCpu')
$script:SparkDisk = $script:Window.FindName('SparkDisk')
$script:RequestCount = $script:Window.FindName('RequestCount')
$script:RequestsEmpty = $script:Window.FindName('RequestsEmpty')
$script:RequestsGrid = $script:Window.FindName('RequestsGrid')
$script:RequestsTotals = $script:Window.FindName('RequestsTotals')
$script:ConversationCacheText = $script:Window.FindName('ConversationCacheText')
$script:LoadingSettings = $false

# Live telemetry uses a bounded Task started by Update-LiveMetrics; no UI-thread I/O.

function Set-ActionMessage([string]$Message) {
    $script:ActionMessage.Text = $Message
}

function Get-SettingsModel {
    return $script:SettingsModelBox.SelectedItem
}

function Add-ContextChoice([string]$Label, [int]$Value) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $Label
    $item.Tag = [string]$Value
    $null = $script:ContextBox.Items.Add($item)
}

function Update-SettingsControls {
    $model = Get-SettingsModel
    if (-not $model) { return }
    $script:LoadingSettings = $true
    try {
        $script:ContextBox.Items.Clear()
        if ($model.kind -eq 'mini') { $script:ReadPicturesBox.SelectedIndex = 0 } else { $script:ReadPicturesBox.SelectedIndex = 1 }
        $savedContext = if ($script:ApiStatus -and $script:ApiStatus.context) { [int]$script:ApiStatus.context } else { [int]$script:Catalog.ninfer.context }
        $gameMode = [bool]($script:ApiStatus -and $script:ApiStatus.gameMode)
        $script:GameModeToggle.IsEnabled = ($model.kind -eq 'mini') -and (-not $script:PreviewState)
        $script:GameModeToggle.IsChecked = ($model.kind -eq 'mini') -and $gameMode
        switch ([string]$model.kind) {
            'inkling' {
                Add-ContextChoice '64K tokens' 65536
                Add-ContextChoice '96K tokens' 98304
                Add-ContextChoice '128K tokens' 131072
                $script:ContextBox.IsEnabled = -not [bool]$script:PreviewState
                $script:ContextHelp.Text = 'Inkling context is saved for the next start. The currently serving backend is not restarted.'
                $script:GameModeState.Text = 'Game Mode only applies to MiniCPM.'
                $script:SettingsSaveMessage.Text = if ($script:PreviewState) { 'Demo preview is read-only.' } else { 'Context changes apply on the next start.' }
            }
            'mini' {
                Add-ContextChoice '128K - Standard' 131072
                Add-ContextChoice '64K - Adaptive Game Mode' 65536
                $script:ContextBox.IsEnabled = -not [bool]$script:PreviewState
                $script:ContextHelp.Text = 'MiniCPM exposes its supported 128K standard and 64K adaptive Game Mode profiles; arbitrary context sizes are not offered.'
                $script:GameModeState.Text = if ($gameMode) { 'Adaptive Game Mode is selected for the next MiniCPM start.' } else { 'Standard 128K profile is selected for the next MiniCPM start.' }
                $script:SettingsSaveMessage.Text = if ($script:PreviewState) { 'Demo preview is read-only.' } else { 'Game Mode changes apply on the next MiniCPM start; the current backend is left running.' }
            }
            'gyro' {
                Add-ContextChoice '128K - Fixed by Gyro-S runtime' 131072
                $script:ContextBox.IsEnabled = $false
                $script:ContextHelp.Text = 'Gyro-S context is fixed at 128K by its bundled runtime configuration.'
                $script:GameModeState.Text = 'Game Mode only applies to MiniCPM; no Gyro-S setting is changed.'
                $script:SettingsSaveMessage.Text = 'Gyro-S settings are read-only here.'
            }
            default {
                Add-ContextChoice 'Runtime default' $savedContext
                $script:ContextBox.IsEnabled = $false
                $script:ContextHelp.Text = 'This runtime does not expose a context selector in Panda Engine.'
                $script:GameModeState.Text = 'Game Mode only applies to MiniCPM.'
                $script:SettingsSaveMessage.Text = 'No editable runtime settings are available for this model.'
            }
        }
        $desiredContext = $savedContext
        if ($model.kind -eq 'mini') { $desiredContext = if ($gameMode) { 65536 } else { 131072 } }
        if ($model.kind -eq 'gyro') { $desiredContext = 131072 }
        $selectedChoice = @($script:ContextBox.Items | Where-Object { [int]$_.Tag -eq $desiredContext } | Select-Object -First 1)
        if ($selectedChoice.Count -eq 0) { $selectedChoice = @($script:ContextBox.Items | Select-Object -First 1) }
        if ($selectedChoice.Count -gt 0) { $script:ContextBox.SelectedItem = $selectedChoice[0] }
        $fileNames = @()
        if ($model.artifact) { $fileNames += [string]$model.artifact }
        if ($model.files) { $fileNames += @($model.files | ForEach-Object { [string]$_.name }) }
        if ($model.serverConfig) { $fileNames += [string]$model.serverConfig }
        if ($fileNames.Count -eq 0) { $fileNames = @('Bundled Panda Engine runtime') }
        $script:SettingsFiles.Text = $fileNames -join "`r`n"
        $script:SaveSettingsButton.IsEnabled = (-not $script:PreviewState) -and ($model.kind -in @('inkling','mini'))
        if (-not $script:ApiStatus -and -not $script:PreviewState) {
            $script:GameModeToggle.IsEnabled = $false
            $script:GameModeToggle.IsChecked = $null
            $script:ContextBox.IsEnabled = $false
            $script:ContextBox.SelectedIndex = -1
            $script:SaveSettingsButton.IsEnabled = $false
            $script:GameModeState.Text = 'Saved settings are unavailable.'
            $script:SettingsSaveMessage.Text = 'Refresh status before changing settings.'
        }
    } finally {
        $script:LoadingSettings = $false
    }
}

function Update-SettingsModelList($Status) {
    $currentId = if ($script:SettingsModelBox.SelectedItem) { [string]$script:SettingsModelBox.SelectedItem.id } else { '' }
    $script:SettingsModelBox.ItemsSource = @($script:Catalog.models)
    $preferredId = if ($currentId) { $currentId } elseif ($Status.routeModel) { [string]$Status.routeModel } elseif ($Status.activeId) { [string]$Status.activeId } else { 'minicpm-q4km' }
    $preferred = @($script:Catalog.models | Where-Object { [string]$_.id -eq $preferredId } | Select-Object -First 1)
    if ($preferred.Count -eq 0) { $preferred = @($script:Catalog.models | Where-Object { $_.kind -eq 'mini' } | Select-Object -First 1) }
    if ($preferred.Count -eq 0) { $preferred = @($script:Catalog.models | Select-Object -First 1) }
    if ($preferred.Count -gt 0) { $script:SettingsModelBox.SelectedItem = $preferred[0] }
    Update-SettingsControls
}

function Update-MonitorStatus($Status) {
    if (-not $Status) {
        $script:MonitorStateText.Text = 'Not sampled'
        $script:MonitorStateHint.Text = 'Model state is unavailable until Panda Engine status is refreshed.'
        return
    }
    if ($Status.backendRunning -and $Status.routeName) {
        $script:MonitorStateText.Text = 'Serving'
        $script:MonitorStateBadge.Background = [Windows.Media.Brushes]::Honeydew
        $script:MonitorStateHint.Text = ([string]$Status.routeName + ' is routed through the Panda Engine API. This view does not change the running model.')
    } elseif ($Status.apiRunning -and -not $Status.apiConflict) {
        $script:MonitorStateText.Text = 'Idle'
        $script:MonitorStateBadge.Background = [Windows.Media.Brushes]::AliceBlue
        $script:MonitorStateHint.Text = 'Panda Engine API is ready; no healthy model backend is currently routed.'
    } elseif ($Status.apiConflict) {
        $script:MonitorStateText.Text = 'Port conflict'
        $script:MonitorStateBadge.Background = [Windows.Media.Brushes]::Moccasin
        $script:MonitorStateHint.Text = 'Another workspace owns the API port. No stop or route action was taken.'
    } else {
        $script:MonitorStateText.Text = 'Offline'
        $script:MonitorStateBadge.Background = [Windows.Media.Brushes]::Lavender
        $script:MonitorStateHint.Text = 'Panda Engine API is offline. Monitor is read-only until an explicit action is selected.'
    }
}

function Update-HardwareMetrics {
    if ($script:PreviewState) {
        $script:MonitorMessage.Text = 'Demo preview is read-only; no live hardware sensors were queried.'
        return
    }
    $script:HardwareRefreshButton.IsEnabled = $false
    $script:MonitorMessage.Text = 'Sampling local hardware sensors only; no model or Panda Engine API is queried.'
    $script:MetricGpu.Text = 'Not sampled'
    $script:MetricGpuName.Text = 'Hardware only'
    $script:MetricVram.Text = 'Not sampled'
    $script:MetricTemperature.Text = 'Not sampled'
    $script:MetricPower.Text = 'Not sampled'
    $script:MetricFan.Text = 'Not sampled'
    $script:MetricClock.Text = 'Not sampled'
    $script:MetricCpuRam.Text = 'Not sampled'
    try {
        $gpuCommand = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
        if (-not $gpuCommand) { $gpuCommand = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue }
        if ($gpuCommand) {
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = $gpuCommand.Source
            $processInfo.Arguments = '--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed,clocks.current.graphics --format=csv,noheader,nounits'
            $processInfo.UseShellExecute = $false
            $processInfo.CreateNoWindow = $true
            $processInfo.RedirectStandardOutput = $true
            $processInfo.RedirectStandardError = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processInfo
            if ($process.Start()) {
                if ($process.WaitForExit(3000)) {
                    $line = $process.StandardOutput.ReadLine()
                    if ($line) {
                        $values = @($line -split ',\s*' | ForEach-Object { $_.Trim() })
                        if ($values.Count -ge 9) {
                            $script:MetricGpuName.Text = $values[0]
                            $script:MetricGpu.Text = $values[1] + ' %'
                            $script:MetricVram.Text = ([Math]::Round(([double]$values[2] / 1024), 1).ToString() + ' / ' +
                                [Math]::Round(([double]$values[3] / 1024), 1).ToString() + ' GB')
                            $script:MetricTemperature.Text = $values[4] + ' C'
                            $script:MetricPower.Text = $values[5] + ' / ' + $values[6] + ' W'
                            $script:MetricFan.Text = $values[7] + ' %'
                            $script:MetricClock.Text = $values[8] + ' MHz'
                        }
                    }
                } else {
                    try { $process.Kill(); $process.WaitForExit(500) | Out-Null } catch {}
                    $script:MonitorMessage.Text = 'GPU sensor query timed out; no model process was touched.'
                }
                $process.Dispose()
            }
        } else {
            $script:MetricGpu.Text = 'Unavailable'
            $script:MetricVram.Text = 'Unavailable'
            $script:MetricTemperature.Text = 'Unavailable'
            $script:MetricPower.Text = 'Unavailable'
            $script:MetricFan.Text = 'Unavailable'
            $script:MetricClock.Text = 'Unavailable'
            $script:MetricGpuName.Text = 'nvidia-smi not found'
        }
        try {
            $processors = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            if ($processors.Count -gt 0 -and $os) {
                $cpu = [Math]::Round((($processors | Measure-Object -Property LoadPercentage -Average).Average), 0)
                $totalGb = [Math]::Round(([double]$os.TotalVisibleMemorySize / 1MB), 1)
                $freeGb = [Math]::Round(([double]$os.FreePhysicalMemory / 1MB), 1)
                $script:MetricCpuRam.Text = ($cpu.ToString() + ' % CPU | ' + ($totalGb - $freeGb).ToString() + ' / ' + $totalGb.ToString() + ' GB RAM')
            }
        } catch {
            $script:MetricCpuRam.Text = 'Unavailable'
        }
        $script:MetricDisk.Text = 'Unavailable'
        $script:MetricPcie.Text = 'Not reported'
        $script:MetricSpeed.Text = 'Not reported'
        $script:MonitorMessage.Text += ' GPU/CPU/RAM values are device/host totals, not per-model measurements.'
    } catch {
        $script:MonitorMessage.Text = ('Hardware sample failed safely: ' + $_.Exception.Message)
    } finally {
        $script:HardwareRefreshButton.IsEnabled = $true
    }
}

function Get-Numeric($Value) {
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    try { return [double]$Value } catch { return $null }
}

function Get-PrometheusValue([string]$Text, [string]$Name) {
    try {
        $pattern = '(?m)^' + [regex]::Escape($Name) + '(?:\{[^}]*\})?\s+([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)'
        $match = [regex]::Match($Text, $pattern)
        if ($match.Success) {
            return [double]::Parse($match.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
        }
    } catch {}
    return $null
}

function Add-PrometheusHistory([string]$Name, $Value) {
    if ($null -eq $Value) { return }
    $series = @()
    if ($script:PromHistory.ContainsKey($Name)) { $series = @($script:PromHistory[$Name]) }
    $series += [double]$Value
    if ($series.Count -gt 60) { $series = @($series | Select-Object -Last 60) }
    $script:PromHistory[$Name] = $series
}

function Convert-PrometheusTelemetry([string]$Text) {
    if (-not $Text -or $Text.IndexOf('llamacpp:') -lt 0) { return $null }
    $gpuUtil = Get-PrometheusValue $Text 'ninfer:gpu_utilization_percent'
    $gpuMemUsed = Get-PrometheusValue $Text 'ninfer:gpu_memory_used_bytes'
    $gpuMemTotal = Get-PrometheusValue $Text 'ninfer:gpu_memory_total_bytes'
    $gpuTemp = Get-PrometheusValue $Text 'ninfer:gpu_temperature_celsius'
    $gpuPower = Get-PrometheusValue $Text 'ninfer:gpu_power_watts'
    $gpuPowerLimit = Get-PrometheusValue $Text 'ninfer:gpu_power_limit_watts'
    $gpuClock = Get-PrometheusValue $Text 'ninfer:gpu_sm_clock_mhz'
    $decodeRate = Get-PrometheusValue $Text 'llamacpp:predicted_tokens_seconds'
    $prefillRate = Get-PrometheusValue $Text 'llamacpp:prompt_tokens_seconds'
    $kvTokens = Get-PrometheusValue $Text 'llamacpp:kv_cache_tokens'
    $processing = Get-PrometheusValue $Text 'llamacpp:requests_processing'
    $requestsTotal = Get-PrometheusValue $Text 'ninfer:requests_total'
    $promptTotal = Get-PrometheusValue $Text 'llamacpp:prompt_tokens_total'
    $outputTokens = Get-PrometheusValue $Text 'llamacpp:tokens_predicted_total'

    Add-PrometheusHistory 'gpu_util' $gpuUtil
    Add-PrometheusHistory 'gpu_mem_used' $gpuMemUsed
    Add-PrometheusHistory 'gpu_temp' $gpuTemp
    Add-PrometheusHistory 'gpu_power' $gpuPower
    Add-PrometheusHistory 'cpu' $null
    Add-PrometheusHistory 'disk_read_mb' $null
    Add-PrometheusHistory 'tok_s' $decodeRate
    Add-PrometheusHistory 'prefill_tok_s_mean' $prefillRate
    Add-PrometheusHistory 'gpu_pcie_rx_mb' $null

    $history = @{}
    foreach ($key in @('gpu_util','gpu_mem_used','gpu_temp','gpu_power','cpu','disk_read_mb','tok_s','prefill_tok_s_mean','gpu_pcie_rx_mb')) {
        $history[$key] = @()
        if ($script:PromHistory.ContainsKey($key)) { $history[$key] = @($script:PromHistory[$key]) }
    }

    return [pscustomobject]@{
        live = [pscustomobject]@{
            state = if ($processing -gt 0) { 'generating' } else { 'idle' }
            queued = Get-PrometheusValue $Text 'ninfer:requests_admitted'
            phase = ''
            prompt_tokens = $kvTokens
            prompt_read = $null
            prompt_total = $null
            generated = $null
            max_tokens = $null
            tok_s = $decodeRate
            prefill_tok_s_mean = $prefillRate
            elapsed_s = Get-PrometheusValue $Text 'ninfer:uptime_seconds'
        }
        hardware = [pscustomobject]@{
            gpu_util = $gpuUtil
            gpu_mem_used = $gpuMemUsed
            gpu_mem_total = $gpuMemTotal
            gpu_temp = $gpuTemp
            gpu_power = $gpuPower
            gpu_power_limit = $gpuPowerLimit
            gpu_sm_clock = $gpuClock
            cpu = $null
            ram_used = $null
            ram_total = $null
            disk_read_mb = $null
            disk_write_mb = $null
            gpu_pcie_gen = $null
            gpu_pcie_gen_max = $null
            gpu_pcie_width = $null
            gpu_pcie_rx_mb = $null
        }
        hardware_static = [pscustomobject]@{
            gpu_name = 'NVIDIA GPU (NInfer / NVML)'
            cpu_name = $null
            cores = 0
            threads = 0
            psutil = $false
        }
        engine = [pscustomobject]@{
            max_context = [int]$script:Catalog.ninfer.context
            expert_slots = 0
        }
        history = $history
        requests = @()
        requests_kept = 0
        totals = [pscustomobject]@{
            requests = $requestsTotal
            prompt_tokens = $promptTotal
            reused = 0.0
            output_tokens = $outputTokens
        }
        conversation_cache = $null
        time = Get-PrometheusValue $Text 'ninfer:uptime_seconds'
    }
}

function Set-Sparkline($Control, $Values, [double]$Maximum = 0) {
    if (-not $Control) { return }
    $numbers = @($Values | Where-Object { $_ -ne $null } | ForEach-Object { [double]$_ })
    if ($numbers.Count -lt 2) {
        $Control.Points = New-Object System.Windows.Media.PointCollection
        return
    }
    $top = $Maximum
    foreach ($n in $numbers) { if ($n -gt $top) { $top = $n } }
    if ($top -le 0) { $top = 1 }
    $points = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $numbers.Count; $i++) {
        $x = 100.0 * $i / ($numbers.Count - 1)
        $y = 30.0 - (26.0 * [Math]::Min(1.0, [Math]::Max(0.0, $numbers[$i] / $top)))
        $points.Add([System.Windows.Point]::new($x, $y))
    }
    $Control.Points = $points
}

function Set-ContextGauge([double]$Fraction) {
    $fraction = [Math]::Max(0.0, [Math]::Min(1.0, $Fraction))
    $script:ContextGaugeText.Text = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}%', [Math]::Round($fraction * 100, 0))
    if ($fraction -le 0.001) {
        $script:ContextArc.Data = $null
        return
    }
    $sweep = [Math]::Min(359.99, $fraction * 360)
    $startRad = -[Math]::PI / 2
    $endRad = $startRad + ($sweep * [Math]::PI / 180)
    $radius = 54.0
    $x0 = 60 + $radius * [Math]::Cos($startRad)
    $y0 = 60 + $radius * [Math]::Sin($startRad)
    $x1 = 60 + $radius * [Math]::Cos($endRad)
    $y1 = 60 + $radius * [Math]::Sin($endRad)
    $largeArc = if ($sweep -gt 180) { 1 } else { 0 }
    $geometry = [string]::Format([Globalization.CultureInfo]::InvariantCulture,
        'M {0:F2},{1:F2} A {2:F2},{2:F2} 0 {3} 1 {4:F2},{5:F2}', $x0, $y0, $radius, $largeArc, $x1, $y1)
    $script:ContextArc.Data = [System.Windows.Media.Geometry]::Parse($geometry)
}

function Update-GpuFanClock {
    if ($script:PreviewState) { return }
    if ($script:GpuProbeTask) {
        if (-not $script:GpuProbeTask.IsCompleted) { return }
        $line = ''
        try { $line = [string]$script:GpuProbeTask.Result } catch {}
        $script:GpuProbeTask = $null
        if ($line) {
            $parts = @($line -split ',\s*' | ForEach-Object { $_.Trim() })
            if ($parts.Count -ge 2) {
                $script:MetricFan.Text = $parts[0] + ' %'
                $script:MetricClock.Text = $parts[1] + ' MHz'
            }
        }
        return
    }
    try {
        $gpuCommand = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
        if (-not $gpuCommand) { return }
        $script:GpuProbeTask = [PandaGpuProbe]::GetAsync($gpuCommand.Source, '--query-gpu=fan.speed,clocks.current.graphics --format=csv,noheader,nounits', 1200)
    } catch {
        # Fan and clock are optional; the backend cards stay authoritative.
    }
}

function Show-LiveMetricsFailure([string]$Message) {
    $script:LiveMetricsFailures++
    if ($script:LiveMetricsFailures -eq 3) {
        $script:MonitorMessage.Text = 'Live backend telemetry is unavailable. Click Sample hardware for local-only GPU and CPU values. (' + $Message + ')'
    }
}

function Update-LiveMetrics {
    param([string]$PayloadJson)
    if ($script:PreviewState) { return }
    if (-not $PayloadJson) {
        if ($script:MetricsTask) {
            if (-not $script:MetricsTask.IsCompleted) { return }
            $errorMessage = ''
            try { $PayloadJson = [string]$script:MetricsTask.Result } catch { $errorMessage = $_.Exception.Message }
            $script:MetricsTask = $null
            if ($errorMessage) { Show-LiveMetricsFailure $errorMessage; return }
        } else {
            $script:MetricsTask = [PandaTelemetryProbe]::GetAsync(($script:ApiBase + '/metrics'), 2000)
            return
        }
    }
    if (-not $PayloadJson) {
        Show-LiveMetricsFailure 'empty metrics payload'
        return
    }
    try {
        $metrics = $PayloadJson | ConvertFrom-Json -ErrorAction Stop
        $script:IsNinferFeed = $false
    } catch {
        # NInfer serves Prometheus text (/metrics) instead of the Panda Engine JSON feed.
        $metrics = Convert-PrometheusTelemetry $PayloadJson
        if ($null -eq $metrics) {
            Show-LiveMetricsFailure $_.Exception.Message
            return
        }
        $script:IsNinferFeed = $true
    }
    $script:LiveMetricsFailures = 0
    $script:MonitorMessage.Text = 'Live backend telemetry refreshed ' + (Get-Date -Format 'HH:mm:ss') + '. Read-only: no model was started, stopped or changed.'

    $live = $metrics.live
    $hw = $metrics.hardware
    $static = $metrics.hardware_static
    $engine = $metrics.engine
    $history = $metrics.history
    $requests = @($metrics.requests)
    $last = if ($requests.Count -gt 0) { $requests[0] } else { $null }

    # Model state and progress come from the running backend, not from the control panel.
    $state = if ($live) { [string]$live.state } else { 'idle' }
    if ($state -eq 'reading') {
        $script:MonitorStateText.Text = 'Reading prompt'
        $script:MonitorStateBadge.Background = [Windows.Media.Brushes]::AliceBlue
        $promptTotal = Get-Numeric $live.prompt_total
        $promptRead = Get-Numeric $live.prompt_read
        if ($promptTotal -gt 0 -and $null -ne $promptRead) {
            $pct = [Math]::Min(100, [Math]::Round(100 * $promptRead / $promptTotal, 0))
            $script:ModelProgress.Value = $pct
            $script:MonitorStateHint.Text = ('Reading prompt: {0:N0} / {1:N0} tokens ({2}%).' -f $promptRead, $promptTotal, $pct)
        } else {
            $script:ModelProgress.IsIndeterminate = $true
            $script:MonitorStateHint.Text = ('Reading {0:N0} prompt tokens.' -f (Get-Numeric $live.prompt_tokens))
        }
    } elseif ($state -eq 'generating') {
        $script:MonitorStateText.Text = 'Generating'
        $script:MonitorStateBadge.Background = [Windows.Media.Brushes]::Honeydew
        $script:ModelProgress.IsIndeterminate = $false
        $maxTokens = Get-Numeric $live.max_tokens
        $generated = Get-Numeric $live.generated
        $tokSpeed = Get-Numeric $live.tok_s
        if ($maxTokens -gt 0 -and $null -ne $generated) {
            $script:ModelProgress.Value = [Math]::Min(100, [Math]::Round(100 * $generated / $maxTokens, 0))
        }
        $phase = if ($live.phase) { [string]$live.phase + ' | ' } else { '' }
        $rate = if ($null -ne $tokSpeed) { (' | {0:N1} tok/s' -f $tokSpeed) } else { '' }
        $script:MonitorStateHint.Text = $phase + ('{0:N0} tokens generated{1}.' -f $generated, $rate)
        if ($script:IsNinferFeed) {
            $script:MonitorStateHint.Text = ('Generating | {0:N1} tok/s. NInfer does not expose per-request token counts.' -f (Get-Numeric $live.tok_s))
        }
    } else {
        $serving = [bool]($script:ApiStatus -and $script:ApiStatus.backendRunning)
        $script:MonitorStateText.Text = if ($serving) { 'Serving' } else { 'Idle' }
        $script:MonitorStateBadge.Background = if ($serving) { [Windows.Media.Brushes]::Honeydew } else { [Windows.Media.Brushes]::AliceBlue }
        $script:ModelProgress.IsIndeterminate = $false
        $script:ModelProgress.Value = 0
        $hint = 'Waiting for a request'
        if ($last) {
            $lastRate = Get-Numeric $last.decode_tok_s
            if ($null -ne $lastRate) { $hint += (' | last: {0:N0} tokens at {1:N1} tok/s' -f (Get-Numeric $last.output_tokens), $lastRate) }
        }
        $script:MonitorStateHint.Text = $hint
    }

    # Eight live cards. Values are taken from /metrics, the same feed the backend web monitor uses.
    $gpuUtil = Get-Numeric $hw.gpu_util
    $gpuMemUsed = Get-Numeric $hw.gpu_mem_used
    $gpuMemTotal = Get-Numeric $hw.gpu_mem_total
    $gpuTemp = Get-Numeric $hw.gpu_temp
    $gpuPower = Get-Numeric $hw.gpu_power
    $gpuPowerLimit = Get-Numeric $hw.gpu_power_limit
    $cpu = Get-Numeric $hw.cpu
    $ramUsed = Get-Numeric $hw.ram_used
    $ramTotal = Get-Numeric $hw.ram_total
    $diskRead = Get-Numeric $hw.disk_read_mb
    $diskWrite = Get-Numeric $hw.disk_write_mb
    $pcieGen = if ($hw.gpu_pcie_gen_max) { [string]$hw.gpu_pcie_gen_max } elseif ($hw.gpu_pcie_gen) { [string]$hw.gpu_pcie_gen } else { '' }
    $pcieWidth = if ($hw.gpu_pcie_width) { 'x' + [string]$hw.gpu_pcie_width } else { '' }
    $pcieRx = Get-Numeric $hw.gpu_pcie_rx_mb

    $decodeRate = Get-Numeric $live.tok_s
    if ($null -eq $decodeRate -and $last) { $decodeRate = Get-Numeric $last.decode_tok_s }
    $script:MetricSpeed.Text = if ($null -ne $decodeRate) { ('{0:N1}' -f $decodeRate) } else { '-' }
    $script:MetricSpeedDetail.Text = if ($state -eq 'generating') { 'Decode now' } elseif ($last) { 'Decode last' } else { 'Decode' }

    $prefillRate = if ($script:IsNinferFeed -or $state -ne 'idle') { Get-Numeric $live.prefill_tok_s_mean } else { $null }
    if ($null -eq $prefillRate -and $last -and (Get-Numeric $last.prompt_ms) -gt 0) {
        $fresh = [Math]::Max(0.0, (Get-Numeric $last.prompt_tokens) - (Get-Numeric $last.reused))
        $prefillRate = $fresh / ((Get-Numeric $last.prompt_ms) / 1000)
    }
    $script:MetricPrefill.Text = if ($null -ne $prefillRate) { ('{0:N0}' -f $prefillRate) } else { '-' }
    Set-Sparkline $script:SparkDecode $history.tok_s
    Set-Sparkline $script:SparkPrefill $history.prefill_tok_s_mean

    $script:MetricGpu.Text = if ($null -ne $gpuUtil) { ('{0:N0} %' -f $gpuUtil) } else { '-' }
    $script:MetricGpuName.Text = if ($static -and $static.gpu_name) { [string]$static.gpu_name } else { 'Hardware telemetry' }
    Set-Sparkline $script:SparkGpu $history.gpu_util 100

    if ($null -ne $gpuMemUsed -and $null -ne $gpuMemTotal -and $gpuMemTotal -gt 0) {
        $script:MetricVram.Text = ('{0:N1} / {1:N1} GB' -f ($gpuMemUsed / 1GB), ($gpuMemTotal / 1GB))
    } elseif ($null -ne $gpuMemUsed) {
        $script:MetricVram.Text = ('{0:N1} GB' -f ($gpuMemUsed / 1GB))
    } else {
        $script:MetricVram.Text = '-'
    }
    $script:MetricVramDetail.Text = if ($engine -and $engine.expert_slots) { ('{0:N0} experts cached' -f [double]$engine.expert_slots) } else { 'Device total / used' }
    Set-Sparkline $script:SparkVram $history.gpu_mem_used $gpuMemTotal

    $script:MetricTemperature.Text = if ($null -ne $gpuTemp) { ('{0:N0} C' -f $gpuTemp) } else { '-' }
    $script:MetricTempDetail.Text = if ($static -and $static.cpu_name) { [string]$static.cpu_name } else { 'Read-only device telemetry' }
    Set-Sparkline $script:SparkTemp $history.gpu_temp 90

    $script:MetricPower.Text = if ($null -ne $gpuPower) { ('{0:N0} W' -f $gpuPower) } else { '-' }
    $script:MetricPowerDetail.Text = if ($gpuPowerLimit -gt 0) { ('of {0:N0} W limit' -f $gpuPowerLimit) } else { 'GPU draw / limit' }
    Set-Sparkline $script:SparkPower $history.gpu_power $gpuPowerLimit

    $script:MetricPcie.Text = if ($pcieGen) { 'Gen' + $pcieGen + $pcieWidth } else { '-' }
    $script:MetricPcieDetail.Text = if ($null -ne $pcieRx) { ('to GPU {0:N1} MB/s' -f $pcieRx) } else { 'No link telemetry adapter' }
    Set-Sparkline $script:SparkPcie $history.gpu_pcie_rx_mb

    $script:MetricCpuRam.Text = if ($null -ne $cpu) { ('{0:N0} %' -f $cpu) } else { '-' }
    if ($null -ne $ramUsed -and $null -ne $ramTotal -and $ramTotal -gt 0) {
        if ($static -and $static.threads) {
            $script:MetricCpuDetail.Text = ('{0:N1} / {1:N1} GB RAM | {2:N0} threads' -f ($ramUsed / 1GB), ($ramTotal / 1GB), [double]$static.threads)
        } else {
            $script:MetricCpuDetail.Text = ('{0:N1} / {1:N1} GB RAM' -f ($ramUsed / 1GB), ($ramTotal / 1GB))
        }
    } elseif ($static -and $static.threads) {
        $script:MetricCpuDetail.Text = ('{0:N0} cores | {1:N0} threads' -f [double]$static.cores, [double]$static.threads)
    } else {
        $script:MetricCpuDetail.Text = 'Host-level telemetry'
    }
    Set-Sparkline $script:SparkCpu $history.cpu 100

    if ($null -ne $diskRead) {
        $script:MetricDisk.Text = if ($diskRead -ge 1000) { ('{0:N2} GB/s' -f ($diskRead / 1024)) } else { ('{0:N1} MB/s' -f $diskRead) }
        $script:MetricDiskDetail.Text = if ($null -ne $diskWrite) { ('write {0:N1} MB/s' -f $diskWrite) } else { 'Read throughput' }
    } else {
        $script:MetricDisk.Text = '-'
        $script:MetricDiskDetail.Text = if ($static -and -not $static.psutil) { 'needs psutil (setup installs it)' } else { 'Read throughput' }
    }
    Set-Sparkline $script:SparkDisk $history.disk_read_mb

    if ($script:IsNinferFeed) {
        $script:MetricCpuDetail.Text = 'NInfer does not expose host CPU or RAM'
        $script:MetricDiskDetail.Text = 'NInfer does not expose disk I/O'
        $script:MetricPcieDetail.Text = 'NInfer does not expose PCIe telemetry'
        $ninferClock = Get-Numeric $hw.gpu_sm_clock
        if ($null -ne $ninferClock) { $script:MetricClock.Text = ('{0:N0} MHz' -f $ninferClock) }
    }

    # Energy is not exposed by the backend feed; do not invent a value.
    $script:MetricEnergy.Text = 'Not reported'

    # Context fill: the running request, otherwise the last completed one.
    $contextMax = Get-Numeric $engine.max_context
    $used = 0.0
    if ($state -ne 'idle') {
        $used = (Get-Numeric $live.prompt_tokens) + (Get-Numeric $live.generated)
    } elseif ($last) {
        $used = (Get-Numeric $last.prompt_tokens) + (Get-Numeric $last.output_tokens)
    }
    $fraction = if ($contextMax -gt 0) { [Math]::Min(1.0, $used / $contextMax) } else { 0.0 }
    Set-ContextGauge $fraction
    $script:ContextFillValue.Text = if ($contextMax -gt 0) { ('{0:N0} / {1:N0} tokens' -f $used, $contextMax) } else { '-' }
    $script:ContextFillHint.Text = if ($state -ne 'idle') { 'Current request context usage.' } elseif ($last) { 'Context usage of the last request.' } else { 'Waiting for a request.' }

    # Recent requests, newest first.
    $totals = $metrics.totals
    $rows = @()
    foreach ($request in ($requests | Select-Object -First 12)) {
        $finish = [string]$request.finish
        $status = switch ($finish) { 'stop' { 'Done' } 'length' { 'Max tokens' } 'cancel' { 'Stopped' } 'disconnect' { 'Closed' } 'error' { 'Error' } 'nonfinite' { 'Non-finite' } 'tool_calls' { 'Tool calls' } default { if ($finish) { $finish } else { '-' } } }
        $promptTokens = Get-Numeric $request.prompt_tokens
        $reusedTokens = Get-Numeric $request.reused
        $freshTokens = [Math]::Max(0.0, $promptTokens - $reusedTokens)
        $prefillMs = Get-Numeric $request.prompt_ms
        $prefillSpeed = if ($prefillMs -gt 0) { $freshTokens / ($prefillMs / 1000) } else { 0 }
        $hitRate = Get-Numeric $request.hit_rate
        $rows += [pscustomobject]@{
            Time = [DateTimeOffset]::FromUnixTimeSeconds([long][Math]::Floor([double]$request.time)).LocalDateTime.ToString('HH:mm:ss')
            Status = [string]$status
            Prompt = ('{0:N0}' -f $promptTokens)
            Reused = ('{0:N0}' -f $reusedTokens)
            Output = ('{0:N0}' -f (Get-Numeric $request.output_tokens))
            Prefill = ('{0:N0}' -f $prefillSpeed)
            TokS = ('{0:N1}' -f (Get-Numeric $request.decode_tok_s))
            Hit = if ($null -ne $hitRate) { ('{0:N1}%' -f ($hitRate * 100)) } else { '-' }
            Duration = ('{0:N1} s' -f (Get-Numeric $request.duration_s))
        }
    }
    $newestTime = if ($rows.Count -gt 0) { [double]$requests[0].time } else { 0 }
    if ($rows.Count -ne $script:LastRequestCount -or $newestTime -ne $script:LastRequestTime) {
        $script:RequestsGrid.ItemsSource = $rows
        $script:LastRequestCount = $rows.Count
        $script:LastRequestTime = $newestTime
    }
    if ($rows.Count -gt 0) {
        $script:RequestsGrid.Visibility = 'Visible'
        $script:RequestsEmpty.Visibility = 'Collapsed'
        $script:RequestCount.Text = ('{0} of {1} kept' -f $rows.Count, [int]$metrics.requests_kept)
    } else {
        $script:RequestsGrid.Visibility = 'Collapsed'
        $script:RequestsEmpty.Visibility = 'Visible'
        if ($script:IsNinferFeed) {
            $script:RequestsEmpty.Text = 'NInfer does not expose a per-request log.'
            $script:RequestCount.Text = ('NInfer: {0:N0} requests completed' -f (Get-Numeric $totals.requests))
        } else {
            $script:RequestsEmpty.Text = 'No request telemetry has been collected.'
            $script:RequestCount.Text = 'No requests on this backend'
        }
    }
    if ($totals -and (Get-Numeric $totals.requests) -gt 0) {
        $script:RequestsTotals.Text = ('Since start: {0:N0} requests | {1:N0} prompt tokens read | {2:N0} output tokens.' -f (Get-Numeric $totals.requests), ((Get-Numeric $totals.prompt_tokens) - (Get-Numeric $totals.reused)), (Get-Numeric $totals.output_tokens))
    } else {
        $script:RequestsTotals.Text = ''
    }

    $cache = $metrics.conversation_cache
    if ($cache) {
        if ($cache.enabled) {
            $cacheNote = ('{0:N0}/{1:N0} conversations parked.' -f (Get-Numeric $cache.parked), (Get-Numeric $cache.slots))
        } else {
            $cacheNote = 'Keep the last conversation state between requests.'
        }
        $script:ConversationCacheText.Text = ('Prompt cache: {0:N0} of {1:N0} requests reused part of their prompt ({2:N0} tokens). {3}' -f
            (Get-Numeric $cache.requests_reused), (Get-Numeric $cache.requests), (Get-Numeric $cache.reused_tokens), $cacheNote)
    } elseif ($script:IsNinferFeed) {
        $script:ConversationCacheText.Text = 'NInfer reports context-cache counters in /metrics but no per-conversation state.'
    } else {
        $script:ConversationCacheText.Text = 'Cache reuse details appear when the selected runtime reports them; Panda Engine does not fabricate token or request measurements.'
    }
}

function Save-SelectedSettings {
    if ($script:PreviewState) {
        $script:SettingsSaveMessage.Text = 'Demo preview is read-only; no settings were saved.'
        return
    }
    $model = Get-SettingsModel
    if (-not $model) { return }
    if ($model.kind -eq 'inkling') {
        if (-not $script:ContextBox.SelectedItem) { return }
        $context = [int]$script:ContextBox.SelectedItem.Tag
        Start-ManagerAction 'SetContext' ([string]$model.id) $context
    } elseif ($model.kind -eq 'mini') {
        $gameMode = ([bool]$script:GameModeToggle.IsChecked).ToString().ToLowerInvariant()
        Start-ManagerAction 'SetGameMode' ([string]$model.id) -1 $gameMode
    } else {
        $script:SettingsSaveMessage.Text = 'This model has no editable next-start settings in Panda Engine.'
    }
}

function Set-UiBusy([bool]$IsBusy) {
    $script:RefreshButton.IsEnabled = -not $IsBusy
    $script:SearchBox.IsEnabled = -not $IsBusy
    $script:FilterBox.IsEnabled = -not $IsBusy
    $script:ModelsList.IsEnabled = -not $IsBusy
    $script:SettingsModelBox.IsEnabled = -not $IsBusy
    $settingsAvailable = (-not $IsBusy) -and [bool]$script:ApiStatus -and (-not $script:PreviewState)
    $script:ContextBox.IsEnabled = $settingsAvailable -and ($script:SettingsModelBox.SelectedItem -and $script:SettingsModelBox.SelectedItem.kind -in @('inkling','mini'))
    $script:GameModeToggle.IsEnabled = $settingsAvailable -and ($script:SettingsModelBox.SelectedItem -and $script:SettingsModelBox.SelectedItem.kind -eq 'mini')
    $script:SaveSettingsButton.IsEnabled = $settingsAvailable -and ($script:SettingsModelBox.SelectedItem -and $script:SettingsModelBox.SelectedItem.kind -in @('inkling','mini'))
    $script:HardwareRefreshButton.IsEnabled = -not $IsBusy
    $canStop = $script:ApiStatus -and $script:ApiStatus.apiRunning -and -not $script:ApiStatus.apiConflict
    $script:StopButton.IsEnabled = (-not $IsBusy) -and [bool]$canStop
}

function Convert-StatusToRows($Status) {
    $rows = @(
        foreach ($model in @($Status.models)) {
            $runtime = switch ([string]$model.kind) {
                'inkling' { 'NInfer' }
                'mini'    { 'MiniCPM' }
                'gyro'    { 'Gyro-S' }
                default   { [string]$model.kind }
            }
            $runtimeGlyph = switch ([string]$model.kind) {
                'inkling' { 'N' }
                'mini'    { 'M' }
                'gyro'    { 'G' }
                default   { 'AI' }
            }
            $installLabel = if ($model.installed) { 'Installed' } elseif ($model.canInstall) { 'Not installed' } else { 'Bundled files missing' }
            $activeLabel = if ($model.active) { 'Selected' } else { 'Not selected' }
            $serviceLabel = if ($model.running) { 'Running' } elseif ($Status.routeModel -eq $model.id) { 'Route not healthy' } else { 'Not serving' }
            $statusParts = @($installLabel)
            if ($model.active) { $statusParts += 'Selected for next start' }
            if ($model.running) { $statusParts += 'Running' } elseif ($Status.routeModel -eq $model.id) { $statusParts += 'Route not healthy' } else { $statusParts += 'Not serving' }
            $actionKind = 'None'
            $actionLabel = 'Running'
            $actionEnabled = $false
            if (-not $model.installed) {
                if ($model.canInstall) {
                    $actionKind = 'Install'
                    $actionLabel = 'Install model'
                    $actionEnabled = $true
                } else {
                    $actionLabel = 'Files missing'
                }
            } elseif (-not $model.active) {
                $actionKind = 'SetActive'
                $actionLabel = 'Set active'
                $actionEnabled = $true
            } elseif (-not $model.running) {
                $actionKind = 'Start'
                $actionLabel = 'Start model'
                $actionEnabled = -not [bool]$Status.apiConflict
            }
            [pscustomobject]@{
                Id            = [string]$model.id
                Name          = [string]$model.label
                Runtime       = [string]$runtime
                RuntimeGlyph  = [string]$runtimeGlyph
                Provider      = [string]$model.provider
                Files         = @($model.files)
                Installed     = [bool]$model.installed
                Active        = [bool]$model.active
                Running       = [bool]$model.running
                CanInstall    = [bool]$model.canInstall
                InstallLabel  = [string]$installLabel
                ActiveLabel   = [string]$activeLabel
                ServiceLabel  = [string]$serviceLabel
                StatusSummary = [string]($statusParts -join ' | ')
                ActionKind    = [string]$actionKind
                ActionLabel   = [string]$actionLabel
                ActionEnabled = ([bool]$actionEnabled -and (-not [bool]$script:PreviewState))
                ActionAccessibleName = [string]($actionLabel + ' for ' + [string]$model.label)
            }
        }
    )
    return $rows
}

function Show-ModelDetails($Model) {
    if (-not $Model) {
        $script:DetailsTitle.Text = 'Choose a model'
        $script:DetailsId.Text = 'Select a card to inspect its catalog details.'
        $script:InstallValue.Text = '-'
        $script:ActiveValue.Text = '-'
        $script:ServiceValue.Text = '-'
        $script:ProviderValue.Text = '-'
        $script:FilesValue.Text = '-'
        $script:DetailsExpander.IsEnabled = $false
        $script:DetailsExpander.IsExpanded = $false
        $script:GyroHint.Visibility = 'Collapsed'
        $script:MissingHint.Visibility = 'Collapsed'
        return
    }

    $script:DetailsTitle.Text = $Model.Name
    $script:DetailsId.Text = $Model.Id
    $script:InstallValue.Text = $Model.InstallLabel
    $script:ActiveValue.Text = if ($script:StatusUnavailable) { 'Status unknown' } elseif ($Model.Active) { 'Selected for the next start' } else { 'Not selected' }
    $script:ServiceValue.Text = if ($script:StatusUnavailable) { 'Status unknown; API check failed' } elseif ($Model.Running) { 'Running; healthy upstream confirmed' } elseif ($Model.ServiceLabel -eq 'Route not healthy') { 'Route exists, but the backend is not healthy' } else { 'Not currently serving' }
    $script:ProviderValue.Text = if ($Model.Provider) { $Model.Provider } else { 'Not specified in catalog' }
    $script:FilesValue.Text = if ($Model.Files.Count -gt 0) { $Model.Files -join "`r`n" } else { 'Bundled Panda Engine runtime' }
    $script:DetailsExpander.IsEnabled = $true
    $script:GyroHint.Visibility = if ($Model.Runtime -eq 'Gyro-S' -and -not $Model.Installed) { 'Visible' } else { 'Collapsed' }
    $script:MissingHint.Visibility = if (-not $Model.Installed -and -not $Model.CanInstall) { 'Visible' } else { 'Collapsed' }
}

function Invoke-ModelAction($Model) {
    if ($script:PreviewState) {
        Set-ActionMessage 'Preview mode is read-only. Close this window to return to the live model library.'
        return
    }
    if ($script:Busy -or -not $Model -or -not $Model.ActionEnabled) { return }
    switch ([string]$Model.ActionKind) {
        'Install' {
            $answer = [Windows.MessageBox]::Show(
                ('Install ' + $Model.Name + '? This may download model files. Download progress is shown when the file size is available.'),
                'Install model',
                [Windows.MessageBoxButton]::YesNo,
                [Windows.MessageBoxImage]::Question
            )
            if ($answer -eq [Windows.MessageBoxResult]::Yes) { Start-ManagerAction 'Install' $Model.Id }
        }
        'SetActive' {
            if ($Model.Installed) { Start-ManagerAction 'SetActive' $Model.Id }
        }
        'Start' {
            if ($script:ApiStatus -and $script:ApiStatus.apiConflict) {
                Set-ActionMessage 'Another workspace owns the public API port. Resolve that conflict before starting a model here.'
                return
            }
            if ($script:ApiStatus -and $script:ApiStatus.backendRunning -and
                $script:ApiStatus.routeModel -ne $Model.Id -and [string]$script:ApiStatus.routeModel -ne 'gyro-s') {
                $switchMessage = 'Starting ' + $Model.Name + ' will stop the currently serving backend and change the Panda Engine API route. Continue?'
                $answer = [Windows.MessageBox]::Show(
                    $switchMessage,
                    'Confirm backend stop and model switch',
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Warning
                )
                if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
            }
            Start-ManagerAction 'Start' $Model.Id
        }
    }
}

function Apply-ModelFilter {
    $query = ([string]$script:SearchBox.Text).Trim()
    $filter = [string]$script:FilterBox.SelectedItem.Content
    $selectedId = if ($script:ModelsList.SelectedItem) { [string]$script:ModelsList.SelectedItem.Id } else { '' }
    $visible = @(
        $script:Models | Where-Object {
            $matchesQuery = (-not $query) -or ($_.Name -like ('*' + $query + '*')) -or ($_.Id -like ('*' + $query + '*')) -or ($_.Provider -like ('*' + $query + '*'))
            $matchesFilter = if ($filter -eq 'Installed') {
                $_.Installed
            } elseif ($filter -eq 'Not installed') {
                -not $_.Installed
            } else {
                $true
            }
            $matchesQuery -and $matchesFilter
        }
    )
    $script:ModelsList.ItemsSource = $visible
    $script:CountText.Text = ($visible.Count.ToString() + ' of ' + $script:Models.Count.ToString() + ' models')
    if ($visible.Count -eq 0) {
        $script:EmptyState.Visibility = 'Visible'
        if (@($script:Models).Count -eq 0) {
            $script:EmptyStateTitle.Text = 'The model catalog is empty'
            $script:EmptyStateMessage.Text = 'Add model entries to panda/catalog.json, then refresh.'
        } else {
            $script:EmptyStateTitle.Text = 'No models match this search'
            $script:EmptyStateMessage.Text = 'Try another name or filter.'
        }
    } else {
        $script:EmptyState.Visibility = 'Collapsed'
    }
    if ($visible.Count -gt 0) {
        $selected = $null
        if ($selectedId) {
            $selected = $visible | Where-Object { $_.Id -eq $selectedId } | Select-Object -First 1
        }
        if (-not $selected) { $selected = $visible[0] }
        $script:ModelsList.SelectedItem = $selected
        Show-ModelDetails $selected
    } else {
        Show-ModelDetails $null
    }
}

function Update-SearchPlaceholder {
    $script:SearchPlaceholder.Visibility = if ([string]::IsNullOrEmpty($script:SearchBox.Text)) { 'Visible' } else { 'Collapsed' }
}

function Set-ApiUnavailable([string]$Message) {
    $script:StatusUnavailable = $true
    $script:ApiStatus = $null
    $script:ApiState.Text = 'API status unavailable'
    $script:ApiBadge.Background = [Windows.Media.Brushes]::Moccasin
    $script:ApiDot.Fill = [Windows.Media.Brushes]::DarkOrange
    $script:StopButton.IsEnabled = $false
    foreach ($model in @($script:Models)) {
        $model.ActionKind = 'None'
        $model.ActionLabel = 'Status unknown'
        $model.ActionEnabled = $false
        $model.StatusSummary = [string]$model.InstallLabel + ' | Status unknown'
    }
    $script:ModelsList.Items.Refresh()
    if ($script:ModelsList.SelectedItem) {
        Show-ModelDetails $script:ModelsList.SelectedItem
    }
    if (@($script:Models).Count -eq 0) {
        $script:EmptyStateTitle.Text = 'API status unavailable'
        $script:EmptyStateMessage.Text = 'Check the local API, then select Refresh to retry.'
        $script:EmptyState.Visibility = 'Visible'
    }
    Update-SettingsModelList ([pscustomobject]@{ activeId = ''; routeModel = ''; gameMode = $false; context = [int]$script:Catalog.ninfer.context })
    Update-MonitorStatus $null
    Set-ActionMessage ('Status unavailable: ' + $Message + ' Use Refresh to retry.')
}

function Update-ApiStatus($Status) {
    $script:StatusUnavailable = $false
    $script:ApiStatus = $Status
    $listedIds = @($Status.models | ForEach-Object { [string]$_.id })
    $unknownRoute = $Status.backendRunning -and ((-not $Status.routeModel) -or ($listedIds -notcontains [string]$Status.routeModel))
    if ($Status.apiConflict) {
        $script:ApiState.Text = 'API port in use outside this workspace'
        $script:ApiBadge.Background = [Windows.Media.Brushes]::Moccasin
        $script:ApiDot.Fill = [Windows.Media.Brushes]::DarkOrange
        $script:UnknownRouteHint.Visibility = 'Visible'
    } elseif ($unknownRoute) {
        $script:ApiState.Text = 'API route not mapped to this catalog'
        $script:ApiBadge.Background = [Windows.Media.Brushes]::Moccasin
        $script:ApiDot.Fill = [Windows.Media.Brushes]::DarkOrange
        $script:UnknownRouteHint.Visibility = 'Visible'
    } elseif (-not $Status.apiRunning) {
        $script:ApiState.Text = 'API offline'
        $script:ApiBadge.Background = [Windows.Media.Brushes]::Lavender
        $script:ApiDot.Fill = [Windows.Media.Brushes]::SlateBlue
        $script:UnknownRouteHint.Visibility = 'Collapsed'
    } elseif ($Status.backendRunning -and $Status.routeModel -and $Status.routeName) {
        $script:ApiState.Text = ('Serving: ' + [string]$Status.routeName)
        $script:ApiBadge.Background = [Windows.Media.Brushes]::Honeydew
        $script:ApiDot.Fill = [Windows.Media.Brushes]::SeaGreen
        $script:UnknownRouteHint.Visibility = 'Collapsed'
    } elseif ($Status.backendRunning) {
        $script:ApiState.Text = 'API route not mapped to this catalog'
        $script:ApiBadge.Background = [Windows.Media.Brushes]::Moccasin
        $script:ApiDot.Fill = [Windows.Media.Brushes]::DarkOrange
        $script:UnknownRouteHint.Visibility = 'Visible'
    } else {
        $script:ApiState.Text = 'API ready - no healthy backend'
        $script:ApiBadge.Background = [Windows.Media.Brushes]::AliceBlue
        $script:ApiDot.Fill = [Windows.Media.Brushes]::DodgerBlue
        $script:UnknownRouteHint.Visibility = 'Collapsed'
    }
    $script:StopButton.IsEnabled = [bool]($Status.apiRunning -and -not $Status.apiConflict -and -not $script:Busy -and -not $script:PreviewState)
    $script:Models = Convert-StatusToRows $Status
    if ($script:PreviewState) {
        foreach ($model in @($script:Models)) {
            $model.ActionKind = 'None'
            $model.ActionLabel = 'Preview only'
            $model.ActionEnabled = $false
            $model.ActionAccessibleName = 'Preview only for ' + $model.Name
        }
    }
    Apply-ModelFilter
    Update-SettingsModelList $Status
    Update-MonitorStatus $Status
}

function Get-DemoStatus {
    $rows = @(
        foreach ($model in @($script:Catalog.models)) {
            $files = @()
            if ($model.artifact) { $files += [string]$model.artifact }
            if ($model.files) { $files += @($model.files | ForEach-Object { [string]$_.name }) }
            if ($model.serverConfig) { $files += [string]$model.serverConfig }
            [pscustomobject]@{
                id = [string]$model.id
                label = [string]$model.label
                kind = [string]$model.kind
                provider = [string]$model.provider
                files = @($files)
                installed = $true
                active = ([string]$model.id -eq 'minicpm-q4km')
                running = $false
                canInstall = ($model.kind -ne 'gyro')
            }
        }
    )
    return [pscustomobject]@{
        success = $true
        action = 'demo'
        activeId = 'minicpm-q4km'
        activeLabel = 'MiniCPM-V 4.7 35B (Q4_K_M)'
        apiRunning = $false
        apiConflict = $false
        backendRunning = $false
        routeModel = ''
        routeName = ''
        routePort = 0
        gameMode = $true
        context = [int]$script:Catalog.ninfer.context
        models = $rows
    }
}

function Read-ManagerResult($Pending) {
    $text = ''
    if (Test-Path -LiteralPath $Pending.OutputPath) {
        $text = Get-Content -LiteralPath $Pending.OutputPath -Raw -ErrorAction SilentlyContinue
    }
    $jsonLine = @($text -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)
    if ($jsonLine.Count -gt 0) {
        try {
            $result = $jsonLine[0] | ConvertFrom-Json
            if (-not $result.success -and -not $result.requiresGyroStopAuthorization) {
                $details = @($text -split "`r?`n" | Where-Object { $_ -match '^\s*(ERROR|WARNING):' } | Select-Object -Last 2)
                if ($details.Count) {
                    $detailText = (($details | ForEach-Object { $_.Trim() }) -join ' ')
                    if ($detailText.Length -gt 500) { $detailText = $detailText.Substring(0, 500) }
                    $result.message = ([string]$result.message + ' ' + $detailText)
                }
                if (Test-Path -LiteralPath $Pending.ErrorPath) {
                    $errorLines = @(Get-Content -LiteralPath $Pending.ErrorPath -Tail 50 -ErrorAction SilentlyContinue |
                        Where-Object { $_ -match '(?i)(curl:\s*\(\d+\)|error|exception|failed)' } | Select-Object -Last 1)
                    if ($errorLines.Count) {
                        $errorLine = $errorLines[0].Trim()
                        if ($errorLine.Length -gt 300) { $errorLine = $errorLine.Substring($errorLine.Length - 300) }
                        $result.message = ([string]$result.message + ' ' + $errorLine)
                    }
                }
            }
            return $result
        } catch {}
    }
    $errorText = ''
    if (Test-Path -LiteralPath $Pending.ErrorPath) {
        $errorText = (Get-Content -LiteralPath $Pending.ErrorPath -Raw -ErrorAction SilentlyContinue)
    }
    if ($errorText.Length -gt 500) { $errorText = $errorText.Substring($errorText.Length - 500) }
    if (-not $errorText) { $errorText = 'The launcher did not return a status response.' }
    return [pscustomobject]@{ success = $false; message = $errorText.Trim() }
}

function Start-ManagerAction([string]$Action, [string]$SelectedModelId = '', [int]$Context = -1, [string]$GameMode = '', [bool]$AuthorizeGyroStop = $false) {
    if ($script:PreviewState) {
        Set-ActionMessage 'Preview mode is read-only. Close this window to return to the live model library.'
        return
    }
    if ($script:Busy) { return }
    $script:Busy = $true
    if ($Action -in @('SetContext','SetGameMode')) { $script:SettingsActionPending = $true }
    Set-UiBusy $true
    $busyMessage = switch ($Action) {
        'Initialize' { 'Starting the Panda Engine API...' }
        'Status' { 'Refreshing model and service status...' }
        'Install' { 'Installing model. Controls are disabled while this runs.' }
        'Start' { 'Starting model and updating the route...' }
        'Stop' { 'Stopping the API and backends...' }
        default { 'Updating Panda Engine...' }
    }
    Set-ActionMessage $busyMessage
    $script:ActionProgress.Visibility = if ($Action -in @('Install','Start')) { 'Visible' } else { 'Collapsed' }
    $script:ActionProgressText.Visibility = $script:ActionProgress.Visibility
    $script:ActionProgress.IsIndeterminate = $true
    $script:ActionProgressText.Text = if ($Action -eq 'Start') { 'Loading; the backend does not report a percentage.' } else { 'Preparing; progress is unavailable until the download starts.' }

    $token = [guid]::NewGuid().ToString('N')
    $outPath = Join-Path $env:TEMP ('panda-engine-gui-' + $token + '.out')
    $errPath = Join-Path $env:TEMP ('panda-engine-gui-' + $token + '.err')
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ManagerScript + '"'), '-GuiAction', $Action)
    if ($SelectedModelId) { $arguments += @('-ModelId', $SelectedModelId) }
    if ($Context -ge 0) { $arguments += @('-Context', [string]$Context) }
    if ($GameMode) { $arguments += @('-GameMode', $GameMode) }
    if ($AuthorizeGyroStop) { $arguments += '-AuthorizeGyroStop' }
    $timeoutSeconds = switch ($Action) {
        'Status' { 15 }
        'Initialize' { 60 }
        'Install' { 14400 }
        'Start' { 120 }
        'Stop' { 60 }
        'SetActive' { 30 }
        'SetContext' { 30 }
        'SetGameMode' { 30 }
        default { 60 }
    }
    try {
        $process = Start-Process -FilePath $script:PowerShellExe -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $script:PandaDir) `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $script:PendingAction = @{
            Process = $process
            Action = $Action
            ModelId = $SelectedModelId
            OutputPath = $outPath
            ErrorPath = $errPath
            StartedAt = [DateTime]::UtcNow
            TimeoutSeconds = $timeoutSeconds
        }
        $script:ActionTimer.Start()
    } catch {
        $script:Busy = $false
        $script:ActionProgress.Visibility = 'Collapsed'
        $script:ActionProgressText.Visibility = 'Collapsed'
        Set-UiBusy $false
        Set-ActionMessage ('Could not start the launcher action: ' + $_.Exception.Message)
    }
}

$script:LiveTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:LiveTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
$script:LiveTimer.Add_Tick({
    if ($script:PreviewState) { return }
    $selectedTab = $script:MainTabs.SelectedItem
    if (-not $selectedTab -or [string]$selectedTab.Header -ne 'Monitor') { return }
    try {
        $script:MonitorTick++
        Update-LiveMetrics
        if ($script:MonitorTick % 5 -eq 0) { Update-GpuFanClock }
    } catch {
        # A telemetry failure must never stop the UI dispatcher.
    }
})
$script:LiveTimer.Start()

$script:ActionTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ActionTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:ActionTimer.Add_Tick({
    if (-not $script:PendingAction) {
        $script:ActionTimer.Stop()
        return
    }
    if (-not $script:PendingAction.Process.HasExited) {
        if ($script:PendingAction.Action -eq 'Install') {
            try {
                $marker = @(Get-Content -LiteralPath $script:PendingAction.OutputPath -ErrorAction Stop |
                    Where-Object { $_ -match '^PANDA_DOWNLOAD (?:[A-Za-z0-9+/=]+) \d+$|^PANDA_DOWNLOAD_END$' } | Select-Object -Last 1)
                if ($marker.Count -and $marker[0] -match '^PANDA_DOWNLOAD ([A-Za-z0-9+/=]+) (\d+)$') {
                    $partPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
                    $total = [long]$Matches[2]
                    if (Test-Path -LiteralPath $partPath) {
                        $downloaded = [long](Get-Item -LiteralPath $partPath -ErrorAction Stop).Length
                        if ($total -gt 0) {
                            $percent = [Math]::Min(100, [Math]::Round(100.0 * $downloaded / $total, 1))
                            $script:ActionProgress.IsIndeterminate = $false
                            $script:ActionProgress.Value = $percent
                            $script:ActionProgressText.Text = ('Current file: ' + $percent + '% (' + [Math]::Round($downloaded / 1MB, 1) + ' / ' + [Math]::Round($total / 1MB, 1) + ' MiB)')
                        } else {
                            $script:ActionProgress.IsIndeterminate = $true
                            $script:ActionProgressText.Text = ('Current file: ' + [Math]::Round($downloaded / 1MB, 1) + ' MiB downloaded; total unknown.')
                        }
                    } else {
                        $script:ActionProgress.IsIndeterminate = $true
                        $script:ActionProgressText.Text = 'Preparing, verifying or extracting files; progress unavailable.'
                    }
                } else {
                    $script:ActionProgress.IsIndeterminate = $true
                    $script:ActionProgressText.Text = 'Preparing, verifying or extracting files; progress unavailable.'
                }
            } catch {}
        }
        $elapsed = ([DateTime]::UtcNow - $script:PendingAction.StartedAt).TotalSeconds
        if ($elapsed -lt $script:PendingAction.TimeoutSeconds) { return }

        $timedOut = $script:PendingAction
        $script:ActionTimer.Stop()
        $script:PendingAction = $null
        $script:ActionProgress.Visibility = 'Collapsed'
        $script:ActionProgressText.Visibility = 'Collapsed'
        if ($timedOut.Action -notin @('Start','Stop')) {
            try { & taskkill.exe /PID $timedOut.Process.Id /T /F 2>$null | Out-Null } catch {}
        }
        if (-not $timedOut.Process.HasExited) {
            Stop-Process -Id $timedOut.Process.Id -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $timedOut.OutputPath, $timedOut.ErrorPath -Force -ErrorAction SilentlyContinue
        $script:Busy = $false
        Set-UiBusy $false
        $timeoutCleanupMessage = if ($timedOut.Action -in @('Start','Stop')) {
            'Only the manager process was stopped; child backend processes were left untouched.'
        } else {
            'Its launcher process tree was stopped.'
        }
        $script:AfterStatusMessage = ($timedOut.Action + ' timed out. ' + $timeoutCleanupMessage + ' Refresh and verify state before retrying.')
        Start-ManagerAction 'Status'
        return
    }

    $script:ActionTimer.Stop()
    $pending = $script:PendingAction
    $script:PendingAction = $null
    $script:ActionProgress.Visibility = 'Collapsed'
    $script:ActionProgressText.Visibility = 'Collapsed'
    $script:Busy = $false
    Set-UiBusy $false
    $result = Read-ManagerResult $pending
    Remove-Item -LiteralPath $pending.OutputPath, $pending.ErrorPath -Force -ErrorAction SilentlyContinue

    if ($pending.Action -eq 'Status') {
        if ($result.success) {
            Update-ApiStatus $result
            if ($script:SettingsActionPending -and $script:AfterStatusMessage) {
                $script:SettingsSaveMessage.Text = $script:AfterStatusMessage
                $script:SettingsActionPending = $false
            }
            if ($script:AfterStatusMessage) {
                Set-ActionMessage $script:AfterStatusMessage
                $script:AfterStatusMessage = ''
            } else {
                Set-ActionMessage 'Status refreshed. Selecting a row does not change the active model.'
            }
        } else {
            Set-ApiUnavailable ([string]$result.message)
            if ($script:SettingsActionPending -and $script:AfterStatusMessage) {
                $script:SettingsSaveMessage.Text = $script:AfterStatusMessage
                $script:SettingsActionPending = $false
                $script:AfterStatusMessage = ''
            }
        }
        return
    }

    if ($result.requiresGyroStopAuthorization) {
        $authorizationMessage = [string]$result.message + "`r`n`r`nContinue only if you explicitly authorize stopping Gyro-S."
        $answer = [Windows.MessageBox]::Show(
            $authorizationMessage,
            'Authorize stopping Gyro-S',
            [Windows.MessageBoxButton]::YesNo,
            [Windows.MessageBoxImage]::Warning
        )
        if ($answer -eq [Windows.MessageBoxResult]::Yes) {
            Start-ManagerAction -Action ([string]$pending.Action) -SelectedModelId ([string]$pending.ModelId) -AuthorizeGyroStop $true
        } else {
            Set-ActionMessage 'Gyro-S was not stopped. No backend switch or stop was performed.'
        }
        return
    }

    if (-not $result.success) {
        $script:AfterStatusMessage = [string]$result.message
        Start-ManagerAction 'Status'
        return
    }
    $script:AfterStatusMessage = [string]$result.message
    Start-ManagerAction 'Status'
})

$script:SearchBox.Add_TextChanged({
    Update-SearchPlaceholder
    Apply-ModelFilter
})
$script:FilterBox.Add_SelectionChanged({ Apply-ModelFilter })
$script:SettingsModelBox.Add_SelectionChanged({
    if (-not $script:LoadingSettings) { Update-SettingsControls }
})
$script:ContextBox.Add_SelectionChanged({
    if ($script:LoadingSettings -or -not $script:ContextBox.SelectedItem) { return }
    $model = Get-SettingsModel
    if ($model -and $model.kind -eq 'mini') {
        $script:GameModeToggle.IsChecked = ([int]$script:ContextBox.SelectedItem.Tag -eq 65536)
    }
})
$script:GameModeToggle.Add_Checked({
    if ($script:LoadingSettings) { return }
    $choice = @($script:ContextBox.Items | Where-Object { [int]$_.Tag -eq 65536 } | Select-Object -First 1)
    if ($choice.Count -gt 0) { $script:ContextBox.SelectedItem = $choice[0] }
    $script:GameModeState.Text = 'Adaptive Game Mode is selected for the next MiniCPM start.'
})
$script:GameModeToggle.Add_Unchecked({
    if ($script:LoadingSettings) { return }
    $choice = @($script:ContextBox.Items | Where-Object { [int]$_.Tag -eq 131072 } | Select-Object -First 1)
    if ($choice.Count -gt 0) { $script:ContextBox.SelectedItem = $choice[0] }
    $script:GameModeState.Text = 'Standard 128K profile is selected for the next MiniCPM start.'
})
$script:SaveSettingsButton.Add_Click({ Save-SelectedSettings })
$script:HardwareRefreshButton.Add_Click({
    Update-HardwareMetrics
    Update-LiveMetrics
    Update-GpuFanClock
})
$script:ModelsList.Add_SelectionChanged({
    if ($script:ModelsList.SelectedItem) { Show-ModelDetails $script:ModelsList.SelectedItem }
})
$script:MainTabs.Add_SelectionChanged({
    $selectedTab = $script:MainTabs.SelectedItem
    if (-not $selectedTab) { return }
    $pageName = [string]$selectedTab.Header
    $script:CurrentPageLabel.Text = $pageName.ToUpperInvariant()
    [System.Windows.Automation.AutomationProperties]::SetName($script:PageBadge, ('Current page: ' + $pageName))
    if ($pageName -eq 'Monitor' -and -not $script:PreviewState) {
        Start-ManagerAction 'Status'
        Update-LiveMetrics
        Update-GpuFanClock
    }
})
$script:ModelsList.AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($sender, $eventArgs)
        $button = $eventArgs.OriginalSource
        if ($button -is [System.Windows.Controls.Button] -and [string]$button.Tag -eq 'ModelAction') {
            $script:ModelsList.SelectedItem = $button.DataContext
            Invoke-ModelAction $button.DataContext
            $eventArgs.Handled = $true
        }
    },
    $true
)
$script:RefreshButton.Add_Click({ Start-ManagerAction 'Status' })
$script:StopButton.Add_Click({
    if ($script:ApiStatus -and [string]$script:ApiStatus.routeModel -eq 'gyro-s') {
        Start-ManagerAction 'Stop'
        return
    }
    $stopMessage = 'This stops the Panda Engine API and all owned backends. Connected clients will lose service. If a Gyro-S ownership record exists, Panda Engine will ask for separate authorization before attempting to stop it. Continue?'
    $answer = [Windows.MessageBox]::Show(
        $stopMessage,
        'Confirm stop of Panda Engine',
        [Windows.MessageBoxButton]::YesNo,
        [Windows.MessageBoxImage]::Warning
    )
    if ($answer -eq [Windows.MessageBoxResult]::Yes) { Start-ManagerAction 'Stop' }
})
$script:Window.Add_ContentRendered({
    Update-SearchPlaceholder
    if ($script:PreviewState -eq 'RefreshError') {
        Set-ApiUnavailable 'Preview fixture: simulated status request failure.'
    } elseif ($script:PreviewState -eq 'EmptyCatalog') {
        $emptyStatus = [pscustomobject]@{
            success = $true
            action = 'status'
            apiRunning = $true
            apiConflict = $false
            backendRunning = $false
            routeModel = ''
            routeName = ''
            routePort = 0
            models = @()
        }
        Update-ApiStatus $emptyStatus
        Set-ActionMessage 'The catalog is empty. Add model entries to panda/catalog.json, then refresh.'
    } elseif ($script:PreviewState -in @('Demo','DemoLoading','DemoDownload')) {
        $demoStatus = Get-DemoStatus
        Update-ApiStatus $demoStatus
        $script:RefreshButton.IsEnabled = $false
        $script:StopButton.IsEnabled = $false
        $script:HardwareRefreshButton.IsEnabled = $false
        $script:ApiState.Text = 'DEMO PREVIEW - no live API query'
        $script:ApiBadge.Background = [Windows.Media.Brushes]::AliceBlue
        $script:ApiDot.Fill = [Windows.Media.Brushes]::DodgerBlue
        $script:MonitorStateText.Text = 'Demo preview'
        $script:MonitorStateBadge.Background = [Windows.Media.Brushes]::AliceBlue
        $script:MonitorStateHint.Text = 'Synthetic layout preview. No live model status or hardware metrics were queried.'
        $script:SettingsSaveMessage.Text = 'Demo preview is read-only; no settings were saved.'
        Set-ActionMessage 'Demo preview is read-only. No live service was queried.'
        if ($script:PreviewState -in @('DemoLoading','DemoDownload')) {
            $script:ActionProgress.Visibility = 'Visible'
            $script:ActionProgressText.Visibility = 'Visible'
            if ($script:PreviewState -eq 'DemoLoading') {
                $script:ActionProgress.IsIndeterminate = $true
                $script:ActionProgressText.Text = 'Loading; the backend does not report a percentage.'
            } else {
                $script:ActionProgress.IsIndeterminate = $false
                $script:ActionProgress.Value = 45
                $script:ActionProgressText.Text = 'Synthetic preview: current file 45% (450 / 1000 MiB).'
            }
        }
    } elseif ($SkipInitialize) { Start-ManagerAction 'Status' }
    else { Start-ManagerAction 'Initialize' }
})

$null = $script:Window.ShowDialog()

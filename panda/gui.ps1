param(
    [switch]$SkipInitialize,
    [ValidateSet('', 'RefreshError','EmptyCatalog','Demo')]
    [string]$PreviewState = ''
)

$ErrorActionPreference = 'Stop'
$script:PandaDir = $PSScriptRoot
$script:ManagerScript = Join-Path $script:PandaDir 'panda.ps1'
$script:CatalogPath = Join-Path $script:PandaDir 'catalog.json'
$script:PowerShellExe = Join-Path $PSHOME 'powershell.exe'
$script:Catalog = Get-Content -LiteralPath $script:CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:Models = @()
$script:ApiStatus = $null
$script:PendingAction = $null
$script:Busy = $false
$script:StatusUnavailable = $false
$script:AfterStatusMessage = ''
$script:SettingsActionPending = $false
$script:PreviewState = $PreviewState

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

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
          <Border Width="42" Height="42" CornerRadius="11" Background="#E7EEFC" BorderBrush="#D6E1F8" BorderThickness="1">
            <TextBlock Text="P" FontSize="20" FontWeight="Bold" Foreground="#2E68E8"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
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
            <TextBlock x:Name="ApiState" Text="Checking local API..." FontSize="12" FontWeight="SemiBold" Foreground="#526174"/>
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
          <TextBlock x:Name="GyroHint" Text="Gyro-S is bundled. If its local files are missing, Panda has no catalog download action for it."
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
                  AutomationProperties.Name="Stop Panda API and model backends"/>
          <Separator Margin="0,14,0,12" Background="#E2E7EF"/>
          <TextBlock Text="ACTION STATUS" FontSize="10" FontWeight="Bold" Foreground="#77849A" Margin="2,0,0,7"/>
          <TextBlock x:Name="ActionMessage" Text="Select a card to inspect it. Selection alone does not start or switch a model."
                     FontSize="11" Foreground="#5D6B80" TextWrapping="Wrap"/>
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
                  <TextBlock Text="Context and Game Mode are the supported Panda settings. Drafting, image-reading policy, and computer-use permissions remain controlled by the selected runtime or OpenCode."
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
                <StackPanel><TextBlock Text="Speed" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricSpeed" Text="Not reported" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock Text="Decode / prefill" FontSize="10" Foreground="#748196"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,8">
                <StackPanel><TextBlock Text="GPU load" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricGpu" Text="Not sampled" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock x:Name="MetricGpuName" Text="Hardware only" FontSize="10" Foreground="#748196"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,8">
                <StackPanel><TextBlock Text="VRAM" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricVram" Text="Not sampled" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock Text="Device total / used" FontSize="10" Foreground="#748196"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,0,8">
                <StackPanel><TextBlock Text="GPU temperature" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricTemperature" Text="Not sampled" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock Text="Read-only device telemetry" FontSize="10" Foreground="#748196"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,0">
                <StackPanel><TextBlock Text="Power" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricPower" Text="Not sampled" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock Text="GPU draw / limit" FontSize="10" Foreground="#748196"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,0">
                <StackPanel><TextBlock Text="PCIe" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricPcie" Text="Not reported" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock Text="No link telemetry adapter" FontSize="10" Foreground="#748196"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,0">
                <StackPanel><TextBlock Text="CPU / memory" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricCpuRam" Text="Not sampled" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock Text="Host-level only" FontSize="10" Foreground="#748196"/></StackPanel>
              </Border>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,0,0">
                <StackPanel><TextBlock Text="Disk I/O" FontSize="11" Foreground="#69768A"/><TextBlock x:Name="MetricDisk" Text="Not reported" FontSize="23" FontWeight="Bold" Foreground="#17243A" Margin="0,11,0,0"/><TextBlock Text="No process-level sampling" FontSize="10" Foreground="#748196"/></StackPanel>
              </Border>
            </UniformGrid>
            <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,0,12">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="Energy since start" FontSize="10" Foreground="#69768A"/><TextBlock Text="Not reported" FontSize="14" FontWeight="SemiBold" Foreground="#26344A" Margin="0,4,0,0"/></StackPanel>
                <StackPanel Grid.Column="1"><TextBlock Text="GPU fan" FontSize="10" Foreground="#69768A"/><TextBlock x:Name="MetricFan" Text="Not sampled" FontSize="14" FontWeight="SemiBold" Foreground="#26344A" Margin="0,4,0,0"/></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="GPU clock" FontSize="10" Foreground="#69768A"/><TextBlock x:Name="MetricClock" Text="Not sampled" FontSize="14" FontWeight="SemiBold" Foreground="#26344A" Margin="0,4,0,0"/></StackPanel>
              </Grid>
            </Border>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="0.75*"/><ColumnDefinition Width="1.5*"/></Grid.ColumnDefinitions>
              <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,0,8,0">
                <StackPanel>
                  <TextBlock Text="Context fill" FontSize="15" FontWeight="SemiBold" Foreground="#17243A"/>
                  <TextBlock x:Name="ContextFillValue" Text="Not reported" FontSize="23" FontWeight="Bold" Foreground="#26344A" HorizontalAlignment="Center" Margin="0,24,0,0"/>
                  <TextBlock Text="No token-usage feed is exposed by the current backend." FontSize="10" Foreground="#748196" TextWrapping="Wrap" HorizontalAlignment="Center" Margin="0,4,0,18"/>
                  <TextBlock Text="Context ceiling" FontSize="10" Foreground="#69768A"/>
                  <ProgressBar Height="7" Value="0" Maximum="100" Background="#EEF2F7" Margin="0,5,0,0"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="1" Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="8,0,0,0">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Recent requests" FontSize="15" FontWeight="SemiBold" Foreground="#17243A"/>
                    <TextBlock Grid.Column="1" Text="API request history unavailable" FontSize="10" Foreground="#748196" VerticalAlignment="Center"/>
                  </Grid>
                  <Border Background="#F7F9FC" CornerRadius="8" Padding="12" Margin="0,14,0,0">
                    <TextBlock Text="No request telemetry has been collected." FontSize="11" Foreground="#69768A"/>
                  </Border>
                </StackPanel>
              </Border>
            </Grid>
            <Border Background="#FFFFFF" BorderBrush="#E1E6ED" BorderThickness="1" CornerRadius="13" Padding="16" Margin="0,12,0,0">
              <StackPanel>
                <TextBlock Text="Conversation cache" FontSize="15" FontWeight="SemiBold" Foreground="#17243A"/>
                <TextBlock Text="Cache reuse details appear when the selected runtime reports them; Panda does not fabricate token or request measurements."
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
$script:LoadingSettings = $false

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
                $script:ContextHelp.Text = 'This runtime does not expose a context selector in Panda.'
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
        if ($fileNames.Count -eq 0) { $fileNames = @('Bundled Panda runtime') }
        $script:SettingsFiles.Text = $fileNames -join "`r`n"
        $script:SaveSettingsButton.IsEnabled = (-not $script:PreviewState) -and ($model.kind -in @('inkling','mini'))
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
        $script:MonitorStateHint.Text = 'Model state is unavailable until Panda status is refreshed.'
        return
    }
    if ($Status.backendRunning -and $Status.routeName) {
        $script:MonitorStateText.Text = 'Serving'
        $script:MonitorStateBadge.Background = [Windows.Media.Brushes]::Honeydew
        $script:MonitorStateHint.Text = ([string]$Status.routeName + ' is routed through the Panda API. This view does not change the running model.')
    } elseif ($Status.apiRunning -and -not $Status.apiConflict) {
        $script:MonitorStateText.Text = 'Idle'
        $script:MonitorStateBadge.Background = [Windows.Media.Brushes]::AliceBlue
        $script:MonitorStateHint.Text = 'Panda API is ready; no healthy model backend is currently routed.'
    } elseif ($Status.apiConflict) {
        $script:MonitorStateText.Text = 'Port conflict'
        $script:MonitorStateBadge.Background = [Windows.Media.Brushes]::Moccasin
        $script:MonitorStateHint.Text = 'Another workspace owns the API port. No stop or route action was taken.'
    } else {
        $script:MonitorStateText.Text = 'Offline'
        $script:MonitorStateBadge.Background = [Windows.Media.Brushes]::Lavender
        $script:MonitorStateHint.Text = 'Panda API is offline. Monitor is read-only until an explicit action is selected.'
    }
}

function Update-HardwareMetrics {
    if ($script:PreviewState) {
        $script:MonitorMessage.Text = 'Demo preview is read-only; no live hardware sensors were queried.'
        return
    }
    $script:HardwareRefreshButton.IsEnabled = $false
    $script:MonitorMessage.Text = 'Sampling local hardware sensors only; no model or Panda API is queried.'
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
        $script:SettingsSaveMessage.Text = 'This model has no editable next-start settings in Panda.'
    }
}

function Set-UiBusy([bool]$IsBusy) {
    $script:RefreshButton.IsEnabled = -not $IsBusy
    $script:SearchBox.IsEnabled = -not $IsBusy
    $script:FilterBox.IsEnabled = -not $IsBusy
    $script:ModelsList.IsEnabled = -not $IsBusy
    $script:SettingsModelBox.IsEnabled = -not $IsBusy
    $script:ContextBox.IsEnabled = (-not $IsBusy) -and ($script:SettingsModelBox.SelectedItem -and $script:SettingsModelBox.SelectedItem.kind -in @('inkling','mini'))
    $script:GameModeToggle.IsEnabled = (-not $IsBusy) -and ($script:SettingsModelBox.SelectedItem -and $script:SettingsModelBox.SelectedItem.kind -eq 'mini') -and (-not $script:PreviewState)
    $script:SaveSettingsButton.IsEnabled = (-not $IsBusy) -and (-not $script:PreviewState) -and ($script:SettingsModelBox.SelectedItem -and $script:SettingsModelBox.SelectedItem.kind -in @('inkling','mini'))
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
    $script:FilesValue.Text = if ($Model.Files.Count -gt 0) { $Model.Files -join "`r`n" } else { 'Bundled Panda runtime' }
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
                ('Install ' + $Model.Name + '? This may download model files. No progress percentage or ETA is available.'),
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
                $switchMessage = 'Starting ' + $Model.Name + ' will stop the currently serving backend and change the Panda API route. Continue?'
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
        try { return ($jsonLine[0] | ConvertFrom-Json) } catch {}
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
        'Initialize' { 'Starting the Panda API...' }
        'Status' { 'Refreshing model and service status...' }
        'Install' { 'Installing model. Controls are disabled while this runs; no percentage or ETA is available.' }
        'Start' { 'Starting model and updating the route...' }
        'Stop' { 'Stopping the API and backends...' }
        default { 'Updating Panda Engine...' }
    }
    Set-ActionMessage $busyMessage

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
        Set-UiBusy $false
        Set-ActionMessage ('Could not start the launcher action: ' + $_.Exception.Message)
    }
}

$script:ActionTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ActionTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:ActionTimer.Add_Tick({
    if (-not $script:PendingAction) {
        $script:ActionTimer.Stop()
        return
    }
    if (-not $script:PendingAction.Process.HasExited) {
        $elapsed = ([DateTime]::UtcNow - $script:PendingAction.StartedAt).TotalSeconds
        if ($elapsed -lt $script:PendingAction.TimeoutSeconds) { return }

        $timedOut = $script:PendingAction
        $script:ActionTimer.Stop()
        $script:PendingAction = $null
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
$script:HardwareRefreshButton.Add_Click({ Update-HardwareMetrics })
$script:ModelsList.Add_SelectionChanged({
    if ($script:ModelsList.SelectedItem) { Show-ModelDetails $script:ModelsList.SelectedItem }
})
$script:MainTabs.Add_SelectionChanged({
    $selectedTab = $script:MainTabs.SelectedItem
    if (-not $selectedTab) { return }
    $pageName = [string]$selectedTab.Header
    $script:CurrentPageLabel.Text = $pageName.ToUpperInvariant()
    [System.Windows.Automation.AutomationProperties]::SetName($script:PageBadge, ('Current page: ' + $pageName))
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
    $stopMessage = 'This stops the Panda API and all owned backends. Connected clients will lose service. If a Gyro-S ownership record exists, Panda will ask for separate authorization before attempting to stop it. Continue?'
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
    } elseif ($script:PreviewState -eq 'Demo') {
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
    } elseif ($SkipInitialize) { Start-ManagerAction 'Status' }
    else { Start-ManagerAction 'Initialize' }
})

$null = $script:Window.ShowDialog()

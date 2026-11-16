#Requires -Version 5.1
<#
    此刻 · 设备管理  (DeviceWidget)
    ------------------------------------------------------------
    卡片式设备面板：蓝牙设备 / 网络 / 音频，两列排布，点卡片进系统设置。

    · 点卡片        打开对应系统设置页
    · 拖动          移动位置（自动记住）
    · 滚轮          调整不透明度
    · 右键          刷新 / 主题 / 尺寸 / 透明度 / 置于底层 / 开机自启 / 退出
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

trap {
    $detail = "ERROR: " + $_.Exception.Message + "`r`n" + $_.InvocationInfo.PositionMessage + "`r`n" + $_.ScriptStackTrace
    try { [System.IO.File]::AppendAllText((Join-Path $PSScriptRoot 'device.log'), $detail + "`r`n", [System.Text.Encoding]::UTF8) } catch { }
    Write-Host $detail
    break
}

$script:Dir          = $PSScriptRoot
$script:SettingsPath = Join-Path $script:Dir 'device-settings.json'
$script:LogPath      = Join-Path $script:Dir 'device.log'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

function Write-Log([string]$Message) {
    try {
        Add-Content -LiteralPath $script:LogPath -Value (('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)) -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- 单实例
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\DSH.DeviceWidget')
try {
    if (-not $script:Mutex.WaitOne(0)) { return }
} catch [System.Threading.AbandonedMutexException] { } catch { }

# ---------------------------------------------------------------- 设置
$script:Config = [ordered]@{
    left    = $null
    top     = $null
    theme   = 'glass'
    scale   = 1.0
    opacity = 1.0
    desktop = $false
}

if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
        $saved = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @($script:Config.Keys)) {
            $prop = $saved.PSObject.Properties[$key]
            if ($null -ne $prop -and $null -ne $prop.Value) { $script:Config[$key] = $prop.Value }
        }
    } catch { Write-Log "读取设置失败: $_" }
}

# ---------------------------------------------------------------- 界面
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="DeviceWindow"
        Title="此刻 · 设备管理"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="{x:Null}"
        Topmost="True"
        ShowInTaskbar="False"
        ShowActivated="False"
        ResizeMode="NoResize"
        SizeToContent="WidthAndHeight"
        WindowStartupLocation="Manual"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True">
    <Grid x:Name="RootGrid" Margin="40">
        <Border x:Name="Card" CornerRadius="26" Background="#00000000" BorderBrush="#00000000" BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect BlurRadius="34" ShadowDepth="10" Direction="270" Opacity="0" Color="#000000"/>
            </Border.Effect>
        </Border>
        <StackPanel x:Name="Content" Margin="22,16,22,18" MinWidth="470">
            <Grid Margin="4,0,4,10">
                <TextBlock x:Name="HeaderText" Text="我的设备"
                           FontFamily="Microsoft YaHei UI" FontSize="17" FontWeight="Medium"
                           Foreground="#F2EFE6D8" VerticalAlignment="Center"/>
                <TextBlock x:Name="MoreText" Text="全部  ›" Cursor="Hand"
                           FontFamily="Microsoft YaHei UI" FontSize="11.5"
                           Foreground="#A6D9CFC0" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <UniformGrid x:Name="Cards" Columns="2"/>
            <TextBlock x:Name="EmptyText" Text="没有检测到设备"
                       FontFamily="Microsoft YaHei UI" FontSize="12.5"
                       Foreground="#80EFE6D8" Margin="6,10,6,6" Visibility="Collapsed"/>
        </StackPanel>
    </Grid>
</Window>
'@

try {
    $xmlReader = New-Object System.Xml.XmlTextReader (New-Object System.IO.StringReader $script:Xaml)
    $Root = [Windows.Markup.XamlReader]::Load($xmlReader)
} catch {
    Write-Log "XAML 加载失败: $_"
    [Windows.MessageBox]::Show("界面加载失败：`n$_", '此刻 · 设备管理', 'OK', 'Error') | Out-Null
    exit 1
}

$RootGrid   = $Root.FindName('RootGrid')
$Card       = $Root.FindName('Card')
$CardShadow = $Card.Effect
$HeaderText = $Root.FindName('HeaderText')
$MoreText   = $Root.FindName('MoreText')
$Cards      = $Root.FindName('Cards')
$EmptyText  = $Root.FindName('EmptyText')

# ---------------------------------------------------------------- 配色
$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$Hex) {
    return [Windows.Media.SolidColorBrush]$script:BrushConverter.ConvertFromString($Hex)
}

$script:Themes = [ordered]@{
    dark = @{
        Label = '深色玻璃'; Card = '#E6101319'; Border = '#26FFFFFF'; BorderHover = '#4DFFFFFF'
        Title = '#F2FFFFFF'; Muted = '#8CFFFFFF'; Tile = '#14FFFFFF'; TileBorder = '#1FFFFFFF'
        Badge = '#22FFFFFF'; Accent = '#FF59C2FF'; Shadow = 0.55; TextShadow = $false
    }
    light = @{
        Label = '浅色玻璃'; Card = '#F2FFFFFF'; Border = '#1F000000'; BorderHover = '#42000000'
        Title = '#F20B1220'; Muted = '#8C0B1220'; Tile = '#0A000000'; TileBorder = '#14000000'
        Badge = '#14000000'; Accent = '#FF0A84FF'; Shadow = 0.16; TextShadow = $false
    }
    glass = @{
        Label = '透明'; Card = '#00000000'; Border = '#00000000'; BorderHover = '#00000000'
        Title = '#F2EFE6D8'; Muted = '#A6D9CFC0'; Tile = '#12FFFFFF'; TileBorder = '#1FFFFFFF'
        Badge = '#1FFFFFFF'; Accent = '#FFF2C87E'; Shadow = 0.0; TextShadow = $true
    }
}

$script:TextShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$script:TextShadow.BlurRadius  = 14
$script:TextShadow.ShadowDepth = 0
$script:TextShadow.Opacity     = 0.7
$script:TextShadow.Color       = [Windows.Media.Colors]::Black

function Apply-Theme([string]$Name) {
    if (-not $script:Themes.Contains($Name)) { $Name = 'glass' }
    $t = $script:Themes[$Name]
    $script:Config.theme = $Name

    $Card.Background = Get-Brush $t.Card
    $Card.BorderBrush = Get-Brush $t.Border
    $Card.BorderThickness = New-Object System.Windows.Thickness(1)
    $CardShadow.Opacity = [double]$t.Shadow

    $HeaderText.Foreground = Get-Brush $t.Title
    $MoreText.Foreground   = Get-Brush $t.Muted
    $EmptyText.Foreground  = Get-Brush $t.Muted

    foreach ($tb in @($HeaderText, $MoreText, $EmptyText)) {
        $tb.Effect = if ($t.TextShadow) { $script:TextShadow } else { $null }
    }

    Render-Devices
}


function Apply-Scale([double]$Scale) {
    if ($Scale -lt 0.6 -or $Scale -gt 2.0) { $Scale = 1.0 }
    $script:Config.scale = $Scale
    $RootGrid.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($Scale, $Scale)
}

function Save-Settings {
    try {
        if ($null -ne $Root -and -not [double]::IsNaN($Root.Left)) {
            $script:Config.left = [double]$Root.Left
            $script:Config.top  = [double]$Root.Top
        }
        $json = $script:Config | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log "保存设置失败: $_" }
}

function Restore-Position {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $w  = if ($Root.ActualWidth  -gt 0) { $Root.ActualWidth }  else { 480 }
    $h  = if ($Root.ActualHeight -gt 0) { $Root.ActualHeight } else { 320 }

    $valid = $false
    if ($null -ne $script:Config.left -and $null -ne $script:Config.top) {
        $l = [double]$script:Config.left
        $t = [double]$script:Config.top
        if ($l -gt ($wa.Left - 60) -and $l -lt ($wa.Right - 90) -and
            $t -gt ($wa.Top - 60) -and $t -lt ($wa.Bottom - 70)) { $valid = $true }
    }
    if (-not $valid) {
        $l = $wa.Right - $w - 80
        $t = $wa.Top + 160
    }
    $Root.Left = [double]$l
    $Root.Top  = [double]$t
}

# ---------------------------------------------------------------- 设备枚举
function Get-DeviceList {
    $list = New-Object System.Collections.ArrayList
    $seen = @{}

    function Get-DeviceBattery([string]$instanceId) {
        if ([string]::IsNullOrWhiteSpace($instanceId)) { return $null }
        foreach ($k in @('{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2')) {
            try {
                $p = Get-PnpDeviceProperty -InstanceId $instanceId -KeyName $k -ErrorAction Stop
                $v = $p.Data
                if ($null -ne $v -and "$v" -match '^\d+$') {
                    $num = [int]$v
                    if ($num -ge 0 -and $num -le 100) { return $num }
                }
            } catch { }
        }
        return $null
    }

    function Add-Device([string]$name, [string]$status, [string]$badge, [string]$uri, [string]$instanceId) {
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $n = $name.Trim()
        if ($seen.ContainsKey($n)) { return }
        $seen[$n] = $true

        $bat = Get-DeviceBattery $instanceId
        if ($null -ne $bat) { $status = '已连接 · 电量 {0}%' -f $bat }
        [void]$list.Add(@{ Name = $n; Status = $status; Badge = $badge; Uri = $uri; Battery = $bat })
    }

    try {
        Get-PnpDevice -PresentOnly -Class Keyboard -ErrorAction Stop | ForEach-Object {
            Add-Device ([string]$_.FriendlyName) '已连接 · 键盘' '键' 'ms-settings:devices' ([string]$_.InstanceId)
        }
    } catch { Write-Log "枚举键盘失败: $_" }

    try {
        Get-PnpDevice -PresentOnly -Class Mouse -ErrorAction Stop | ForEach-Object {
            Add-Device ([string]$_.FriendlyName) '已连接 · 鼠标' '鼠' 'ms-settings:devices' ([string]$_.InstanceId)
        }
    } catch { Write-Log "枚举鼠标失败: $_" }

    try {
        Get-PnpDevice -PresentOnly -Class AudioEndpoint -ErrorAction Stop |
            Where-Object { $_.FriendlyName -match '耳机|Headphone|Headset|扬声器|Speaker' } |
            ForEach-Object {
                Add-Device ([string]$_.FriendlyName) '已连接 · 音频' '音' 'ms-settings:sound' ([string]$_.InstanceId)
            }
    } catch { Write-Log "枚举音频失败: $_" }

    # 过滤掉明显的虚拟/总线占位设备
    $filtered = New-Object System.Collections.ArrayList
    foreach ($d in $list) {
        if ($d.Name -match '虚拟|Virtual|Root|Enumerator|Microsoft') { continue }
        if ($d.Name -match 'PS/2|Hands-Free|Hands-F|标准键盘') { continue }
        [void]$filtered.Add($d)
        if ($filtered.Count -ge 4) { break }
    }
    return $filtered
}

$script:DeviceSignature = ''

function Render-Devices([bool]$force = $false) {
    $list = Get-DeviceList
    $sig = (($list | ForEach-Object { $_.Name + '|' + $_.Status }) -join ';')
    if (-not $force -and $sig -eq $script:DeviceSignature) { return }
    $script:DeviceSignature = $sig
    $script:Devices = $list

    $Cards.Children.Clear()
    $EmptyText.Visibility = if ($list.Count -eq 0) { 'Visible' } else { 'Collapsed' }

    $t = $script:Themes[$script:Config.theme]
    foreach ($dev in $list) {
        $tile = New-Object System.Windows.Controls.Border
        $tile.Width            = 205
        $tile.Height           = 108
        $tile.Margin           = New-Object System.Windows.Thickness(4)
        $tile.CornerRadius     = New-Object System.Windows.CornerRadius(16)
        $tile.Background       = Get-Brush $t.Tile
        $tile.BorderBrush      = Get-Brush $t.TileBorder
        $tile.BorderThickness  = New-Object System.Windows.Thickness(1)
        $tile.Cursor           = [System.Windows.Input.Cursors]::Hand
        $tile.Tag              = $dev.Uri

        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = New-Object System.Windows.Thickness(12, 10, 12, 10)

        $nameTb = New-Object System.Windows.Controls.TextBlock
        $nameTb.Text = $dev.Name
        $nameTb.FontFamily = 'Microsoft YaHei UI'
        $nameTb.FontSize = 13
        $nameTb.Foreground = Get-Brush $t.Title
        $nameTb.TextTrimming = 'CharacterEllipsis'
        $nameTb.VerticalAlignment = 'Top'
        $nameTb.Margin = New-Object System.Windows.Thickness(0, 0, 0, 0)

        $statusTb = New-Object System.Windows.Controls.TextBlock
        $statusTb.Text = $dev.Status
        $statusTb.FontFamily = 'Microsoft YaHei UI'
        $statusTb.FontSize = 10.5
        $statusTb.Foreground = Get-Brush $t.Muted
        $statusTb.TextTrimming = 'CharacterEllipsis'
        $statusTb.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)

        $textStack = New-Object System.Windows.Controls.StackPanel
        $textStack.VerticalAlignment = 'Top'
        [void]$textStack.Children.Add($nameTb)
        [void]$textStack.Children.Add($statusTb)

        $badge = New-Object System.Windows.Controls.Border
        $badge.Width = 34
        $badge.Height = 34
        $badge.CornerRadius = New-Object System.Windows.CornerRadius(17)
        $badge.Background = Get-Brush $t.Badge
        $badge.HorizontalAlignment = 'Left'
        $badge.VerticalAlignment = 'Bottom'

        $badgeTb = New-Object System.Windows.Controls.TextBlock
        $badgeTb.Text = $dev.Badge
        $badgeTb.FontFamily = 'Microsoft YaHei UI'
        $badgeTb.FontSize = 12
        $badgeTb.Foreground = Get-Brush $t.Title
        $badgeTb.HorizontalAlignment = 'Center'
        $badgeTb.VerticalAlignment = 'Center'
        $badge.Child = $badgeTb

        $arrow = New-Object System.Windows.Controls.Border
        $arrow.Width = 34
        $arrow.Height = 34
        $arrow.CornerRadius = New-Object System.Windows.CornerRadius(17)
        $arrow.Background = Get-Brush $t.Badge
        $arrow.HorizontalAlignment = 'Right'
        $arrow.VerticalAlignment = 'Bottom'

        $arrowTb = New-Object System.Windows.Controls.TextBlock
        $arrowTb.Text = '›'
        $arrowTb.FontFamily = 'Segoe UI Symbol'
        $arrowTb.FontSize = 16
        $arrowTb.Foreground = Get-Brush $t.Title
        $arrowTb.HorizontalAlignment = 'Center'
        $arrowTb.VerticalAlignment = 'Center'
        $arrow.Child = $arrowTb

        [void]$grid.Children.Add($textStack)
        [void]$grid.Children.Add($badge)
        [void]$grid.Children.Add($arrow)
        $tile.Child = $grid

        $tile.Add_MouseEnter({
            param($s, $e)
            $s.Background = Get-Brush $script:Themes[$script:Config.theme].BorderHover
        })
        $tile.Add_MouseLeave({
            param($s, $e)
            $s.Background = Get-Brush $script:Themes[$script:Config.theme].Tile
        })
        $tile.Add_MouseLeftButtonUp({
            param($s, $e)
            $e.Handled = $true
            try { Start-Process ([string]$s.Tag) } catch { Write-Log "打开设置失败: $_" }
        })

        [void]$Cards.Children.Add($tile)
    }
}

# ---------------------------------------------------------------- 开机自启
$script:StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '此刻设备管理.lnk'

function Test-Autostart { return (Test-Path -LiteralPath $script:StartupLnk) }

function Set-Autostart([bool]$Enable) {
    try {
        if ($Enable) {
            $shell = New-Object -ComObject WScript.Shell
            $lnk = $shell.CreateShortcut($script:StartupLnk)
            $lnk.TargetPath       = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
            $lnk.Arguments        = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $script:Dir 'DeviceWidget.ps1') + '"'
            $lnk.WorkingDirectory = $script:Dir
            $lnk.WindowStyle      = 7
            $lnk.Description      = '此刻 · 设备管理'
            $icon = Join-Path $script:Dir 'device.ico'
            if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = $icon + ',0' }
            $lnk.Save()
        } elseif (Test-Path -LiteralPath $script:StartupLnk) {
            Remove-Item -LiteralPath $script:StartupLnk -Force
        }
        return $true
    } catch {
        Write-Log "设置开机自启失败: $_"
        return $false
    }
}

# ---------------------------------------------------------------- 菜单
$script:MenuShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$script:MenuShadow.BlurRadius  = 30
$script:MenuShadow.ShadowDepth = 10
$script:MenuShadow.Opacity     = 0.55
$script:MenuShadow.Color       = [Windows.Media.Colors]::Black

$script:MenuBorder = New-Object System.Windows.Controls.Border
$script:MenuBorder.Background      = Get-Brush '#F5161B24'
$script:MenuBorder.BorderBrush     = Get-Brush '#2EFFFFFF'
$script:MenuBorder.BorderThickness = New-Object System.Windows.Thickness(1)
$script:MenuBorder.CornerRadius    = New-Object System.Windows.CornerRadius(12)
$script:MenuBorder.Padding         = New-Object System.Windows.Thickness(6)
$script:MenuBorder.MinWidth        = 286
$script:MenuBorder.Effect          = $script:MenuShadow
$script:MenuBorder.Focusable       = $true

$script:MenuPanel = New-Object System.Windows.Controls.StackPanel
$script:MenuBorder.Child = $script:MenuPanel

$script:MenuHost = New-Object System.Windows.Controls.Grid
$script:MenuHost.Margin = New-Object System.Windows.Thickness(18)
[void]$script:MenuHost.Children.Add($script:MenuBorder)

$script:MenuWindow = New-Object System.Windows.Window
$script:MenuWindow.WindowStyle           = 'None'
$script:MenuWindow.AllowsTransparency    = $true
$script:MenuWindow.Background            = [Windows.Media.Brushes]::Transparent
$script:MenuWindow.ShowInTaskbar         = $false
$script:MenuWindow.ShowActivated         = $true
$script:MenuWindow.Topmost               = $true
$script:MenuWindow.ResizeMode            = 'NoResize'
$script:MenuWindow.SizeToContent         = 'WidthAndHeight'
$script:MenuWindow.WindowStartupLocation = 'Manual'
$script:MenuWindow.Content               = $script:MenuHost
$script:MenuWindow.Add_Deactivated({ try { $script:MenuWindow.Hide() } catch { } })

function Hide-Menu { try { if ($script:MenuWindow.IsVisible) { $script:MenuWindow.Hide() } } catch { } }

$script:MenuTextBrush   = Get-Brush '#F2F6EFE3'
$script:MenuMutedBrush  = Get-Brush '#80EFE6D8'
$script:MenuAccentBrush = Get-Brush '#FFF2C87E'
$script:MenuHoverBrush  = Get-Brush '#1FFFFFFF'

function Add-MenuRow([string]$Text, [scriptblock]$OnClick, [bool]$Checked = $false) {
    $prefix = if ($Checked) { '✓  ' } else { '     ' }
    $row = New-Object System.Windows.Controls.Border
    $row.CornerRadius = New-Object System.Windows.CornerRadius(7)
    $row.Padding      = New-Object System.Windows.Thickness(9, 7, 12, 7)
    $row.Background   = [Windows.Media.Brushes]::Transparent
    $row.Cursor       = [System.Windows.Input.Cursors]::Hand
    $row.Tag          = $OnClick

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text       = $prefix + $Text
    $tb.FontFamily = 'Microsoft YaHei UI'
    $tb.FontSize   = 12.5
    $tb.Foreground = $script:MenuTextBrush
    $row.Child     = $tb

    $row.Add_MouseEnter({ param($s, $e) $s.Background = $script:MenuHoverBrush })
    $row.Add_MouseLeave({ param($s, $e) $s.Background = [Windows.Media.Brushes]::Transparent })
    $row.Add_MouseLeftButtonUp({ param($s, $e) & $s.Tag; Hide-Menu })
    [void]$script:MenuPanel.Children.Add($row)
}

function Add-MenuSeparator {
    $line = New-Object System.Windows.Controls.Border
    $line.Height     = 1
    $line.Margin     = New-Object System.Windows.Thickness(9, 5, 9, 5)
    $line.Background = Get-Brush '#26FFFFFF'
    [void]$script:MenuPanel.Children.Add($line)
}

function Add-MenuSegments([string]$Label, $Options, [scriptblock]$OnPick) {
    $wrap = New-Object System.Windows.Controls.StackPanel
    $wrap.Margin = New-Object System.Windows.Thickness(9, 6, 9, 8)

    $lab = New-Object System.Windows.Controls.TextBlock
    $lab.Text       = $Label
    $lab.FontFamily = 'Microsoft YaHei UI'
    $lab.FontSize   = 10.5
    $lab.Foreground = $script:MenuMutedBrush
    $lab.Margin     = New-Object System.Windows.Thickness(0, 0, 0, 6)
    [void]$wrap.Children.Add($lab)

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'

    foreach ($opt in $Options) {
        $chip = New-Object System.Windows.Controls.Border
        $chip.CornerRadius = New-Object System.Windows.CornerRadius(5)
        $chip.Padding      = New-Object System.Windows.Thickness(8, 3, 8, 3)
        $chip.Margin       = New-Object System.Windows.Thickness(0, 0, 6, 0)
        $chip.Cursor       = [System.Windows.Input.Cursors]::Hand
        $chip.Tag          = @{ Action = $OnPick; Value = $opt.Value }

        if ($opt.Active) { $chip.Background = Get-Brush '#33F2C87E' } else { $chip.Background = Get-Brush '#12FFFFFF' }

        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text       = $opt.Label
        $tb.FontFamily = 'Microsoft YaHei UI'
        $tb.FontSize   = 11.5
        $tb.Foreground = if ($opt.Active) { $script:MenuAccentBrush } else { $script:MenuMutedBrush }
        $chip.Child = $tb

        if (-not $opt.Active) {
            $chip.Add_MouseEnter({ param($s, $e) $s.Background = $script:MenuHoverBrush })
            $chip.Add_MouseLeave({ param($s, $e) $s.Background = Get-Brush '#12FFFFFF' })
        }
        $chip.Add_MouseLeftButtonUp({ param($s, $e) $a = $s.Tag; & $a.Action $a.Value; Hide-Menu })
        [void]$row.Children.Add($chip)
    }

    [void]$wrap.Children.Add($row)
    [void]$script:MenuPanel.Children.Add($wrap)
}

function Build-ThemeOptions {
    $opts = @()
    foreach ($key in @('dark', 'light', 'glass')) {
        $opts += @{ Label = $script:Themes[$key].Label; Value = $key; Active = ($key -eq $script:Config.theme) }
    }
    return $opts
}

function Build-ScaleOptions {
    $current = [double]$script:Config.scale
    $opts = @()
    foreach ($pair in @(@('0.85', '小'), @('1.0', '标准'), @('1.15', '大'), @('1.35', '特大'))) {
        $val = [double]$pair[0]
        $opts += @{ Label = $pair[1]; Value = $val; Active = ([math]::Abs($val - $current) -lt 0.001) }
    }
    return $opts
}

function Build-OpacityOptions {
    $current = [double]$script:Config.opacity
    $opts = @()
    foreach ($v in @(1.0, 0.85, 0.7, 0.55)) {
        $opts += @{ Label = ('{0}%' -f [int]($v * 100)); Value = $v; Active = ([math]::Abs($v - $current) -lt 0.001) }
    }
    return $opts
}

function Show-Menu {
    $script:MenuPanel.Children.Clear()

    Add-MenuRow '立即刷新' { Render-Devices $true }
    Add-MenuRow '蓝牙设置' { Start-Process 'ms-settings:bluetooth' }
    Add-MenuRow '网络设置' { Start-Process 'ms-settings:network-status' }

    Add-MenuSeparator
    Add-MenuSegments '外观主题' (Build-ThemeOptions) { param($v) Apply-Theme ([string]$v); Save-Settings }
    Add-MenuSegments '显示尺寸' (Build-ScaleOptions) { param($v) Apply-Scale ([double]$v); Save-Settings }
    Add-MenuSegments '不透明度' (Build-OpacityOptions) {
        param($v)
        $script:Config.opacity = [double]$v
        $Root.Opacity = [double]$v
        Save-Settings
    }
    Add-MenuSeparator

    Add-MenuRow '置于底层' {
        Set-DesktopMode (-not [bool]$script:Config.desktop)
        Save-Settings
    } ([bool]$script:Config.desktop)

    Add-MenuRow '开机自动启动' {
        $want = -not (Test-Autostart)
        if (-not (Set-Autostart $want)) {
            [Windows.MessageBox]::Show('无法写入开机启动项。可以把「此刻设备管理.lnk」的副本放进启动文件夹（Win+R 输入 shell:startup）。',
                '此刻 · 设备管理', 'OK', 'Warning') | Out-Null
        }
    } (Test-Autostart)

    Add-MenuRow '回到默认位置' {
        $script:Config.left = $null
        $script:Config.top  = $null
        Restore-Position
        Save-Settings
    }

    Add-MenuSeparator
    Add-MenuRow '退出' { $Root.Close() }

    $pos = [System.Windows.Input.Mouse]::GetPosition($Root)
    $script:MenuWindow.Left = $Root.Left + $pos.X
    $script:MenuWindow.Top  = $Root.Top + $pos.Y
    $script:MenuWindow.Show()
    $script:MenuWindow.Activate()
    $script:MenuBorder.Focus() | Out-Null

    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($script:MenuWindow.Left + $script:MenuWindow.ActualWidth - 36 -gt $wa.Right) {
        $script:MenuWindow.Left = $wa.Right - $script:MenuWindow.ActualWidth
    }
    if ($script:MenuWindow.Top + $script:MenuWindow.ActualHeight - 36 -gt $wa.Bottom) {
        $script:MenuWindow.Top = $wa.Bottom - $script:MenuWindow.ActualHeight
    }
}

$script:MenuBorder.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') { Hide-Menu; $e.Handled = $true }
})

# ---------------------------------------------------------------- 桌面层
function Send-ToBottom {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($Root)).Handle
        if ($h -ne [IntPtr]::Zero) {
            [void][DeviceNative.Win32]::SetWindowPos($h, [IntPtr](1), 0, 0, 0, 0, 0x0013)
        }
    } catch { }
}

function Set-DesktopMode([bool]$On) {
    $script:Config.desktop = $On
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($Root)).Handle
        if ($h -ne [IntPtr]::Zero) {
            $ex = [DeviceNative.Win32]::GetWindowLong($h, -20)
            if ($On) { $ex = $ex -bor 0x08000000; $Root.Topmost = $false }
            else { $ex = $ex -band (-bnot 0x08000000); $Root.Topmost = $true }
            [void][DeviceNative.Win32]::SetWindowLong($h, -20, $ex)
        }
    } catch { }
    if ($On) { Send-ToBottom }
}

Add-Type -Namespace DeviceNative -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
'@

# ---------------------------------------------------------------- 交互
$Root.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($e.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
    try {
        $Root.DragMove()
        if ([bool]$script:Config.desktop) { Send-ToBottom }
        Save-Settings
    } catch { }
})

$Root.Add_MouseRightButtonUp({ param($sender, $e) Show-Menu; $e.Handled = $true })

$Root.Add_MouseWheel({
    param($sender, $e)
    $step = if ($e.Delta -gt 0) { 0.05 } else { -0.05 }
    $val  = [Math]::Round([Math]::Min(1.0, [Math]::Max(0.3, $Root.Opacity + $step)), 2)
    $Root.Opacity = $val
    $script:Config.opacity = $val
    Save-Settings
    $e.Handled = $true
})

$Root.Add_MouseEnter({ $Card.BorderBrush = Get-Brush $script:Themes[$script:Config.theme].BorderHover })
$Root.Add_MouseLeave({ $Card.BorderBrush = Get-Brush $script:Themes[$script:Config.theme].Border })

$Root.Add_Deactivated({ if ([bool]$script:Config.desktop) { Send-ToBottom } })

$MoreText.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Start-Process 'ms-settings:bluetooth' })

$Root.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($Root)
        $style  = [DeviceNative.Win32]::GetWindowLong($helper.Handle, -20)
        [void][DeviceNative.Win32]::SetWindowLong($helper.Handle, -20, ($style -bor 0x00000080))
        if ([bool]$script:Config.desktop) { Set-DesktopMode $true }
    } catch { Write-Log "设置窗口样式失败: $_" }
})

# ---------------------------------------------------------------- 启动
Apply-Theme $script:Config.theme
Apply-Scale ([double]$script:Config.scale)
$Root.Opacity = [double]$script:Config.opacity
$Root.Topmost = -not [bool]$script:Config.desktop
Render-Devices $true

$RootGrid.Opacity = 0.0

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromSeconds(6)
$script:Timer.Add_Tick({ try { Render-Devices } catch { Write-Log "刷新失败: $_" } })
$script:Timer.Start()

$Root.Add_Loaded({
    Restore-Position

    if (-not [bool]$script:Config.desktop) {
        try {
            $helper = New-Object System.Windows.Interop.WindowInteropHelper($Root)
            [void][DeviceNative.Win32]::SetWindowPos($helper.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
        } catch { }
    }

    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.From     = 0.0
    $fade.To       = 1.0
    $fade.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds(260)
    $RootGrid.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
})

$Root.Add_Closing({
    $script:Timer.Stop()
    Save-Settings
    try { $script:Mutex.ReleaseMutex() } catch { }
})

try {
    $script:App = New-Object System.Windows.Application
    $script:App.ShutdownMode = 'OnMainWindowClose'
    [void]$script:App.Run($Root)
} catch {
    Write-Log "运行失败: $_"
    [Windows.MessageBox]::Show("运行失败：`n$_", '此刻 · 设备管理', 'OK', 'Error') | Out-Null
} finally {
    try { $script:Mutex.ReleaseMutex() } catch { }
}

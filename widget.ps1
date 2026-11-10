param([int]$Port = 3456)

# 右下角常駐小工具：Codex／Claude 額度 + CPU／GPU／RAM
$Mutex = New-Object Threading.Mutex($false, 'Local\AIUsageWidget')
# 已在執行：通知它回到右下角並跳到最前面，自己結束
$ShowSignal = New-Object Threading.EventWaitHandle($false, 'AutoReset', 'Local\AIUsageWidgetShow')
if (-not $Mutex.WaitOne(0)) { [void]$ShowSignal.Set(); exit 0 }

Add-Type -AssemblyName PresentationFramework

$AccessKey = ''
$EnvFile = Join-Path $PSScriptRoot '.env'
if (Test-Path -LiteralPath $EnvFile) {
  $Line = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match '^\s*ACCESS_KEY\s*=' } | Select-Object -First 1
  if ($Line) { $AccessKey = ($Line -split '=', 2)[1].Trim().Trim('"') }
}

# ponytail: WMI 查詢要數百毫秒到數秒，全部丟背景 runspace，UI 執行緒只讀共享表
$State = [hashtable]::Synchronized(@{ cpu = $null; gpu = $null; ram = $null; usage = $null; offline = $false })
$Runspace = [runspacefactory]::CreateRunspace()
$Runspace.Open()
$Runspace.SessionStateProxy.SetVariable('State', $State)
$Sampler = [powershell]::Create()
$Sampler.Runspace = $Runspace
[void]$Sampler.AddScript({
  param($Port, $AccessKey)
  # 工作管理員（Win10 以後）用的是 % Processor Utility（含睿頻換算），不是 % Processor Time
  try { $Cpu = New-Object Diagnostics.PerformanceCounter 'Processor Information', '% Processor Utility', '_Total'; [void]$Cpu.NextValue() }
  catch { try { $Cpu = New-Object Diagnostics.PerformanceCounter 'Processor', '% Processor Time', '_Total'; [void]$Cpu.NextValue() } catch { $Cpu = $null } }
  $Smi = @("$env:WINDIR\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  # ponytail: 非 NVIDIA 時顯存總量取登錄檔最大 qwMemorySize；多張獨顯會不準，需要時再依 LUID 對應
  $DedicatedTotal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.'HardwareInformation.qwMemorySize' } | Measure-Object -Maximum).Maximum
  $SharedTotal = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 2  # Windows 共用 GPU 記憶體上限 = RAM 一半
  $NextUsage = [datetime]::MinValue
  $Tick = [Diagnostics.Stopwatch]::new()
  while ($true) {
    $Tick.Restart()
    # 額度放最前面：啟動時先顯示；伺服器還沒好就 5 秒後重試
    if ((Get-Date) -ge $NextUsage) {
      try {
        $Client = New-Object Net.WebClient
        $Client.Encoding = [Text.Encoding]::UTF8
        if ($AccessKey) { $Client.Headers.Add('x-access-key', $AccessKey) }
        $State.usage = $Client.DownloadString("http://localhost:$Port/api/usage") | ConvertFrom-Json
        try { $State.update = $Client.DownloadString("http://localhost:$Port/api/update") | ConvertFrom-Json } catch {}
        $State.offline = $false
        $NextUsage = (Get-Date).AddSeconds(60)
      } catch { $State.offline = $true; $NextUsage = (Get-Date).AddSeconds(5) }
    }
    try {
      $State.cpu = if ($Cpu) { [math]::Min(100, [math]::Round($Cpu.NextValue())) } else { (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime }
    } catch {}
    try {
      $Os = Get-CimInstance Win32_OperatingSystem
      $State.ram = [math]::Round(100 - 100 * $Os.FreePhysicalMemory / $Os.TotalVisibleMemorySize)
    } catch {}
    try {
      # 與工作管理員相同：各引擎類型加總後取最大值
      $State.gpu = [math]::Min(100, [math]::Round((
        Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Property Name, UtilizationPercentage |
          Group-Object { ($_.Name -split '_engtype_')[1] } |
          ForEach-Object { ($_.Group | Measure-Object UtilizationPercentage -Sum).Sum } |
          Measure-Object -Maximum).Maximum))
    } catch {}
    if ($Smi) {
      try {
        $Parts = (& $Smi --query-gpu=temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits | Select-Object -First 1) -split ',\s*'
        $State.gpuTemp = [int]$Parts[0]
        $State.vramUsed = [double]$Parts[1] * 1MB
        $State.vramTotal = [double]$Parts[2] * 1MB
      } catch { $Smi = $null; $State.gpuTemp = $null }
    } else {
      try {
        $Adapter = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -Property DedicatedUsage, SharedUsage |
          Sort-Object { [double]$_.DedicatedUsage + $_.SharedUsage } -Descending | Select-Object -First 1
        if ($Adapter.DedicatedUsage -gt 0 -and $DedicatedTotal) {
          $State.vramUsed = [double]$Adapter.DedicatedUsage; $State.vramTotal = [double]$DedicatedTotal; $State.vramShared = $false
        } else {
          $State.vramUsed = [double]$Adapter.SharedUsage; $State.vramTotal = [double]$SharedTotal; $State.vramShared = $true
        }
      } catch {}
    }
    Start-Sleep -Milliseconds ([math]::Max(50, 1000 - $Tick.ElapsedMilliseconds))
  }
}).AddArgument($Port).AddArgument($AccessKey)
[void]$Sampler.BeginInvoke()

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Width="284" SizeToContent="Height" FontFamily="Microsoft JhengHei UI" FontSize="12">
  <Border CornerRadius="10" Background="#E6161A20" BorderBrush="#33FFFFFF" BorderThickness="1">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Name="HandleCol" Width="16"/>
        <ColumnDefinition/>
      </Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition/>
        <RowDefinition Name="HandleRow" Height="0"/>
      </Grid.RowDefinitions>
      <Border Name="Handle" Background="#1AFFFFFF" CornerRadius="9,0,0,9" Cursor="Hand">
        <StackPanel Name="HandleBody" VerticalAlignment="Center" HorizontalAlignment="Center">
          <TextBlock Name="Arrow" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="#AAFFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          <StackPanel Name="Dots" Margin="0,6,0,0" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>
      <StackPanel Name="Body" Grid.Column="1" Margin="10,10,12,10">
        <Grid Margin="0,0,0,6">
          <TextBlock Name="TitleText" Text="AI 額度 · 效能" Foreground="#99FFFFFF" FontSize="11"/>
          <TextBlock Name="Status" HorizontalAlignment="Right" Foreground="#99FFFFFF" FontSize="11" TextTrimming="CharacterEllipsis"/>
        </Grid>
        <WrapPanel Name="Rows"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@
$Window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $Xaml))
foreach ($Name in 'Rows', 'Status', 'TitleText', 'Handle', 'HandleBody', 'Arrow', 'Dots', 'Body', 'HandleCol', 'HandleRow') {
  Set-Variable -Name $Name -Value $Window.FindName($Name)
}
$Converter = New-Object Windows.Media.BrushConverter
$Invariant = [Globalization.CultureInfo]::InvariantCulture

# 樣式：bar 條狀、gauge 指針、text 純數字；位置：side 右側、top 頂部。都存在資料夾內，下次沿用
$StyleFile = Join-Path $PSScriptRoot '.widget-style'
$Style = 'bar'
try { $Saved = (Get-Content -LiteralPath $StyleFile -Raw -ErrorAction Stop).Trim(); if ($Saved -in 'bar', 'gauge', 'text') { $Style = $Saved } } catch {}
$EdgeFile = Join-Path $PSScriptRoot '.widget-edge'
$Edge = 'side'
try { if ((Get-Content -LiteralPath $EdgeFile -Raw -ErrorAction Stop).Trim() -eq 'top') { $Edge = 'top' } } catch {}

# 每個項目固定寬度，內容區是 WrapPanel：右側模式一欄往下排，頂部模式橫向多欄
$CellWidth = @{ bar = 244; gauge = 70; text = 144 }   # 條狀：標籤 78 + 軌道 106 + 數值 60
function Get-ColumnWidth { $CellWidth[$script:Style] + $(if ($script:Edge -eq 'top' -and $script:Style -ne 'gauge') { 16 } else { 0 }) }
function Get-WindowWidth {
  if ($script:Edge -eq 'top') {
    $Columns = switch ($script:Style) { 'bar' { 3 } 'text' { 4 } default { [math]::Max(1, [math]::Min(10, $Cells.Count)) } }
    return $Columns * (Get-ColumnWidth) + 26   # 左右邊距 24 + 邊框 2
  }
  $Columns = if ($script:Style -eq 'gauge') { 3 } else { 1 }
  return $Columns * (Get-ColumnWidth) + 40     # 把手 16 + 邊距 22 + 邊框 2
}

$Brushes = @{}
function Get-Brush([string]$Color) {
  if (-not $Brushes.ContainsKey($Color)) { $B = $Converter.ConvertFrom($Color); $B.Freeze(); $Brushes[$Color] = $B }
  return $Brushes[$Color]
}

# 四段：藍 <50 充裕、綠 50–74 用掉一半、黃 75–89 注意、紅 ≥90 快用完（燈號快閃）。GPU 溫度同刻度（°C）
$AlertLevel = 90
function Get-LevelColor($Percent) {
  if ($null -eq $Percent) { '#66FFFFFF' }
  elseif ($Percent -ge $AlertLevel) { '#FF5C5C' }
  elseif ($Percent -ge 75) { '#FACC15' }
  elseif ($Percent -ge 50) { '#4ADE80' }
  else { '#60A5FA' }
}

function New-Text([string]$Text, [double]$Size, [string]$Color) {
  $Block = New-Object Windows.Controls.TextBlock
  $Block.Text = $Text; $Block.FontSize = $Size
  $Block.Foreground = Get-Brush $Color
  return $Block
}

function Get-CellMargin([double]$Top, [double]$Bottom) {
  $Side = if ($script:Edge -eq 'top' -and $script:Style -ne 'gauge') { 8 } else { 0 }
  return New-Object Windows.Thickness($Side, $Top, $Side, $Bottom)
}

# 元件只在項目清單、樣式或位置改變時建立一次，之後每秒只改數值，避免整個重繪造成閃爍
function New-BarCell($Item, [bool]$Gap) {
  $Grid = New-Object Windows.Controls.Grid
  $Grid.Width = $CellWidth.bar
  $Grid.Margin = Get-CellMargin ($(if ($Gap) { 8 } else { 2 })) 2
  foreach ($W in 78, 1, 60) {
    $Col = New-Object Windows.Controls.ColumnDefinition
    $Col.Width = if ($W -eq 1) { New-Object Windows.GridLength(1, 'Star') } else { New-Object Windows.GridLength($W) }
    $Grid.ColumnDefinitions.Add($Col)
  }
  $Grid.Children.Add((New-Text $Item.Label 12 '#DDFFFFFF')) | Out-Null
  $Track = New-Object Windows.Controls.Border
  $Track.Height = 6; $Track.CornerRadius = 3; $Track.VerticalAlignment = 'Center'
  $Track.Background = Get-Brush '#26FFFFFF'
  [Windows.Controls.Grid]::SetColumn($Track, 1)
  $Fill = New-Object Windows.Controls.Border
  $Fill.CornerRadius = 3; $Fill.HorizontalAlignment = 'Left'
  $Track.Child = $Fill
  $Grid.Children.Add($Track) | Out-Null
  $Text = New-Text '' 12 '#FFFFFFFF'
  $Text.HorizontalAlignment = 'Right'
  [Windows.Controls.Grid]::SetColumn($Text, 2)
  $Grid.Children.Add($Text) | Out-Null
  return @{ Root = $Grid; Fill = $Fill; Text = $Text }
}

function New-GaugeCell($Item) {
  # 半圓儀表：圓心 (28,30)、半徑 24，0% 在左、100% 在右
  $Panel = New-Object Windows.Controls.StackPanel
  $Panel.Width = $CellWidth.gauge; $Panel.Margin = Get-CellMargin 2 6
  $Canvas = New-Object Windows.Controls.Canvas
  $Canvas.Width = 56; $Canvas.Height = 33
  $Arcs = foreach ($Color in '#26FFFFFF', '#00000000') {
    $Path = New-Object Windows.Shapes.Path
    $Path.Data = [Windows.Media.Geometry]::Parse('M 4,30 A 24,24 0 0 1 52,30')
    $Path.Stroke = Get-Brush $Color; $Path.StrokeThickness = 5
    $Path.StrokeStartLineCap = 'Round'; $Path.StrokeEndLineCap = 'Round'
    $Canvas.Children.Add($Path) | Out-Null
    $Path
  }
  $Needle = New-Object Windows.Shapes.Line
  $Needle.X1 = 28; $Needle.Y1 = 30; $Needle.X2 = 11; $Needle.Y2 = 30
  $Needle.Stroke = Get-Brush '#FFFFFFFF'; $Needle.StrokeThickness = 2; $Needle.StrokeEndLineCap = 'Round'
  $Canvas.Children.Add($Needle) | Out-Null
  $Hub = New-Object Windows.Shapes.Ellipse
  $Hub.Width = 6; $Hub.Height = 6; $Hub.Fill = Get-Brush '#FFFFFFFF'
  [Windows.Controls.Canvas]::SetLeft($Hub, 25); [Windows.Controls.Canvas]::SetTop($Hub, 27)
  $Canvas.Children.Add($Hub) | Out-Null
  $Panel.Children.Add($Canvas) | Out-Null
  $Text = New-Text '' 12 '#FFFFFFFF'
  $Label = New-Text $Item.Label 10 '#99FFFFFF'
  foreach ($Line in $Text, $Label) { $Line.HorizontalAlignment = 'Center'; $Panel.Children.Add($Line) | Out-Null }
  return @{ Root = $Panel; Arc = $Arcs[1]; Needle = $Needle; Text = $Text; Last = -1 }
}

function New-TextCell($Item, [bool]$Gap) {
  $Grid = New-Object Windows.Controls.Grid
  $Grid.Width = $CellWidth.text
  $Grid.Margin = Get-CellMargin ($(if ($Gap) { 5 } else { 0 })) 0
  $Grid.Children.Add((New-Text $Item.Label 11 '#CCFFFFFF')) | Out-Null
  $Value = New-Text '' 11 '#66FFFFFF'
  $Value.HorizontalAlignment = 'Right'
  $Grid.Children.Add($Value) | Out-Null
  return @{ Root = $Grid; Value = $Value }
}

# 把手上的燈號：每個項目一顆，平常依序慢慢呼吸（波浪），到 $AlertLevel（90%）以上改成快閃
# ponytail: 透明視窗每格動畫都要整窗重繪，限 20fps 省 CPU；還嫌耗就改成只在收合時播放
function New-Dot([int]$Index) {
  $Dot = New-Object Windows.Shapes.Ellipse
  $Dot.Width = 6; $Dot.Height = 6
  $Dot.Margin = if ($script:Edge -eq 'top') { New-Object Windows.Thickness(2, 0, 2, 0) } else { New-Object Windows.Thickness(0, 2, 0, 2) }
  $Dot.Fill = Get-Brush '#66FFFFFF'
  return $Dot
}
function Set-DotPulse($Cell, [bool]$Alert) {
  $Cell.Alert = $Alert
  $Ms = if ($Alert) { 350 } else { 1400 }
  $Anim = New-Object Windows.Media.Animation.DoubleAnimation(1.0, 0.3, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds($Ms))))
  $Anim.AutoReverse = $true
  $Anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
  $Anim.BeginTime = [TimeSpan]::FromMilliseconds($Cell.Index * 160)
  [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($Anim, 20)
  $Cell.Dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $Anim)
}

function Set-Cell($Cell, $Item) {
  if ($Cell.Dot) {
    $Cell.Dot.Fill = Get-Brush (Get-LevelColor $Item.Percent)
    $Alert = $Item.Percent -ge $AlertLevel
    if ($Cell.Alert -ne $Alert) { Set-DotPulse $Cell $Alert }
  }
  $Tip = if ($Item.Tip) { $Item.Tip } else { $null }
  if ($Cell.Root.ToolTip -ne $Tip) { $Cell.Root.ToolTip = $Tip }
  $Brush = Get-Brush (Get-LevelColor $Item.Percent)
  switch ($script:Style) {
    'gauge' {
      $Cell.Text.Text = $Item.Text
      if ($Cell.Last -ne $Item.Value) {
        $Cell.Last = $Item.Value
        $Angle = [math]::PI * (1 - $Item.Value / 100)
        $Cell.Needle.X2 = 28 + 17 * [math]::Cos($Angle); $Cell.Needle.Y2 = 30 - 17 * [math]::Sin($Angle)
        if ($Item.Value -gt 0) {
          $Cell.Arc.Data = [Windows.Media.Geometry]::Parse([string]::Format($Invariant, 'M 4,30 A 24,24 0 0 1 {0:0.##},{1:0.##}', (28 + 24 * [math]::Cos($Angle)), (30 - 24 * [math]::Sin($Angle))))
          $Cell.Arc.Visibility = 'Visible'
        } else { $Cell.Arc.Visibility = 'Collapsed' }
      }
      $Cell.Arc.Stroke = $Brush
    }
    'text' { $Cell.Value.Text = $Item.Text; $Cell.Value.Foreground = $Brush }
    default {
      $Cell.Fill.Width = [math]::Round(1.06 * $Item.Value)  # 軌道寬 106px，改寬度要一起改
      $Cell.Fill.Background = $Brush
      $Cell.Text.Text = $Item.Text
    }
  }
}

function Get-Items {
  $Items = New-Object Collections.Generic.List[object]
  function Add-Item($Group, $Label, $Percent, $Tip = '', $Text = '') {
    $Value = if ($null -eq $Percent) { 0 } else { [math]::Max(0, [math]::Min(100, [double]$Percent)) }
    if ($null -eq $Percent) { $Text = '—' } elseif (-not $Text) { $Text = "$([math]::Round([double]$Percent))%" }
    $Items.Add([pscustomobject]@{ Group = $Group; Label = $Label; Percent = $Percent; Value = $Value; Text = $Text; Tip = $Tip })
  }
  foreach ($Provider in @($State.usage.providers)) {
    if (-not $Provider -or $Provider.installed -eq $false) { continue }  # 沒安裝的服務不佔小工具版面
    if (-not $Provider.available) {
      Add-Item $Provider.id $Provider.name $null ($(if ($Provider.installed) { '暫無資料' } else { '這台電腦尚未安裝' }))
      continue
    }
    foreach ($Limit in @($Provider.windows)) {
      $Tip = if ($Limit.resetsAt) { '重置於 ' + ([datetime]$Limit.resetsAt).ToLocalTime().ToString('M/d HH:mm') } elseif ($Limit.resetPassed) { '已重置' } else { '' }
      if ($Provider.stale -and $Provider.message) { $Tip = ("$Tip`n舊資料：$($Provider.message)").Trim() }
      if ($Provider.id -eq 'antigravity') {
        # 「Claude Opus 5.5」→「AG Opus」：去掉廠牌字與含數字的版本號，完整名稱放提示
        $Short = (($Limit.label -split '\s+') | Where-Object { $_ -notmatch '^(Claude|Gemini)$' -and $_ -notmatch '\d' }) -join ' '
        if (-not $Short) { $Short = $Limit.label }
        Add-Item $Provider.id "AG $Short" $Limit.usedPercent ("Antigravity $($Limit.label)`n$Tip").Trim()
        continue
      }
      $Short = $Limit.label -replace '額度', '' -replace '每週 · 所有模型', '週' -replace '每週 · ', '週·' -replace '\s+', ''
      Add-Item $Provider.id "$($Provider.name) $Short" $Limit.usedPercent $Tip
    }
  }
  Add-Item 'sys' 'CPU' $State.cpu
  Add-Item 'sys' 'GPU' $State.gpu
  $TempTip = if ($null -eq $State.gpuTemp) { '此顯示卡未提供溫度（目前支援 NVIDIA）' } else { '' }
  Add-Item 'sys' 'GPU 溫度' $State.gpuTemp $TempTip "$($State.gpuTemp)°C"
  if ($State.vramTotal) {
    $Kind = if ($State.vramShared) { '共用 GPU 記憶體' } else { '專用顯示卡記憶體' }
    $VramTip = '{0}：{1:N1} / {2:N1} GB' -f $Kind, ($State.vramUsed / 1GB), ($State.vramTotal / 1GB)
    Add-Item 'sys' '顯存' (100 * $State.vramUsed / $State.vramTotal) $VramTip ('{0:N1}/{1:N0}G' -f ($State.vramUsed / 1GB), ($State.vramTotal / 1GB))
  } else { Add-Item 'sys' '顯存' $null }
  Add-Item 'sys' 'RAM' $State.ram
  return $Items
}

$Cells = New-Object Collections.Generic.List[object]
$Signature = ''
# 使用者勾掉不想看的項目：存在 .widget-hidden（UTF-8，一行一個項目名稱）
$HiddenFile = Join-Path $PSScriptRoot '.widget-hidden'
$Hidden = New-Object 'System.Collections.Generic.HashSet[string]'
try { foreach ($Line in Get-Content -LiteralPath $HiddenFile -Encoding UTF8 -ErrorAction Stop) { if ($Line.Trim()) { [void]$Hidden.Add($Line.Trim()) } } } catch {}
function Save-Hidden { try { Set-Content -LiteralPath $HiddenFile -Value @($Hidden) -Encoding UTF8 } catch {} }
$AllItems = @()
function Update-Widget {
  $script:AllItems = @(Get-Items)
  $Items = @($script:AllItems | Where-Object { -not $Hidden.Contains($_.Label) })
  $Sig = "$($script:Style)|$($script:Edge)|" + (($Items | ForEach-Object { "$($_.Group)/$($_.Label)" }) -join ',')
  if ($Sig -ne $script:Signature) {
    $script:Signature = $Sig
    $Rows.Children.Clear()
    $Dots.Children.Clear()
    $Cells.Clear()
    $Previous = $null
    foreach ($Item in $Items) {
      # 分組間距只在右側直排時有意義；頂部橫排、指針格子不加
      $Gap = $script:Edge -eq 'side' -and $null -ne $Previous -and $Item.Group -ne $Previous
      $Cell = switch ($script:Style) {
        'gauge' { New-GaugeCell $Item }
        'text' { New-TextCell $Item $Gap }
        default { New-BarCell $Item $Gap }
      }
      $Rows.Children.Add($Cell.Root) | Out-Null
      $Cell.Index = $Cells.Count
      $Cell.Dot = New-Dot $Cell.Index
      $Cell.Alert = $null
      $Dots.Children.Add($Cell.Dot) | Out-Null
      $Cells.Add($Cell)
      $Previous = $Item.Group
    }
  }
  for ($I = 0; $I -lt $Items.Count; $I++) { Set-Cell $Cells[$I] $Items[$I] }
  $Width = Get-WindowWidth
  if ($Window.Width -ne $Width) { $Window.Width = $Width }
  # 標題列右邊：平常顯示時間；有新版、更新中、更新失敗時改成提示
  $U = $State.update
  # 需要使用者處理的事（例如 Claude 要重新登入），要跳通知的排前面
  $Needs = @(@($State.usage.providers) | Where-Object { $_ -and $_.attention } | Sort-Object { -not $_.attention.notify }) | Select-Object -First 1
  Check-Attention
  # 語音指令的回應：藍字顯示幾秒，蓋過其他狀態；標題暫時讓位
  $VoiceActive = $VoiceShow -and (Get-Date) -lt $VoiceShow.Until
  $TitleText.Visibility = if ($VoiceActive) { 'Hidden' } else { 'Visible' }
  $Line = if ($VoiceActive) { @($VoiceShow.Text, '#60A5FA') }
    elseif ($State.offline) { @('服務離線', '#99FFFFFF') }
    elseif ($U.status -in 'downloading', 'installing') { @('更新中…', '#FACC15') }
    elseif ($U.status -eq 'error') { @('更新失敗', '#FF5C5C') }
    elseif ($Needs) { @($Needs.attention.text, '#FACC15') }
    elseif ($U.newer) { @("有新版 v$($U.latest)", '#FACC15') }
    else { @((Get-Date).ToString('HH:mm'), '#99FFFFFF') }
  $Status.Text = $Line[0]
  $Status.Foreground = Get-Brush $Line[1]
  $Tip = if ($U.status -eq 'error') { $U.error } elseif ($Needs) { "$($Needs.message)" } elseif ($U.newer) { '右鍵選單可以更新' } else { $null }
  if ($Status.ToolTip -ne $Tip) { $Status.ToolTip = $Tip }
}

# 右側：把手在左邊（直的）；頂部：把手移到下緣（橫的），燈號跟著轉橫排
function Apply-Edge {
  $IsTop = $script:Edge -eq 'top'
  $HandleCol.Width = New-Object Windows.GridLength($(if ($IsTop) { 0 } else { 16 }))
  $HandleRow.Height = New-Object Windows.GridLength($(if ($IsTop) { 16 } else { 0 }))
  [Windows.Controls.Grid]::SetRow($Handle, $(if ($IsTop) { 1 } else { 0 }))
  [Windows.Controls.Grid]::SetColumnSpan($Handle, $(if ($IsTop) { 2 } else { 1 }))
  [Windows.Controls.Grid]::SetColumn($Body, $(if ($IsTop) { 0 } else { 1 }))
  [Windows.Controls.Grid]::SetColumnSpan($Body, $(if ($IsTop) { 2 } else { 1 }))
  $Handle.CornerRadius = if ($IsTop) { New-Object Windows.CornerRadius(0, 0, 9, 9) } else { New-Object Windows.CornerRadius(9, 0, 0, 9) }
  $HandleBody.Orientation = if ($IsTop) { 'Horizontal' } else { 'Vertical' }
  $Dots.Orientation = $HandleBody.Orientation
  $Dots.Margin = if ($IsTop) { New-Object Windows.Thickness(8, 0, 0, 0) } else { New-Object Windows.Thickness(0, 6, 0, 0) }
  $Body.Margin = if ($IsTop) { New-Object Windows.Thickness(12, 10, 12, 6) } else { New-Object Windows.Thickness(10, 10, 12, 10) }
}

# 釘選＝固定展開；未釘選＝平常收合，滑鼠移過把手才滑出來
$PinFile = Join-Path $PSScriptRoot '.widget-pinned'
$Pinned = $true
try { if ((Get-Content -LiteralPath $PinFile -Raw -ErrorAction Stop).Trim() -eq '0') { $Pinned = $false } } catch {}
$Dragged = $false
$Collapsed = -not $Pinned
# 把手可沿邊緣拖：右側存高度 .widget-top，頂部存水平位置 .widget-left（DIP）；沒拖過就用預設位置
function Read-Number([string]$File) {
  try { return [double]::Parse((Get-Content -LiteralPath $File -Raw -ErrorAction Stop).Trim(), $Invariant) } catch { return $null }
}
$TopFile = Join-Path $PSScriptRoot '.widget-top'
$LeftFile = Join-Path $PSScriptRoot '.widget-left'
$CustomTop = Read-Number $TopFile
$CustomLeft = Read-Number $LeftFile
function Get-Dock {
  $Area = [Windows.SystemParameters]::WorkArea
  $W = $Window.ActualWidth; $H = $Window.ActualHeight
  if ($script:Edge -eq 'top') {
    # 頂部：預設置中；收合時往上滑，只露出下緣 17px 的把手。展開一律貼齊上緣，游標停在把手上滑出後仍在面板內
    # ponytail: 上方若還有另一台螢幕，收合的部分會出現在那台；需要時改成依所在螢幕計算
    $Left = if ($null -ne $script:CustomLeft) { [math]::Min([math]::Max($script:CustomLeft, $Area.Left), $Area.Right - $W) } else { $Area.Left + ($Area.Width - $W) / 2 }
    $Top = if ($script:Collapsed) { $Area.Top - $H + 17 } else { $Area.Top }
    return @{ Left = $Left; Top = $Top }
  }
  # 右側：未釘選的滑出預覽要貼齊螢幕右緣：游標停在把手上，滑出後仍在面板內，才不會一出來就判定離開又收回
  $Left = if ($script:Collapsed) { $Area.Right - 17 } elseif (-not $script:Pinned) { $Area.Right - $W } else { $Area.Right - $W - 12 }
  $Top = if ($null -ne $script:CustomTop) { [math]::Min([math]::Max($script:CustomTop, $Area.Top), $Area.Bottom - $H) } else { $Area.Bottom - $H - 12 }
  return @{ Left = $Left; Top = $Top }
}
function Get-MouseDip {
  $Source = [Windows.PresentationSource]::FromVisual($Window)
  if (-not $Source) { return $null }
  $Scale = $Source.CompositionTarget.TransformToDevice.M11
  $Mouse = [System.Windows.Forms.Control]::MousePosition
  return @{ X = $Mouse.X / $Scale; Y = $Mouse.Y / $Scale }
}
# 參考型別，讓動畫完成事件（閉包）也能讀寫。滑進滑出可能在動畫途中反向觸發：
# 新動畫會取代舊的，只有代號仍是最新的那個動畫完成時才寫入最終位置
$Slide = @{ Until = [datetime]::MinValue }
$Drag = @{ Active = $false; Moved = $false; Start = 0; Grab = 0 }
function Move-ToCorner {
  if ($script:Dragged -or $Drag.Active -or (Get-Date) -lt $Slide.Until) { return }
  $Dock = Get-Dock
  if ([math]::Abs($Window.Left - $Dock.Left) -gt 0.5) { $Window.Left = $Dock.Left }
  if ([math]::Abs($Window.Top - $Dock.Top) -gt 0.5) { $Window.Top = $Dock.Top }
}
function Start-Slide($Property, [double]$To) {
  $W = $Window; $S = $Slide; $Token = [guid]::NewGuid()
  $S[$Property.Name] = $Token
  $S.Until = (Get-Date).AddMilliseconds(400)
  $Anim = New-Object Windows.Media.Animation.DoubleAnimation([double]$W.GetValue($Property), $To, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(280))))
  $Ease = New-Object Windows.Media.Animation.CubicEase; $Ease.EasingMode = 'EaseOut'
  $Anim.EasingFunction = $Ease
  # 跑完才寫入最終位置再拿掉動畫：開頭不會先跳到終點，結尾也不會閃回起點
  $Anim.Add_Completed({ if ($S[$Property.Name] -eq $Token) { $W.SetValue($Property, $To); $W.BeginAnimation($Property, $null) } }.GetNewClosure())
  $W.BeginAnimation($Property, $Anim)
}
function Update-Handle {
  # 收合：箭頭指向滑出方向（右側往左、頂部往下）；展開時顯示圖釘，亮＝已釘選、暗＝滑鼠移開就會收回
  $Arrow.Text = if (-not $script:Collapsed) { [string][char]0xE718 } elseif ($script:Edge -eq 'top') { [string][char]0xE70D } else { [string][char]0xE76B }
  $Arrow.Foreground = Get-Brush $(if ($script:Pinned -and -not $script:Collapsed) { '#FFFFFFFF' } else { '#88FFFFFF' })
  $Handle.ToolTip = if ($script:Pinned) { '已釘選：點一下取消（改為自動收合）' } else { '點一下釘選（固定展開）' }
}
function Set-Collapsed([bool]$Value) {
  $script:Collapsed = $Value
  $script:Dragged = $false
  Update-Handle
  $Dock = Get-Dock
  Start-Slide ([Windows.Window]::LeftProperty) $Dock.Left
  Start-Slide ([Windows.Window]::TopProperty) $Dock.Top
}
function Set-Pinned([bool]$Value) {
  $script:Pinned = $Value
  try { Set-Content -LiteralPath $PinFile -Value ([int]$Value) -Encoding ascii } catch {}
  Set-Collapsed (-not $Value)
}
function Set-Edge([string]$Value) {
  $script:Edge = $Value
  try { Set-Content -LiteralPath $EdgeFile -Value $Value -Encoding ascii } catch {}
  Apply-Edge
  Update-Widget            # 位置進了簽章，會重建格子與燈號並換寬度
  $Window.UpdateLayout()   # 先算出新寬高，Get-Dock 才會用到正確尺寸
  Set-Collapsed $script:Collapsed
}
# 把手：點一下切換釘選；按住沿邊緣拖超過 4px 則移動（右側上下、頂部左右）
function Get-DragAxis {
  if ($script:Edge -eq 'top') { return @{ Property = [Windows.Window]::LeftProperty; Key = 'X' } }
  return @{ Property = [Windows.Window]::TopProperty; Key = 'Y' }
}
$Handle.Add_MouseLeftButtonDown({
  param($Sender, $E)
  $E.Handled = $true
  $Mouse = Get-MouseDip
  if (-not $Mouse) { return }
  $Axis = Get-DragAxis
  $Slide[$Axis.Property.Name] = 'drag'  # 讓進行中的動畫完成時不要蓋掉拖曳位置
  $Window.BeginAnimation($Axis.Property, $null)
  $Drag.Active = $true; $Drag.Moved = $false; $Drag.Start = $Mouse[$Axis.Key]; $Drag.Grab = $Mouse[$Axis.Key] - $Window.GetValue($Axis.Property)
  [void]$Handle.CaptureMouse()
})
$Handle.Add_MouseMove({
  if (-not $Drag.Active) { return }
  $Mouse = Get-MouseDip
  if (-not $Mouse) { return }
  $Axis = Get-DragAxis
  if (-not $Drag.Moved -and [math]::Abs($Mouse[$Axis.Key] - $Drag.Start) -lt 4) { return }
  $Drag.Moved = $true
  $Area = [Windows.SystemParameters]::WorkArea
  if ($script:Edge -eq 'top') {
    $script:CustomLeft = [math]::Min([math]::Max($Mouse.X - $Drag.Grab, $Area.Left), $Area.Right - $Window.ActualWidth)
    $Window.Left = $script:CustomLeft
  } else {
    $script:CustomTop = [math]::Min([math]::Max($Mouse.Y - $Drag.Grab, $Area.Top), $Area.Bottom - $Window.ActualHeight)
    $Window.Top = $script:CustomTop
  }
})
$Handle.Add_MouseLeftButtonUp({
  param($Sender, $E)
  if (-not $Drag.Active) { return }
  $E.Handled = $true
  $Drag.Active = $false
  $Handle.ReleaseMouseCapture()
  if ($Drag.Moved) {
    $File, $Value = if ($script:Edge -eq 'top') { $LeftFile, $script:CustomLeft } else { $TopFile, $script:CustomTop }
    try { Set-Content -LiteralPath $File -Value ($Value.ToString($Invariant)) -Encoding ascii } catch {}
    $Hover.Suppress = $true  # 放開時游標還在把手上：等游標離開過，下次移入才滑出
  } else { Set-Pinned (-not $script:Pinned) }
})
$Window.Add_SizeChanged({ Move-ToCorner })
$Window.Add_MouseLeftButtonDown({ if ($script:Pinned -and -not $script:Collapsed) { $script:Dragged = $true; $Window.DragMove() } })

# 未釘選時：游標停在小工具上 0.2 秒才滑出（避免經過工作列誤觸），離開 0.5 秒才收回。
# 不用 MouseEnter/MouseLeave：視窗自己滑動、游標沒動時 WPF 會誤判離開，造成來回彈；改成每 0.1 秒比對游標座標
Add-Type -AssemblyName System.Windows.Forms
$Hover = @{ Over = 0; Away = 0; Suppress = $false }
$HoverTimer = New-Object Windows.Threading.DispatcherTimer
$HoverTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$HoverTimer.Add_Tick({
  if ($script:Pinned -or $Drag.Active -or $Window.ContextMenu.IsOpen) { $Hover.Over = 0; $Hover.Away = 0; return }
  $Mouse = Get-MouseDip
  if (-not $Mouse) { return }
  $Inside = $Mouse.X -ge $Window.Left -and $Mouse.X -le $Window.Left + $Window.ActualWidth -and $Mouse.Y -ge $Window.Top -and $Mouse.Y -le $Window.Top + $Window.ActualHeight
  if ($Hover.Suppress) { if (-not $Inside) { $Hover.Suppress = $false }; return }
  if ($Inside) { $Hover.Over += 100; $Hover.Away = 0 } else { $Hover.Away += 100; $Hover.Over = 0 }
  if ($script:Collapsed -and $Hover.Over -ge 200) { Set-Collapsed $false }
  elseif (-not $script:Collapsed -and $Hover.Away -ge 500) { Set-Collapsed $true }
})
$HoverTimer.Start()

$Menu = New-Object Windows.Controls.ContextMenu
$Open = New-Object Windows.Controls.MenuItem; $Open.Header = '開啟完整儀表板'
$Open.Add_Click({ Start-Process "http://localhost:$Port" })
$Corner = New-Object Windows.Controls.MenuItem; $Corner.Header = '回到預設位置'
$Corner.Add_Click({
  $script:CustomTop = $null; $script:CustomLeft = $null
  foreach ($File in $TopFile, $LeftFile) { if (Test-Path -LiteralPath $File) { [IO.File]::Delete($File) } }
  Set-Pinned $true
})
$Quit = New-Object Windows.Controls.MenuItem; $Quit.Header = '關閉小工具'
$Quit.Add_Click({ $Window.Close() })
function New-ChoiceMenu([string]$Header, [object[]]$Options, [string]$Current, [scriptblock]$OnPick) {
  $Parent = New-Object Windows.Controls.MenuItem; $Parent.Header = $Header
  foreach ($Option in $Options) {
    $Choice = New-Object Windows.Controls.MenuItem
    $Choice.Header = $Option[1]; $Choice.Tag = $Option[0]; $Choice.IsChecked = ($Option[0] -eq $Current)
    $Choice.Add_Click({
      param($Sender)
      foreach ($Other in $Sender.Parent.Items) { $Other.IsChecked = ($Other -eq $Sender) }
      & $OnPick $Sender.Tag
    }.GetNewClosure())
    $Parent.Items.Add($Choice) | Out-Null
  }
  return $Parent
}
function Set-Style([string]$Value) {
  $script:Style = $Value
  try { Set-Content -LiteralPath $StyleFile -Value $Value -Encoding ascii } catch {}
  # 語音換樣式時，選單的勾勾也要跟著換
  foreach ($Other in $StyleMenu.Items) { $Other.IsChecked = ($Other.Tag -eq $Value) }
  Update-Widget
}
$StyleMenu = New-ChoiceMenu '樣式' @(@('bar', '條狀'), @('gauge', '指針'), @('text', '純數字')) $Style { param($Value) Set-Style $Value }
$EdgeMenu = New-ChoiceMenu '位置' @(@('side', '右側'), @('top', '頂部')) $Edge { param($Value) Set-Edge $Value }
# 顯示項目：每次打開選單時依目前的項目重建，打勾＝顯示；點了不關選單，可以連續勾
$ShowMenu = New-Object Windows.Controls.MenuItem; $ShowMenu.Header = '顯示項目'
function Update-ShowMenu {
  $ShowMenu.Items.Clear()
  $All = New-Object Windows.Controls.MenuItem; $All.Header = '全部顯示'; $All.StaysOpenOnClick = $true
  $All.Add_Click({
    $Hidden.Clear(); Save-Hidden
    foreach ($Other in $ShowMenu.Items) { if ($Other -is [Windows.Controls.MenuItem] -and $Other.IsCheckable) { $Other.IsChecked = $true } }
    Update-Widget
  })
  $ShowMenu.Items.Add($All) | Out-Null
  $PreviousGroup = $null
  foreach ($Entry in $script:AllItems) {
    if ($Entry.Group -ne $PreviousGroup) { $ShowMenu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null; $PreviousGroup = $Entry.Group }
    $Choice = New-Object Windows.Controls.MenuItem
    $Choice.Header = $Entry.Label; $Choice.Tag = $Entry.Label
    $Choice.IsCheckable = $true; $Choice.StaysOpenOnClick = $true
    $Choice.IsChecked = -not $Hidden.Contains($Entry.Label)
    $Choice.Add_Click({
      param($Sender)
      if ($Sender.IsChecked) { [void]$Hidden.Remove($Sender.Tag) } else { [void]$Hidden.Add($Sender.Tag) }
      Save-Hidden
      Update-Widget
    })
    $ShowMenu.Items.Add($Choice) | Out-Null
  }
}
# 更新：有新版才出現在選單最上面。MSI 安裝版先確認再請伺服器下載安裝；可攜版打開 GitHub 下載頁
$UpdateItem = New-Object Windows.Controls.MenuItem
$UpdateItem.FontWeight = 'Bold'
function Update-UpdateItem {
  $U = $State.update
  if (-not $U -or -not $U.newer -or $U.status -in 'downloading', 'installing') { $UpdateItem.Visibility = 'Collapsed'; return }
  $UpdateItem.Visibility = 'Visible'
  $UpdateItem.Header = if ($U.managed) { "更新到 v$($U.latest)…" } else { "下載新版 v$($U.latest)…" }
}
function Confirm-Update([string]$Version) {
  $Text = "要現在更新到 v$Version 嗎？`n`n小工具會先關閉，安裝完成後幾秒內自動重新開啟，設定會保留。"
  return [System.Windows.MessageBox]::Show($Window, $Text, 'AI 額度小工具', 'YesNo', 'Question') -eq 'Yes'
}
function Invoke-Update {
  $U = $State.update
  if (-not $U.managed) {
    if ("$($U.pageUrl)" -like 'https://github.com/*') { Start-Process $U.pageUrl }
    return
  }
  if (-not (Confirm-Update $U.latest)) { return }
  try {
    $Client = New-Object Net.WebClient
    $Client.Encoding = [Text.Encoding]::UTF8
    if ($AccessKey) { $Client.Headers.Add('x-access-key', $AccessKey) }
    $State.update = $Client.UploadString("http://localhost:$Port/api/update/install", 'POST', '') | ConvertFrom-Json
  } catch { [void][System.Windows.MessageBox]::Show($Window, "無法開始更新：$($_.Exception.Message)", 'AI 額度小工具') }
  Update-Widget
}
$UpdateItem.Add_Click({ Invoke-Update })

# 需要處理的提醒：同一次失效只通知一次（處理好、提醒消失後再失效才會再通知）；
# 期間系統匣留一個圖示，處理好就自動拿掉
Add-Type -AssemblyName System.Drawing
$Notified = New-Object 'System.Collections.Generic.HashSet[string]'
$Tray = $null
$TrayAction = $null
function Invoke-Attention([string]$Action) {
  if ($Action -eq 'claude-login') {
    # 開 Claude 官方登入；跑完停在畫面上讓人看結果
    $Setup = Join-Path $PSScriptRoot 'claude-setup.ps1'
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"& '$Setup'; Write-Host ''; Read-Host '按 Enter 關閉此視窗'`""
  } elseif ($Action -eq 'codex-login') {
    # Codex 官方登入（會開瀏覽器）；找不到 PATH 上的 codex 就用桌面版內附的
    $Codex = (Get-Command codex -ErrorAction SilentlyContinue).Source
    if (-not $Codex) { $Codex = Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe' }
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"& '$Codex' login; Write-Host ''; Read-Host '按 Enter 關閉此視窗'`""
  } else { Start-Process "http://localhost:$Port" }
}
function Show-Notice($Provider) {
  if (-not $script:Tray) {
    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    try { $script:Tray.Icon = New-Object System.Drawing.Icon (Join-Path $PSScriptRoot 'app.ico') } catch { $script:Tray.Icon = [System.Drawing.SystemIcons]::Information }
    $script:Tray.Text = 'AI 額度小工具'
    $script:Tray.Add_BalloonTipClicked({ Invoke-Attention $script:TrayAction })
    $script:Tray.Add_MouseClick({ Invoke-Attention $script:TrayAction })
  }
  $script:TrayAction = $Provider.attention.action
  $script:Tray.Visible = $true
  $script:Tray.BalloonTipTitle = 'AI 額度小工具'
  $script:Tray.BalloonTipText = "$($Provider.attention.text)。點這裡處理。"
  $script:Tray.ShowBalloonTip(15000)
}
function Check-Attention {
  $Active = $false
  foreach ($Provider in @($State.usage.providers)) {
    if (-not $Provider) { continue }
    if ($Provider.attention -and $Provider.attention.notify) {
      $Active = $true
      if ($Notified.Add($Provider.id)) { Show-Notice $Provider }
    } else { [void]$Notified.Remove($Provider.id) }
  }
  if (-not $Active -and $script:Tray) { $script:Tray.Visible = $false }
}
$LoginItem = New-Object Windows.Controls.MenuItem
$LoginItem.Header = '重新登入 Claude…'; $LoginItem.FontWeight = 'Bold'
$LoginItem.Add_Click({ Invoke-Attention 'claude-login' })
$CodexLoginItem = New-Object Windows.Controls.MenuItem
$CodexLoginItem.Header = '重新登入 Codex…'; $CodexLoginItem.FontWeight = 'Bold'
$CodexLoginItem.Add_Click({ Invoke-Attention 'codex-login' })
function Update-LoginItem {
  foreach ($Pair in @(@($LoginItem, 'claude-login'), @($CodexLoginItem, 'codex-login'))) {
    $Needed = @(@($State.usage.providers) | Where-Object { $_ -and $_.attention.action -eq $Pair[1] }).Count -gt 0
    $Pair[0].Visibility = if ($Needed) { 'Visible' } else { 'Collapsed' }
  }
}
$Window.Add_Closed({ if ($script:Tray) { $script:Tray.Dispose() } })

# ================================================================
#  語音指令（System.Speech，中文（台灣）離線辨識，只認固定句型）
#  叫喚詞「欸小工具」（「欸」可省略）＋ 指令。預設關閉；右鍵選單勾「語音指令」才開麥克風，設定存在 .widget-voice
# ================================================================
$VoiceFile = Join-Path $PSScriptRoot '.widget-voice'
$VoiceOn = $false
try { $VoiceOn = (Get-Content -LiteralPath $VoiceFile -Raw -ErrorAction Stop).Trim() -eq '1' } catch {}
# 背景執行緒只負責「聽」，把辨識結果丟進佇列；動作一律回到 UI 執行緒做（PowerShell 的事件處理器不能在別的執行緒跑）
$Voice = [hashtable]::Synchronized(@{
  Enabled = $VoiceOn; Status = 'off'; Speaking = $false; QuietUntil = [datetime]::MinValue
  Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
})
$VoiceRunspace = [runspacefactory]::CreateRunspace()
$VoiceRunspace.Open()
$VoiceListener = [powershell]::Create()
$VoiceListener.Runspace = $VoiceRunspace
[void]$VoiceListener.AddScript({
  param($V)
  Add-Type -AssemblyName System.Speech
  $NS = 'System.Speech.Recognition'
  # 每個指令：鍵、說法（中間的 | 分隔可互換的詞，依序接起來）
  $Quota = '還剩多少|剩多少|額度|的額度|額度多少|用了多少|用多少'
  $Commands = @(
    @('open', '打開|展開|開啟|顯示'),
    @('close', '收起來|收起|縮起來|關起來'),
    @('dashboard', '開儀表板|打開儀表板|開啟儀表板'),
    @('style-bar', '換成條狀|改成條狀|條狀'),
    @('style-gauge', '換成指針|改成指針|指針'),
    @('style-text', '換成數字|改成數字|換成純數字|數字'),
    @('quota-claude', "Claude|克勞德|克老德", $Quota),
    @('quota-codex', "Codex|扣德克斯|寇德克斯|扣得克斯", $Quota),
    @('quota-antigravity', "Antigravity|安提格拉維提|反重力", $Quota),
    @('next', '下一首|下一首歌|下一個'),
    @('prev', '上一首|上一首歌|上一個'),
    @('play', '播放|繼續播放|播放音樂'),
    @('pause', '暫停|暫停音樂|停止播放'),
    @('volup', '大聲一點|大聲點|聲音大一點'),
    @('voldown', '小聲一點|小聲點|聲音小一點'),
    @('mute', '靜音|取消靜音')
  )
  function New-Grammar($Culture, [bool]$WithLatin) {
    $All = New-Object "$NS.Choices"
    foreach ($Cmd in $Commands) {
      $Builder = New-Object "$NS.GrammarBuilder"
      $Builder.Culture = $Culture
      $Ok = $true
      foreach ($Part in $Cmd[1..($Cmd.Count - 1)]) {
        $Words = @($Part -split '\|' | Where-Object { $WithLatin -or $_ -notmatch '[A-Za-z]' })
        if ($Words.Count -eq 0) { $Ok = $false; break }
        $Choice = New-Object "$NS.Choices"
        $Choice.Add([string[]]$Words)
        $Builder.Append($Choice)
      }
      if (-not $Ok) { continue }
      $Value = New-Object "$NS.SemanticResultValue" -ArgumentList $Builder, $Cmd[0]
      $All.Add([System.Speech.Recognition.GrammarBuilder[]]@($Value.ToGrammarBuilder()))
    }
    $Root = New-Object "$NS.GrammarBuilder"
    $Root.Culture = $Culture
    $Hey = New-Object "$NS.Choices"
    $Hey.Add([string[]]@('欸', '誒', '哎'))
    $Root.Append((New-Object "$NS.GrammarBuilder" -ArgumentList $Hey), 0, 1)   # 「欸」可以不說
    $Root.Append('小工具')
    $Key = New-Object "$NS.SemanticResultKey" -ArgumentList 'cmd', ([System.Speech.Recognition.GrammarBuilder[]]@((New-Object "$NS.GrammarBuilder" -ArgumentList $All)))
    $Root.Append($Key.ToGrammarBuilder())
    $Grammar = New-Object "$NS.Grammar" -ArgumentList $Root
    $Grammar.Name = 'widget'
    return $Grammar
  }
  function Wait-Retry([int]$Seconds) {
    for ($I = 0; $I -lt $Seconds * 2 -and $V.Enabled; $I++) { Start-Sleep -Milliseconds 500 }
  }
  while ($true) {
    if (-not $V.Enabled) { $V.Status = 'off'; Start-Sleep -Milliseconds 500; continue }
    $Info = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() |
      Where-Object { $_.Culture.Name -eq 'zh-TW' } | Sort-Object { $_.Id -ne 'MS-1028-80-DESK' } | Select-Object -First 1
    if (-not $Info) { $V.Status = 'norecognizer'; Wait-Retry 30; continue }
    $Engine = $null
    try {
      $Engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine -ArgumentList $Info
      try { $Engine.SetInputToDefaultAudioDevice() }
      catch { $V.Status = 'nomic'; $Engine.Dispose(); $Engine = $null; Wait-Retry 30; continue }   # 沒有麥克風：保持開啟，30 秒後再試
      # 英文產品名稱有的辨識引擎編不進中文文法，失敗就只用中文音譯
      try { $Engine.LoadGrammar((New-Grammar $Info.Culture $true)) } catch { $Engine.LoadGrammar((New-Grammar $Info.Culture $false)) }
      $V.Status = 'listening'
      while ($V.Enabled) {
        $R = $Engine.Recognize([TimeSpan]::FromSeconds(3))
        if (-not $R) { continue }
        # 自己正在朗讀時聽到的不算
        if ($V.Speaking -or (Get-Date) -lt $V.QuietUntil) { continue }
        if ($R.Confidence -lt 0.55) { continue }
        $Cmd = $null
        try { $Cmd = [string]$R.Semantics['cmd'].Value } catch {}
        if ($Cmd) { $V.Queue.Enqueue(@($Cmd, $R.Text, $R.Confidence)) }
      }
    } catch {
      # 麥克風被拔掉等：回到開頭重試
      $V.Status = 'nomic'
      Wait-Retry 30
    } finally {
      if ($Engine) { try { $Engine.Dispose() } catch {} }
    }
  }
}).AddArgument($Voice)
[void]$VoiceListener.BeginInvoke()

# 中文朗讀：zh-TW 語音（Microsoft Hanhan）；沒有就只在標題列顯示文字
Add-Type -AssemblyName System.Speech
$Synth = $null
try { $Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer; $Synth.SetOutputToDefaultAudioDevice() } catch { $Synth = $null }
function Get-ZhVoice {
  if (-not $script:Synth) { return $null }
  return $script:Synth.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -eq 'zh-TW' } |
    Sort-Object { $_.VoiceInfo.Name -notmatch 'Hanhan' } | Select-Object -First 1
}
function Invoke-Say([string]$Text) {
  $Zh = Get-ZhVoice
  if (-not $Zh) { return $false }
  try {
    $script:Synth.SelectVoice($Zh.VoiceInfo.Name)
    $script:Synth.SpeakAsyncCancelAll()
    $Voice.Speaking = $true
    [void]$script:Synth.SpeakAsync($Text)
    return $true
  } catch { return $false }
}

# 標題列用藍字顯示幾秒
$VoiceShow = @{ Text = ''; Until = [datetime]::MinValue }
function Show-VoiceText([string]$Text, [double]$Seconds = 4) {
  $VoiceShow.Text = $Text
  $VoiceShow.Until = (Get-Date).AddSeconds($Seconds)
  Update-Widget
}

# 鍵盤媒體鍵：Spotify、YouTube（瀏覽器）等有接 Windows 媒體控制的播放器都吃
Add-Type -Namespace Win32 -Name MediaKeys -MemberDefinition '[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);'
function Send-MediaKey([byte]$Vk, [int]$Times = 1) {
  for ($I = 0; $I -lt $Times; $I++) {
    [Win32.MediaKeys]::keybd_event($Vk, 0, 0, [UIntPtr]::Zero)
    [Win32.MediaKeys]::keybd_event($Vk, 0, 2, [UIntPtr]::Zero)
  }
}

# 額度：念出各額度用了多少 %，舊資料要說明
function Get-QuotaReport([string]$Id) {
  $Names = @{ claude = 'Claude'; codex = 'Codex'; antigravity = 'Antigravity' }
  $Name = $Names[$Id]
  $P = @($State.usage.providers) | Where-Object { $_ -and $_.id -eq $Id } | Select-Object -First 1
  if (-not $P -or $P.installed -eq $false) { return @{ Say = "這台電腦沒有安裝 $Name。"; Show = "$Name：未安裝" } }
  if (-not $P.available -or @($P.windows).Count -eq 0) { return @{ Say = "$Name 目前沒有額度資料。"; Show = "$Name：沒有資料" } }
  $Said = New-Object Collections.Generic.List[string]
  $Shown = New-Object Collections.Generic.List[string]
  foreach ($L in @($P.windows)) {
    if ($Id -eq 'antigravity') {
      $Label = (($L.label -split '\s+') | Where-Object { $_ -notmatch '^(Claude|Gemini)$' -and $_ -notmatch '\d' }) -join ' '
      if (-not $Label) { $Label = $L.label }
    } else {
      $Label = ($L.label -replace '額度', '' -replace '每週 · 所有模型', '每週' -replace '每週 · ', '每週 ').Trim()
    }
    if ($null -eq $L.usedPercent) { $Said.Add("$Label 沒有資料"); $Shown.Add("$Label —"); continue }
    $Pct = [math]::Round([double]$L.usedPercent)
    $Said.Add("$Label 用了百分之$Pct")
    $Shown.Add("$Label $Pct%")
  }
  $Say = "$Name，" + ($Said -join '，') + '。'
  $Show = "$Name " + ($Shown -join ' · ')
  if ($P.stale) {
    $Say += '注意，這是舊資料' + $(if ($P.message) { "，$($P.message)" } else { '' }) + '。'
    $Show += '（舊資料）'
  }
  return @{ Say = $Say; Show = $Show }
}

function Invoke-VoiceCommand([string]$Cmd) {
  # 動作本身的輸出一律丟掉，只留下要顯示的文字
  $Label = $null
  switch ($Cmd) {
    'open' { Set-Pinned $true | Out-Null; $Label = '展開' }
    'close' { Set-Pinned $false | Out-Null; $Label = '收起來' }
    'dashboard' { Start-Process "http://localhost:$Port"; $Label = '開啟儀表板' }
    'style-bar' { Set-Style 'bar' | Out-Null; $Label = '換成條狀' }
    'style-gauge' { Set-Style 'gauge' | Out-Null; $Label = '換成指針' }
    'style-text' { Set-Style 'text' | Out-Null; $Label = '換成數字' }
    'next' { Send-MediaKey 0xB0; $Label = '下一首' }
    'prev' { Send-MediaKey 0xB1; $Label = '上一首' }
    'play' { Send-MediaKey 0xB3; $Label = '播放' }          # 播放／暫停是同一個鍵
    'pause' { Send-MediaKey 0xB3; $Label = '暫停' }
    'volup' { Send-MediaKey 0xAF 5; $Label = '大聲一點' }   # 每按一下約 2%
    'voldown' { Send-MediaKey 0xAE 5; $Label = '小聲一點' }
    'mute' { Send-MediaKey 0xAD; $Label = '靜音' }
  }
  if ($Cmd -like 'quota-*') {
    $Report = Get-QuotaReport ($Cmd.Substring(6))
    $Spoken = Invoke-Say $Report.Say
    Show-VoiceText $Report.Show $(if ($Spoken) { 6 } else { 10 })
    return
  }
  if ($Label) { Show-VoiceText ([string][char]0xD83C + [char]0xDF99 + ' ' + $Label) }
}

function Test-ZhRecognizer {
  return [bool](@([System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() | Where-Object { $_.Culture.Name -eq 'zh-TW' }).Count)
}
$VoicePrompted = $false
function Request-ZhSpeech {
  # 缺少中文語音辨識：詢問是否安裝（需要系統管理員權限；MSI 本身不需要）
  if ($script:VoicePrompted) { return }
  $script:VoicePrompted = $true
  $Text = "這台電腦沒有「中文（台灣）」語音辨識，語音指令需要它。`n`n要現在安裝嗎？會以系統管理員身分安裝 Windows 的中文語音辨識與中文朗讀（需要網路，約數分鐘）。`n安裝完成後語音指令會自動開始，不用重開小工具。"
  if ([System.Windows.MessageBox]::Show($Window, $Text, 'AI 額度小工具 · 語音指令', 'YesNo', 'Question') -ne 'Yes') {
    Show-VoiceText '語音：缺少中文語音辨識' 6
    return
  }
  $Script = "Add-WindowsCapability -Online -Name 'Language.Speech~~~zh-TW~0.0.1.0'; Add-WindowsCapability -Online -Name 'Language.TextToSpeech~~~zh-TW~0.0.1.0'; Write-Host ''; Write-Host '安裝完成，可以關閉這個視窗。'; Read-Host '按 Enter 關閉'"
  try {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$Script`""
    Show-VoiceText '語音：正在安裝中文語音…' 8
  } catch { Show-VoiceText '語音：已取消安裝' 6 }   # 使用者在 UAC 按了「否」
}

function Set-Voice([bool]$On) {
  $Voice.Enabled = $On
  try { Set-Content -LiteralPath $VoiceFile -Value ([int]$On) -Encoding ascii } catch {}
  if (-not $On) { Show-VoiceText '語音指令已關閉' 3; return }
  if (-not (Test-ZhRecognizer)) { Request-ZhSpeech; return }
  Show-VoiceText '語音指令：說「欸小工具」＋指令' 5
}

$VoiceItem = New-Object Windows.Controls.MenuItem
$VoiceItem.Header = '語音指令'
$VoiceItem.IsCheckable = $true
$VoiceItem.IsChecked = $VoiceOn
$VoiceItem.ToolTip = "說「欸小工具」再接指令（「欸」可省略）：`n打開／收起來／開儀表板／換成條狀・指針・數字`nClaude 還剩多少／Codex 額度／Antigravity 額度`n下一首／上一首／播放／暫停／大聲一點／小聲一點／靜音"
$VoiceItem.Add_Click({ Set-Voice $VoiceItem.IsChecked })
function Update-VoiceItem {
  $VoiceItem.IsChecked = $Voice.Enabled
  $VoiceItem.Header = switch ($Voice.Status) {
    'nomic' { '語音指令（沒有麥克風，接上後自動開始）' }
    'norecognizer' { '語音指令（缺少中文語音辨識）' }
    'listening' { '語音指令（聆聽中）' }
    default { '語音指令' }
  }
}

$LastVoiceStatus = ''
$VoiceTimer = New-Object Windows.Threading.DispatcherTimer
$VoiceTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$VoiceTimer.Add_Tick({
  $Speaking = $script:Synth -and $script:Synth.State -eq 'Speaking'
  if ($Voice.Speaking -and -not $Speaking) { $Voice.QuietUntil = (Get-Date).AddMilliseconds(800) }
  $Voice.Speaking = $Speaking
  $Item = $null
  while ($Voice.Queue.TryDequeue([ref]$Item)) { Invoke-VoiceCommand $Item[0] }
  # 狀態改變時提示一次
  if ($Voice.Status -ne $script:LastVoiceStatus) {
    $Was = $script:LastVoiceStatus
    $script:LastVoiceStatus = $Voice.Status
    if ($Voice.Enabled) {
      switch ($Voice.Status) {
        'nomic' { Show-VoiceText '語音：沒有麥克風，接上後自動開始' 5 }
        'norecognizer' { Request-ZhSpeech }
        'listening' { if ($Was -in 'nomic', 'norecognizer') { Show-VoiceText '語音指令已開始' 3 } }
      }
    }
  }
})
$VoiceTimer.Start()
$Window.Add_Closed({ $Voice.Enabled = $false; if ($script:Synth) { try { $script:Synth.Dispose() } catch {} } })

$Menu.Add_Opened({ Update-ShowMenu; Update-UpdateItem; Update-LoginItem; Update-VoiceItem })
foreach ($Item in $LoginItem, $CodexLoginItem, $UpdateItem, $Open, $StyleMenu, $EdgeMenu, $ShowMenu, $VoiceItem, $Corner, $Quit) { $Menu.Items.Add($Item) | Out-Null }
$Window.ContextMenu = $Menu

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromSeconds(1)
Add-Type -Namespace Win32 -Name ZOrder -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);'
$Timer.Add_Tick({
  Update-Widget
  # 別的「最上層」視窗（例如 Codex 頭像、釘選視窗）被點到時會蓋過來；每秒把自己推回最上層。
  # HWND_TOPMOST，NOMOVE|NOSIZE|NOACTIVATE：不搶焦點，正在打字的視窗不受影響
  [void][Win32.ZOrder]::SetWindowPos((New-Object Windows.Interop.WindowInteropHelper $Window).Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)
  # 再次點捷徑：展開並跳到最前面
  if ($ShowSignal.WaitOne(0)) { Set-Pinned $true; $Window.Activate() | Out-Null; return }
  # 螢幕配置會變（接投影、DeskIn 遠端切解析度）；被拖到已不存在的位置就拉回來
  # ponytail: 只檢查虛擬螢幕外框，多螢幕高度不一的空白角落不算出界
  if ($script:Dragged) {
    $CenterX = $Window.Left + $Window.ActualWidth / 2
    $CenterY = $Window.Top + $Window.ActualHeight / 2
    if ($CenterX -lt [Windows.SystemParameters]::VirtualScreenLeft -or
        $CenterX -gt [Windows.SystemParameters]::VirtualScreenLeft + [Windows.SystemParameters]::VirtualScreenWidth -or
        $CenterY -lt [Windows.SystemParameters]::VirtualScreenTop -or
        $CenterY -gt [Windows.SystemParameters]::VirtualScreenTop + [Windows.SystemParameters]::VirtualScreenHeight) { $script:Dragged = $false }
  }
  Move-ToCorner
})
$Timer.Start()
Apply-Edge
Update-Widget
Update-Handle

[void]$Window.ShowDialog()
[Environment]::Exit(0)

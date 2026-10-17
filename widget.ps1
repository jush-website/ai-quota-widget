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
        <ColumnDefinition Width="16"/>
        <ColumnDefinition/>
      </Grid.ColumnDefinitions>
      <Border Name="Handle" Background="#1AFFFFFF" CornerRadius="9,0,0,9" Cursor="Hand" ToolTip="收合／展開">
        <StackPanel VerticalAlignment="Center">
          <TextBlock Name="Arrow" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="#AAFFFFFF" HorizontalAlignment="Center"/>
          <StackPanel Name="Dots" Margin="0,6,0,0"/>
        </StackPanel>
      </Border>
      <StackPanel Grid.Column="1" Margin="10,10,12,10">
        <Grid Margin="0,0,0,6">
          <TextBlock Text="AI 額度 · 效能" Foreground="#99FFFFFF" FontSize="11"/>
          <TextBlock Name="Status" HorizontalAlignment="Right" Foreground="#99FFFFFF" FontSize="11"/>
        </Grid>
        <StackPanel Name="Rows"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@
$Window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $Xaml))
$Rows = $Window.FindName('Rows')
$Status = $Window.FindName('Status')
$Handle = $Window.FindName('Handle')
$Arrow = $Window.FindName('Arrow')
$Dots = $Window.FindName('Dots')
$Converter = New-Object Windows.Media.BrushConverter
$Invariant = [Globalization.CultureInfo]::InvariantCulture

# 樣式：bar 條狀、gauge 指針、text 純數字；存在資料夾內，下次沿用
$StyleFile = Join-Path $PSScriptRoot '.widget-style'
$Style = 'bar'
try { $Saved = (Get-Content -LiteralPath $StyleFile -Raw -ErrorAction Stop).Trim(); if ($Saved -in 'bar', 'gauge', 'text') { $Style = $Saved } } catch {}
# 內容寬 = 視窗寬 - 40（把手 16、邊距 22、邊框 2）：條狀軌道 106、指針 3 格 × 70
$StyleWidth = @{ bar = 284; gauge = 250; text = 184 }

$Brushes = @{}
function Get-Brush([string]$Color) {
  if (-not $Brushes.ContainsKey($Color)) { $B = $Converter.ConvertFrom($Color); $B.Freeze(); $Brushes[$Color] = $B }
  return $Brushes[$Color]
}

function Get-LevelColor($Percent) {
  if ($null -eq $Percent) { '#66FFFFFF' } elseif ($Percent -ge 85) { '#FF5C5C' } elseif ($Percent -ge 65) { '#FFB547' } else { '#4ADE80' }
}

function New-Text([string]$Text, [double]$Size, [string]$Color) {
  $Block = New-Object Windows.Controls.TextBlock
  $Block.Text = $Text; $Block.FontSize = $Size
  $Block.Foreground = Get-Brush $Color
  return $Block
}

# 元件只在項目清單或樣式改變時建立一次，之後每秒只改數值，避免整個重繪造成閃爍
function New-BarCell($Item, [bool]$Gap) {
  $Grid = New-Object Windows.Controls.Grid
  $Grid.Margin = New-Object Windows.Thickness(0, ($(if ($Gap) { 8 } else { 2 })), 0, 2)
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
  $Panel.Width = 70; $Panel.Margin = New-Object Windows.Thickness(0, 2, 0, 6)
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
  $Grid.Margin = New-Object Windows.Thickness(0, ($(if ($Gap) { 5 } else { 0 })), 0, 0)
  $Grid.Children.Add((New-Text $Item.Label 11 '#CCFFFFFF')) | Out-Null
  $Value = New-Text '' 11 '#66FFFFFF'
  $Value.HorizontalAlignment = 'Right'
  $Grid.Children.Add($Value) | Out-Null
  return @{ Root = $Grid; Value = $Value }
}

# 把手上的燈號：每個項目一顆，平常依序慢慢呼吸（波浪），到 85% 以上改成快閃
# ponytail: 透明視窗每格動畫都要整窗重繪，限 20fps 省 CPU；還嫌耗就改成只在收合時播放
function New-Dot([int]$Index) {
  $Dot = New-Object Windows.Shapes.Ellipse
  $Dot.Width = 6; $Dot.Height = 6; $Dot.Margin = New-Object Windows.Thickness(0, 2, 0, 2)
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
    $Alert = $Item.Percent -ge 85
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
      $Tip = if ($Limit.resetsAt) { '重置於 ' + ([datetime]$Limit.resetsAt).ToLocalTime().ToString('M/d HH:mm') } else { '' }
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
function Update-Widget {
  $Items = @(Get-Items)
  $Sig = $script:Style + '|' + (($Items | ForEach-Object { "$($_.Group)/$($_.Label)" }) -join ',')
  if ($Sig -ne $script:Signature) {
    $script:Signature = $Sig
    $Rows.Children.Clear()
    $Cells.Clear()
    $Previous = $null
    $Wrap = $null
    foreach ($Item in $Items) {
      $Gap = $null -ne $Previous -and $Item.Group -ne $Previous
      switch ($script:Style) {
        'gauge' {
          # 指針不分組，三個一列連續排（每格有文字標籤）
          if (-not $Wrap) { $Wrap = New-Object Windows.Controls.WrapPanel; $Rows.Children.Add($Wrap) | Out-Null }
          $Cell = New-GaugeCell $Item; $Wrap.Children.Add($Cell.Root) | Out-Null
        }
        'text' { $Cell = New-TextCell $Item $Gap; $Rows.Children.Add($Cell.Root) | Out-Null }
        default { $Cell = New-BarCell $Item $Gap; $Rows.Children.Add($Cell.Root) | Out-Null }
      }
      $Cell.Index = $Cells.Count
      $Cell.Dot = New-Dot $Cell.Index
      $Cell.Alert = $null
      if ($Cells.Count -eq 0) { $Dots.Children.Clear() }
      $Dots.Children.Add($Cell.Dot) | Out-Null
      $Cells.Add($Cell)
      $Previous = $Item.Group
    }
  }
  for ($I = 0; $I -lt $Items.Count; $I++) { Set-Cell $Cells[$I] $Items[$I] }
  if ($Window.Width -ne $StyleWidth[$script:Style]) { $Window.Width = $StyleWidth[$script:Style] }
  $Status.Text = if ($State.offline) { '服務離線' } else { (Get-Date).ToString('HH:mm') }
}

# 位置：展開時貼齊右下角；收合時滑到螢幕右緣，只露出左側把手
# 釘選＝固定展開；未釘選＝平常收合，滑鼠移過把手才滑出來。狀態存在資料夾內
$PinFile = Join-Path $PSScriptRoot '.widget-pinned'
$Pinned = $true
try { if ((Get-Content -LiteralPath $PinFile -Raw -ErrorAction Stop).Trim() -eq '0') { $Pinned = $false } } catch {}
$Dragged = $false
$Collapsed = -not $Pinned
# 把手可沿右緣上下拖；拖過的高度存在 .widget-top（DIP），沒拖過就貼底
$TopFile = Join-Path $PSScriptRoot '.widget-top'
$CustomTop = $null
try { $CustomTop = [double]::Parse((Get-Content -LiteralPath $TopFile -Raw -ErrorAction Stop).Trim(), [Globalization.CultureInfo]::InvariantCulture) } catch {}
function Get-Dock {
  $Area = [Windows.SystemParameters]::WorkArea
  # 未釘選的滑出預覽要貼齊螢幕右緣：游標停在把手上，滑出後仍在面板內，才不會一出來就判定離開又收回
  $Left = if ($script:Collapsed) { $Area.Right - 17 } elseif (-not $script:Pinned) { $Area.Right - $Window.ActualWidth } else { $Area.Right - $Window.ActualWidth - 12 }
  $Top = if ($null -ne $script:CustomTop) { [math]::Min([math]::Max($script:CustomTop, $Area.Top), $Area.Bottom - $Window.ActualHeight) } else { $Area.Bottom - $Window.ActualHeight - 12 }
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
$Drag = @{ Active = $false; Moved = $false; StartY = 0; Grab = 0 }
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
  # 收合：左箭頭；展開時顯示圖釘，亮＝已釘選、暗＝滑鼠移開就會收回
  $Arrow.Text = if ($script:Collapsed) { [string][char]0xE76B } else { [string][char]0xE718 }
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
# 把手：點一下切換釘選；按住上下拖超過 4px 則沿右緣移動
$Handle.Add_MouseLeftButtonDown({
  param($Sender, $E)
  $E.Handled = $true
  $Mouse = Get-MouseDip
  if (-not $Mouse) { return }
  $Slide['Top'] = 'drag'  # 讓進行中的上下動畫完成時不要蓋掉拖曳位置
  $Window.BeginAnimation([Windows.Window]::TopProperty, $null)
  $Drag.Active = $true; $Drag.Moved = $false; $Drag.StartY = $Mouse.Y; $Drag.Grab = $Mouse.Y - $Window.Top
  [void]$Handle.CaptureMouse()
})
$Handle.Add_MouseMove({
  if (-not $Drag.Active) { return }
  $Mouse = Get-MouseDip
  if (-not $Mouse) { return }
  if (-not $Drag.Moved -and [math]::Abs($Mouse.Y - $Drag.StartY) -lt 4) { return }
  $Drag.Moved = $true
  $Area = [Windows.SystemParameters]::WorkArea
  $script:CustomTop = [math]::Min([math]::Max($Mouse.Y - $Drag.Grab, $Area.Top), $Area.Bottom - $Window.ActualHeight)
  $Window.Top = $script:CustomTop
})
$Handle.Add_MouseLeftButtonUp({
  param($Sender, $E)
  if (-not $Drag.Active) { return }
  $E.Handled = $true
  $Drag.Active = $false
  $Handle.ReleaseMouseCapture()
  if ($Drag.Moved) {
    try { Set-Content -LiteralPath $TopFile -Value ($script:CustomTop.ToString([Globalization.CultureInfo]::InvariantCulture)) -Encoding ascii } catch {}
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
$Corner = New-Object Windows.Controls.MenuItem; $Corner.Header = '回到右下角'
$Corner.Add_Click({
  $script:CustomTop = $null
  if (Test-Path -LiteralPath $TopFile) { [IO.File]::Delete($TopFile) }
  Set-Pinned $true
})
$Quit = New-Object Windows.Controls.MenuItem; $Quit.Header = '關閉小工具'
$Quit.Add_Click({ $Window.Close() })
$StyleMenu = New-Object Windows.Controls.MenuItem; $StyleMenu.Header = '樣式'
foreach ($Option in @(@('bar', '條狀'), @('gauge', '指針'), @('text', '純數字'))) {
  $Choice = New-Object Windows.Controls.MenuItem
  $Choice.Header = $Option[1]; $Choice.Tag = $Option[0]; $Choice.IsChecked = ($Option[0] -eq $Style)
  $Choice.Add_Click({
    param($Sender)
    $script:Style = $Sender.Tag
    try { Set-Content -LiteralPath $StyleFile -Value $script:Style -Encoding ascii } catch {}
    foreach ($Other in $StyleMenu.Items) { $Other.IsChecked = ($Other.Tag -eq $script:Style) }
    Update-Widget
  })
  $StyleMenu.Items.Add($Choice) | Out-Null
}
$Menu.Items.Add($Open) | Out-Null; $Menu.Items.Add($StyleMenu) | Out-Null; $Menu.Items.Add($Corner) | Out-Null; $Menu.Items.Add($Quit) | Out-Null
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
Update-Widget
Update-Handle

[void]$Window.ShowDialog()
[Environment]::Exit(0)

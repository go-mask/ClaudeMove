# ClaudeMove GUI - 圖形介面外殼 (WinForms, 需要 PowerShell 7 / pwsh)
# 所有功能皆呼叫 src\ClaudeMove.psm1 引擎, 與 CLI 共用同一套已測試邏輯。
param(
    [switch]$SmokeTest,     # 煙霧測試: 建構介面並跑一次盤點後結束, 不顯示視窗
    [string]$Screenshot     # 開發用: 離螢幕渲染各分頁存成 PNG 到指定資料夾後結束
)

Set-StrictMode -Off
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try {
    Import-Module (Join-Path $PSScriptRoot 'src\ClaudeMove.psm1') -Force -ErrorAction Stop
} catch {
    [System.Windows.Forms.MessageBox]::Show("引擎載入失敗:`n$($_.Exception.Message)", 'ClaudeMove', 'OK', 'Error') | Out-Null
    exit 1
}
try { [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::SystemAware) | Out-Null } catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

# 以隱藏視窗方式啟動 (捷徑/VBS 的 Run ...,0) 時, 程序的第一個頂層視窗會繼承 SW_HIDE,
# 導致主視窗隱形。用 Win32 API 在表單顯示時強制取消隱藏。
$win32Def = @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
try { Add-Type -Name Win32Show -Namespace ClaudeMove -MemberDefinition $win32Def -ErrorAction Stop } catch {}
trap {
    [System.Windows.Forms.MessageBox]::Show("啟動失敗:`n$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)", 'ClaudeMove', 'OK', 'Error') | Out-Null
    exit 1
}

# ============================================================ 設計系統
$C = @{
    Bg        = [System.Drawing.Color]::FromArgb(245, 247, 250)
    Panel     = [System.Drawing.Color]::White
    Header    = [System.Drawing.Color]::FromArgb(17, 24, 39)
    HeaderSub = [System.Drawing.Color]::FromArgb(156, 163, 175)
    Primary   = [System.Drawing.Color]::FromArgb(37, 99, 235)
    PrimaryDk = [System.Drawing.Color]::FromArgb(29, 78, 216)
    Danger    = [System.Drawing.Color]::FromArgb(234, 88, 12)
    DangerDk  = [System.Drawing.Color]::FromArgb(194, 65, 12)
    Ghost     = [System.Drawing.Color]::FromArgb(229, 231, 235)
    GhostDk   = [System.Drawing.Color]::FromArgb(209, 213, 219)
    Text      = [System.Drawing.Color]::FromArgb(31, 41, 55)
    Subtle    = [System.Drawing.Color]::FromArgb(107, 114, 128)
    GridHead  = [System.Drawing.Color]::FromArgb(243, 244, 246)
    GridAlt   = [System.Drawing.Color]::FromArgb(249, 250, 251)
    GridLine  = [System.Drawing.Color]::FromArgb(229, 231, 235)
    LogBg     = [System.Drawing.Color]::FromArgb(17, 24, 39)
    LogFg     = [System.Drawing.Color]::FromArgb(209, 213, 219)
}
$FontUI   = [System.Drawing.Font]::new('Segoe UI', 9.75)
$FontBold = [System.Drawing.Font]::new('Segoe UI Semibold', 9.75)
$FontH1   = [System.Drawing.Font]::new('Segoe UI Semibold', 14)
$FontMono = [System.Drawing.Font]::new('Consolas', 9.25)

function New-Btn {
    param($Text, $X, $Y, $W = 130, $H = 32, [ValidateSet('primary','ghost','danger')]$Style = 'ghost')
    $b = [System.Windows.Forms.Button]::new()
    $b.Text = $Text; $b.Location = [System.Drawing.Point]::new($X, $Y); $b.Size = [System.Drawing.Size]::new($W, $H)
    $b.FlatStyle = 'Flat'; $b.Font = $FontBold; $b.Cursor = 'Hand'
    $b.FlatAppearance.BorderSize = 0
    switch ($Style) {
        'primary' { $b.BackColor = $C.Primary; $b.ForeColor = [System.Drawing.Color]::White; $b.FlatAppearance.MouseOverBackColor = $C.PrimaryDk }
        'danger'  { $b.BackColor = $C.Danger;  $b.ForeColor = [System.Drawing.Color]::White; $b.FlatAppearance.MouseOverBackColor = $C.DangerDk }
        'ghost'   { $b.BackColor = $C.Ghost;   $b.ForeColor = $C.Text;                        $b.FlatAppearance.MouseOverBackColor = $C.GhostDk }
    }
    $b.Tag = @{ Back = $b.BackColor; Fore = $b.ForeColor }   # 停用時變灰, 啟用時還原
    $b.Add_EnabledChanged({
        if ($this.Enabled) { $this.BackColor = $this.Tag.Back; $this.ForeColor = $this.Tag.Fore }
        else { $this.BackColor = $C.Ghost; $this.ForeColor = $C.Subtle }
    })
    return $b
}
function New-Lbl {
    param($Text, $X, $Y, [switch]$Subtle, [switch]$Bold)
    $l = [System.Windows.Forms.Label]::new()
    $l.Text = $Text; $l.Location = [System.Drawing.Point]::new($X, $Y); $l.AutoSize = $true
    $l.Font = $FontUI
    if ($Bold)   { $l.Font = $FontBold }
    if ($Subtle) { $l.ForeColor = $C.Subtle } else { $l.ForeColor = $C.Text }
    return $l
}
function New-Txt {
    param($X, $Y, $W, $Text = '')
    $t = [System.Windows.Forms.TextBox]::new()
    $t.Location = [System.Drawing.Point]::new($X, $Y); $t.Size = [System.Drawing.Size]::new($W, 27)
    $t.Font = $FontUI; $t.BorderStyle = 'FixedSingle'; $t.Text = $Text
    return $t
}
function New-LogBox {
    $tb = [System.Windows.Forms.TextBox]::new()
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'
    $tb.Font = $FontMono; $tb.BackColor = $C.LogBg; $tb.ForeColor = $C.LogFg; $tb.BorderStyle = 'None'
    return $tb
}
function Set-GridStyle {
    param([System.Windows.Forms.DataGridView]$G)
    $G.ReadOnly = $false; $G.AllowUserToAddRows = $false; $G.RowHeadersVisible = $false
    $G.AutoSizeColumnsMode = 'AllCells'; $G.BorderStyle = 'None'; $G.BackgroundColor = $C.Panel
    $G.GridColor = $C.GridLine; $G.CellBorderStyle = 'SingleHorizontal'
    $G.EnableHeadersVisualStyles = $false
    $G.ColumnHeadersDefaultCellStyle.BackColor = $C.GridHead
    $G.ColumnHeadersDefaultCellStyle.ForeColor = $C.Subtle
    $G.ColumnHeadersDefaultCellStyle.Font = $FontBold
    $G.ColumnHeadersBorderStyle = 'None'
    $G.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
    $G.DefaultCellStyle.Font = $FontUI
    $G.DefaultCellStyle.ForeColor = $C.Text
    $G.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
    $G.DefaultCellStyle.SelectionForeColor = $C.Text
    $G.DefaultCellStyle.Padding = [System.Windows.Forms.Padding]::new(2, 4, 2, 4)
    $G.AlternatingRowsDefaultCellStyle.BackColor = $C.GridAlt
    $G.RowTemplate.Height = [Math]::Max(30, $FontUI.Height + 14)   # 列高隨字型縮放
    $G.SelectionMode = 'FullRowSelect'; $G.MultiSelect = $false
}

# 呼叫引擎並把 Write-Host/警告/錯誤 都收進 GUI 日誌; 回傳引擎的資料物件
function Invoke-Engine {
    param([scriptblock]$Script, [System.Windows.Forms.TextBox]$LogBox)
    $objs = [System.Collections.Generic.List[object]]::new()
    $form.Cursor = 'WaitCursor'
    try {
        $all = & $Script 6>&1 3>&1 2>&1
        foreach ($x in @($all)) {
            if ($x -is [System.Management.Automation.InformationRecord] -or
                $x -is [System.Management.Automation.WarningRecord] -or
                $x -is [System.Management.Automation.ErrorRecord]) {
                if ($LogBox) { $LogBox.AppendText(([string]$x) + "`r`n") }
            } else { $objs.Add($x) }
        }
    } catch {
        if ($LogBox) { $LogBox.AppendText("錯誤: $($_.Exception.Message)`r`n") }
    } finally { $form.Cursor = 'Default' }
    if ($LogBox) { $LogBox.ScrollToCaret(); [System.Windows.Forms.Application]::DoEvents() }
    return $objs
}

# ============================================================ 主視窗
$ver = Get-ClaudeMoveVersion
$form = [System.Windows.Forms.Form]::new()
$form.Text = "ClaudeMove v$ver"
$form.Size = [System.Drawing.Size]::new(1010, 760)
$form.MinimumSize = [System.Drawing.Size]::new(900, 640)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C.Bg
$form.Font = $FontUI
try { $form.Icon = [System.Drawing.Icon]::new((Join-Path $PSScriptRoot 'claudemove.ico')) } catch {}

# --- 頁首橫幅 (高度依實際字高計算, 避免系統文字縮放時裁字) ---
$header = [System.Windows.Forms.Panel]::new()
$header.Dock = 'Top'; $header.BackColor = $C.Header
$hTitle = [System.Windows.Forms.Label]::new()
$hTitle.Text = 'ClaudeMove'; $hTitle.Font = $FontH1; $hTitle.ForeColor = [System.Drawing.Color]::White
$hTitle.Location = '18,8'; $hTitle.AutoSize = $true
$header.Controls.Add($hTitle)
$hSub = [System.Windows.Forms.Label]::new()
$hSub.Text = "Claude 資料備份・轉移・合併    v$ver  |  $env:COMPUTERNAME\$env:USERNAME"
$hSub.Font = $FontUI; $hSub.ForeColor = $C.HeaderSub
$hSub.AutoSize = $true
$hSub.Location = [System.Drawing.Point]::new(20, $hTitle.Top + $hTitle.PreferredHeight + 2)
$header.Controls.Add($hSub)
$header.Height = $hSub.Top + $hSub.PreferredHeight + 10

# --- 狀態列 ---
$status = [System.Windows.Forms.StatusStrip]::new()
$status.BackColor = $C.Ghost
$statusLbl = [System.Windows.Forms.ToolStripStatusLabel]::new()
$statusLbl.Text = '就緒'
[void]$status.Items.Add($statusLbl)

$tabs = [System.Windows.Forms.TabControl]::new()
$tabs.Dock = 'Fill'; $tabs.Font = $FontBold; $tabs.Padding = [System.Drawing.Point]::new(16, 9)

$form.Controls.Add($tabs)
$form.Controls.Add($header)
$form.Controls.Add($status)

function New-Tab { param($Text)
    $t = [System.Windows.Forms.TabPage]::new($Text)
    $t.BackColor = $C.Panel; $t.Padding = [System.Windows.Forms.Padding]::new(6)
    $tabs.TabPages.Add($t); return $t
}

# ============================================================ 分頁 1: 盤點
$tabInv = New-Tab '📊 盤點'
$btnScan = New-Btn '重新掃描本機' 12 12 140 32 'primary'
$tabInv.Controls.Add($btnScan)

$gridInv = [System.Windows.Forms.DataGridView]::new()
$gridInv.Location = '12,56'; $gridInv.Size = '960,430'; $gridInv.Anchor = 'Top,Left,Right,Bottom'
Set-GridStyle $gridInv; $gridInv.ReadOnly = $true
[void]$gridInv.Columns.Add('slug', '專案 (slug)')
[void]$gridInv.Columns.Add('path', '實體路徑')
[void]$gridInv.Columns.Add('exists', '路徑存在')
[void]$gridInv.Columns.Add('git', 'Git')
[void]$gridInv.Columns.Add('sessions', 'Sessions')
[void]$gridInv.Columns.Add('memory', '記憶')
[void]$gridInv.Columns.Add('size', '大小(MB)')
$tabInv.Controls.Add($gridInv)

$logInv = New-LogBox
$logInv.Location = '12,496'; $logInv.Size = '960,130'; $logInv.Anchor = 'Left,Right,Bottom'
$tabInv.Controls.Add($logInv)

# ============================================================ 分頁 2: 匯出
$tabExp = New-Tab '📦 匯出打包'
$tabExp.Controls.Add((New-Lbl '選擇專案:' 12 12 -Bold))
$clbProjects = [System.Windows.Forms.CheckedListBox]::new()
$clbProjects.Location = '12,36'; $clbProjects.Size = '450,235'; $clbProjects.CheckOnClick = $true
$clbProjects.Font = $FontUI; $clbProjects.BorderStyle = 'FixedSingle'
$tabExp.Controls.Add($clbProjects)

$chkAllSess = [System.Windows.Forms.CheckBox]::new()
$chkAllSess.Text = '打包所選專案的全部 session'; $chkAllSess.Checked = $true
$chkAllSess.Location = '480,10'; $chkAllSess.AutoSize = $true; $chkAllSess.Font = $FontBold
$tabExp.Controls.Add($chkAllSess)
$clbSessions = [System.Windows.Forms.CheckedListBox]::new()
$clbSessions.Location = '480,36'; $clbSessions.Size = '492,235'; $clbSessions.CheckOnClick = $true
$clbSessions.Enabled = $false; $clbSessions.HorizontalScrollbar = $true
$clbSessions.Font = $FontUI; $clbSessions.BorderStyle = 'FixedSingle'
$tabExp.Controls.Add($clbSessions)

$lblOut = New-Lbl '輸出檔案:' 12 288 -Bold
$tabExp.Controls.Add($lblOut)
$outX = $lblOut.Left + $lblOut.PreferredWidth + 10
$txtOut = New-Txt $outX 285 (720 - $outX)
$tabExp.Controls.Add($txtOut)
$btnBrowseOut = New-Btn '瀏覽...' 730 283 76 30
$tabExp.Controls.Add($btnBrowseOut)
$btnExport = New-Btn '匯出' 816 283 156 30 'primary'
$tabExp.Controls.Add($btnExport)

$logExp = New-LogBox
$logExp.Location = '12,326'; $logExp.Size = '960,300'; $logExp.Anchor = 'Top,Left,Right,Bottom'
$tabExp.Controls.Add($logExp)

# ============================================================ 分頁 3: 匯入
$tabImp = New-Tab '📥 匯入合併'
$lblPack = New-Lbl '遷移包:' 12 14 -Bold
$tabImp.Controls.Add($lblPack)
$packX = $lblPack.Left + $lblPack.PreferredWidth + 10
$txtPack = New-Txt $packX 11 (630 - $packX)
$tabImp.Controls.Add($txtPack)
$btnBrowsePack = New-Btn '瀏覽...' 640 9 76 30
$tabImp.Controls.Add($btnBrowsePack)
$btnAnalyze = New-Btn '分析與建議' 726 9 116 30 'primary'
$tabImp.Controls.Add($btnAnalyze)
$cmbMode = [System.Windows.Forms.ComboBox]::new()
$cmbMode.Location = '852,11'; $cmbMode.Size = '120,27'; $cmbMode.DropDownStyle = 'DropDownList'; $cmbMode.Font = $FontUI
[void]$cmbMode.Items.Add('Merge 合併'); [void]$cmbMode.Items.Add('Move 搬移')
$cmbMode.SelectedIndex = 0
$tabImp.Controls.Add($cmbMode)

$tabImp.Controls.Add((New-Lbl '路徑對映 (可直接編輯「對映到」欄, 勾選「採用」才生效):' 12 48 -Subtle))
$gridSug = [System.Windows.Forms.DataGridView]::new()
$gridSug.Location = '12,70'; $gridSug.Size = '960,150'; $gridSug.Anchor = 'Top,Left,Right'
Set-GridStyle $gridSug
$colUse = [System.Windows.Forms.DataGridViewCheckBoxColumn]::new(); $colUse.HeaderText = '採用'; $colUse.Name = 'use'; $colUse.Width = 48
[void]$gridSug.Columns.Add($colUse)
[void]$gridSug.Columns.Add('slug', '專案')
[void]$gridSug.Columns.Add('src', '原路徑')
[void]$gridSug.Columns.Add('status', '狀態')
[void]$gridSug.Columns.Add('to', '對映到')
[void]$gridSug.Columns.Add('reason', '依據')
$gridSug.Columns['slug'].ReadOnly = $true; $gridSug.Columns['src'].ReadOnly = $true
$gridSug.Columns['status'].ReadOnly = $true; $gridSug.Columns['reason'].ReadOnly = $true
$tabImp.Controls.Add($gridSug)

$btnDryRun = New-Btn '產生計畫 (Dry-run)' 12 230 160 32 'primary'
$tabImp.Controls.Add($btnDryRun)
$btnApplyImp = New-Btn '執行匯入' 182 230 150 32 'danger'
$btnApplyImp.Enabled = $false
$tabImp.Controls.Add($btnApplyImp)

$gridPlan = [System.Windows.Forms.DataGridView]::new()
$gridPlan.Location = '12,272'; $gridPlan.Size = '960,205'; $gridPlan.Anchor = 'Top,Left,Right'
Set-GridStyle $gridPlan; $gridPlan.ReadOnly = $true
[void]$gridPlan.Columns.Add('action', '動作')
[void]$gridPlan.Columns.Add('detail', '項目')
$tabImp.Controls.Add($gridPlan)

$logImp = New-LogBox
$logImp.Location = '12,486'; $logImp.Size = '960,140'; $logImp.Anchor = 'Left,Right,Bottom'
$tabImp.Controls.Add($logImp)

# ============================================================ 分頁 4: 網路傳輸
$tabNet = New-Tab '🌐 網路傳輸'
$grpSend = [System.Windows.Forms.GroupBox]::new(); $grpSend.Text = '傳送端 (在來源電腦執行)'
$grpSend.Location = '12,12'; $grpSend.Size = '960,120'; $grpSend.Font = $FontBold; $grpSend.ForeColor = $C.Text
$tabNet.Controls.Add($grpSend)
$txtSendPack = New-Txt 15 30 620
$txtSendPack.Font = $FontUI
$grpSend.Controls.Add($txtSendPack)
$btnBrowseSend = New-Btn '瀏覽...' 645 28 76 30
$grpSend.Controls.Add($btnBrowseSend)
$btnSend = New-Btn '開始傳送' 731 28 110 30 'primary'
$grpSend.Controls.Add($btnSend)
$lblSendHint = New-Lbl '按下後會顯示本機 IP 與 Token, 到另一台電腦的「接收端」輸入即可。首次使用請允許防火牆。' 15 70 -Subtle
$grpSend.Controls.Add($lblSendHint)

$grpRecv = [System.Windows.Forms.GroupBox]::new(); $grpRecv.Text = '接收端 (在目標電腦執行)'
$grpRecv.Location = '12,142'; $grpRecv.Size = '960,100'; $grpRecv.Font = $FontBold; $grpRecv.ForeColor = $C.Text
$tabNet.Controls.Add($grpRecv)
# 依實際字寬串接定位, 避免不同字型縮放下標籤壓到輸入框
$lblFrom = New-Lbl '來源 IP[:埠]:' 15 35
$grpRecv.Controls.Add($lblFrom)
$txtFrom = New-Txt ($lblFrom.Left + $lblFrom.PreferredWidth + 8) 32 150
$grpRecv.Controls.Add($txtFrom)
$lblTok = New-Lbl 'Token:' ($txtFrom.Right + 16) 35
$grpRecv.Controls.Add($lblTok)
$txtTok = New-Txt ($lblTok.Left + $lblTok.PreferredWidth + 8) 32 105
$grpRecv.Controls.Add($txtTok)
$lblSave = New-Lbl '存到:' ($txtTok.Right + 16) 35
$grpRecv.Controls.Add($lblSave)
$saveX = $lblSave.Left + $lblSave.PreferredWidth + 8
$txtSave = New-Txt $saveX 32 (725 - $saveX) (Join-Path $env:USERPROFILE 'Downloads')
$grpRecv.Controls.Add($txtSave)
$btnRecv = New-Btn '接收' 740 30 100 30 'primary'
$grpRecv.Controls.Add($btnRecv)

$logNet = New-LogBox
$logNet.Location = '12,252'; $logNet.Size = '960,374'; $logNet.Anchor = 'Top,Left,Right,Bottom'
$tabNet.Controls.Add($logNet)

# ============================================================ 分頁 5: 去重
$tabDed = New-Tab '🧹 slug 去重'
$btnDedScan = New-Btn '掃描重複群組' 12 12 140 32 'primary'
$tabDed.Controls.Add($btnDedScan)
$lblDedSrc = New-Lbl '舊路徑 (紀錄所指):' 12 60
$tabDed.Controls.Add($lblDedSrc)
$txtDedSrc = New-Txt ($lblDedSrc.Left + $lblDedSrc.PreferredWidth + 8) 57 300
$tabDed.Controls.Add($txtDedSrc)
$lblDedTo = New-Lbl '合併到 (現路徑):' ($txtDedSrc.Right + 16) 60
$tabDed.Controls.Add($lblDedTo)
$dedToX = $lblDedTo.Left + $lblDedTo.PreferredWidth + 8
$txtDedTo = New-Txt $dedToX 57 (826 - $dedToX)
$tabDed.Controls.Add($txtDedTo)
$btnDedDry = New-Btn 'Dry-run' 838 55 62 30
$tabDed.Controls.Add($btnDedDry)
$btnDedGo = New-Btn '執行' 906 55 66 30 'danger'
$tabDed.Controls.Add($btnDedGo)

$logDed = New-LogBox
$logDed.Location = '12,98'; $logDed.Size = '960,528'; $logDed.Anchor = 'Top,Left,Right,Bottom'
$tabDed.Controls.Add($logDed)

# ============================================================ 事件處理
$script:projItems = @()
$script:sessItems = @()

$refreshInventory = {
    $statusLbl.Text = '掃描中...'
    $logInv.Clear(); $gridInv.Rows.Clear(); $clbProjects.Items.Clear()
    $data = Invoke-Engine -Script { Get-ClaudeInventory } -LogBox $logInv
    $inv = $data | Select-Object -First 1
    if (-not $inv) { $logInv.AppendText("掃描失敗。`r`n"); $statusLbl.Text = '掃描失敗'; return }
    $script:projItems = @($inv.claudeCode.projects)
    foreach ($p in $script:projItems) {
        [void]$gridInv.Rows.Add($p.slug, $p.realPath, $p.pathExists, $p.isGitRepo, $p.sessionCount, $p.memoryCount, [math]::Round($p.sizeBytes / 1MB, 1))
        [void]$clbProjects.Items.Add(("{0}  ({1} sessions, {2:N1} MB)" -f $p.slug, $p.sessionCount, ($p.sizeBytes / 1MB)))
    }
    $logInv.AppendText(("完成: {0} 個專案。Claude Code: {1}" -f $script:projItems.Count, $inv.claudeCode.root) + "`r`n")
    $gridInv.ClearSelection()
    $statusLbl.Text = ("已盤點 {0} 個專案" -f $script:projItems.Count)
}
$btnScan.Add_Click($refreshInventory)

$refreshSessions = {
    $clbSessions.Items.Clear(); $script:sessItems = @()
    $slugs = @(); foreach ($i in $clbProjects.CheckedIndices) { $slugs += $script:projItems[$i].slug }
    if ($slugs.Count -eq 0) { return }
    $script:sessItems = @(Invoke-Engine -Script { Get-ClaudeSessionList -Projects $slugs }.GetNewClosure() -LogBox $logExp)
    foreach ($s in $script:sessItems) {
        [void]$clbSessions.Items.Add(("{0} | {1} | {2:N1} MB | {3}" -f $s.slug, $s.lastWrite, $s.sizeMB, $s.preview))
    }
}
$chkAllSess.Add_CheckedChanged({
    $clbSessions.Enabled = -not $chkAllSess.Checked
    if (-not $chkAllSess.Checked) { & $refreshSessions }
})
$clbProjects.Add_ItemCheck({
    if (-not $chkAllSess.Checked) { $form.BeginInvoke([Action]$refreshSessions) | Out-Null }
})

$btnBrowseOut.Add_Click({
    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Filter = '遷移包|*.claudepack.zip'; $dlg.FileName = 'mypack.claudepack.zip'
    if ($dlg.ShowDialog() -eq 'OK') { $txtOut.Text = $dlg.FileName }
})
$btnExport.Add_Click({
    $slugs = @(); foreach ($i in $clbProjects.CheckedIndices) { $slugs += $script:projItems[$i].slug }
    if ($slugs.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('請先勾選至少一個專案 (若清單為空, 先到「盤點」分頁掃描)。') | Out-Null; return }
    if (-not $txtOut.Text) { [System.Windows.Forms.MessageBox]::Show('請指定輸出檔案。') | Out-Null; return }
    $sessions = $null
    if (-not $chkAllSess.Checked) {
        $sessions = @(); foreach ($i in $clbSessions.CheckedIndices) { $sessions += $script:sessItems[$i].sessionId }
        if ($sessions.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('自選模式下請勾選至少一個 session。') | Out-Null; return }
    }
    $out = $txtOut.Text
    $statusLbl.Text = '匯出中...'
    $logExp.AppendText("匯出中...`r`n")
    if ($sessions) {
        Invoke-Engine -Script { Export-ClaudePack -OutputPath $out -Projects $slugs -Sessions $sessions }.GetNewClosure() -LogBox $logExp | Out-Null
    } else {
        Invoke-Engine -Script { Export-ClaudePack -OutputPath $out -Projects $slugs }.GetNewClosure() -LogBox $logExp | Out-Null
    }
    $statusLbl.Text = '匯出完成'
})

$btnBrowsePack.Add_Click({
    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Filter = '遷移包|*.zip|全部|*.*'
    if ($dlg.ShowDialog() -eq 'OK') { $txtPack.Text = $dlg.FileName }
})
$btnAnalyze.Add_Click({
    if (-not (Test-Path $txtPack.Text)) { [System.Windows.Forms.MessageBox]::Show('請先選擇有效的遷移包。') | Out-Null; return }
    $gridSug.Rows.Clear(); $statusLbl.Text = '分析中...'
    $logImp.AppendText("分析中 (掃描本機磁碟找對映建議)...`r`n")
    $pack = $txtPack.Text
    $sugs = @(Invoke-Engine -Script { Get-ClaudeMappingSuggestions -PackPath $pack }.GetNewClosure() -LogBox $logImp)
    foreach ($s in $sugs) {
        $use = ($s.status -eq 'suggested')
        $to = ''; if ($s.suggested) { $to = $s.suggested }
        [void]$gridSug.Rows.Add($use, $s.slug, $s.sourcePath, $s.status, $to, $s.reason)
    }
    $logImp.AppendText("分析完成, 請確認對映後按「產生計畫」。`r`n")
    $gridSug.ClearSelection()
    $btnApplyImp.Enabled = $false
    $statusLbl.Text = '分析完成'
})

$buildMapping = {
    $map = @{}
    foreach ($row in $gridSug.Rows) {
        if ($row.Cells['use'].Value -and $row.Cells['src'].Value -and $row.Cells['to'].Value) {
            $map[[string]$row.Cells['src'].Value] = [string]$row.Cells['to'].Value
        }
    }
    return $map
}
$getMode = { if ($cmbMode.SelectedIndex -eq 1) { 'Move' } else { 'Merge' } }
$btnDryRun.Add_Click({
    if (-not (Test-Path $txtPack.Text)) { [System.Windows.Forms.MessageBox]::Show('請先選擇有效的遷移包。') | Out-Null; return }
    $gridPlan.Rows.Clear()
    $pack = $txtPack.Text; $map = & $buildMapping; $mode = & $getMode
    $statusLbl.Text = '產生計畫中...'
    $logImp.AppendText("產生計畫中...`r`n")
    $plan = @(Invoke-Engine -Script {
        if ($map.Count -gt 0) { Import-ClaudePack -PackPath $pack -Mapping $map -Mode $mode } else { Import-ClaudePack -PackPath $pack -Mode $mode }
    }.GetNewClosure() -LogBox $logImp)
    foreach ($item in $plan) { [void]$gridPlan.Rows.Add($item.Action, $item.Detail) }
    $gridPlan.ClearSelection()
    if ($plan.Count -gt 0) { $btnApplyImp.Enabled = $true }
    $statusLbl.Text = 'Dry-run 完成, 未變更任何檔案'
})
$btnApplyImp.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show('確定執行匯入? 受影響的既有檔案會先自動備份。', 'ClaudeMove', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $pack = $txtPack.Text; $map = & $buildMapping; $mode = & $getMode
    $statusLbl.Text = '匯入中...'
    $logImp.AppendText("執行匯入中...`r`n")
    Invoke-Engine -Script {
        if ($map.Count -gt 0) { Import-ClaudePack -PackPath $pack -Mapping $map -Mode $mode -Apply } else { Import-ClaudePack -PackPath $pack -Mode $mode -Apply }
    }.GetNewClosure() -LogBox $logImp | Out-Null
    $logImp.AppendText("== 匯入流程結束, 建議重開 Claude Desktop 確認結果 ==`r`n")
    $statusLbl.Text = '匯入完成'
})

# --- 網路: 傳送用背景 job + Timer 更新日誌 ---
$script:sendJob = $null
$script:sendLogLen = 0
$sendTimer = [System.Windows.Forms.Timer]::new(); $sendTimer.Interval = 700
$sendTimer.Add_Tick({
    if (-not $script:sendJob) { $sendTimer.Stop(); return }
    $txt = (Receive-Job $script:sendJob -Keep 6>&1 3>&1 2>&1 | Out-String)
    if ($txt.Length -gt $script:sendLogLen) {
        $logNet.AppendText($txt.Substring($script:sendLogLen)); $script:sendLogLen = $txt.Length
    }
    if ($script:sendJob.State -in 'Completed', 'Failed', 'Stopped') {
        $sendTimer.Stop(); Remove-Job $script:sendJob -Force -ErrorAction SilentlyContinue
        $script:sendJob = $null; $btnSend.Enabled = $true; $btnSend.Text = '開始傳送'
        $statusLbl.Text = '傳送端已結束'
    }
})
$btnBrowseSend.Add_Click({
    $dlg = [System.Windows.Forms.OpenFileDialog]::new(); $dlg.Filter = '遷移包|*.zip|全部|*.*'
    if ($dlg.ShowDialog() -eq 'OK') { $txtSendPack.Text = $dlg.FileName }
})
$btnSend.Add_Click({
    if (-not (Test-Path $txtSendPack.Text)) { [System.Windows.Forms.MessageBox]::Show('請先選擇要傳送的遷移包。') | Out-Null; return }
    $mod = Join-Path $PSScriptRoot 'src\ClaudeMove.psm1'
    $script:sendLogLen = 0
    $script:sendJob = Start-Job -ScriptBlock {
        param($m, $p)
        Import-Module $m -Force
        Send-ClaudePack -PackPath $p -TimeoutSec 600
    } -ArgumentList $mod, $txtSendPack.Text
    $btnSend.Enabled = $false; $btnSend.Text = '等待中...'
    $logNet.AppendText("傳送端已啟動 (等待 10 分鐘)...`r`n")
    $statusLbl.Text = '等待接收端連入...'
    $sendTimer.Start()
})
$btnRecv.Add_Click({
    if (-not $txtFrom.Text -or -not $txtTok.Text) { [System.Windows.Forms.MessageBox]::Show('請輸入來源 IP 與 Token。') | Out-Null; return }
    $from = $txtFrom.Text; $tok = $txtTok.Text; $save = $txtSave.Text
    $statusLbl.Text = '接收中...'
    $logNet.AppendText("連線接收中...`r`n")
    $got = @(Invoke-Engine -Script { Receive-ClaudePack -From $from -Token $tok -OutputPath $save }.GetNewClosure() -LogBox $logNet)
    $f = $got | Select-Object -First 1
    if ($f) {
        $txtPack.Text = $f.FullName
        $logNet.AppendText("已自動填入「匯入合併」分頁, 可直接切換過去分析。`r`n")
        $statusLbl.Text = '接收完成'
    } else { $statusLbl.Text = '接收失敗' }
})

# --- 去重 ---
$btnDedScan.Add_Click({
    $logDed.Clear()
    Invoke-Engine -Script { Merge-ClaudeProjectSlugs } -LogBox $logDed | Out-Null
})
$btnDedDry.Add_Click({
    $src = $txtDedSrc.Text; $to = $txtDedTo.Text
    if (-not $src -or -not $to) { [System.Windows.Forms.MessageBox]::Show('請填舊路徑與合併目的路徑。') | Out-Null; return }
    Invoke-Engine -Script { Merge-ClaudeProjectSlugs -SourcePath $src -IntoPath $to }.GetNewClosure() -LogBox $logDed | Out-Null
})
$btnDedGo.Add_Click({
    $src = $txtDedSrc.Text; $to = $txtDedTo.Text
    if (-not $src -or -not $to) { [System.Windows.Forms.MessageBox]::Show('請填舊路徑與合併目的路徑。') | Out-Null; return }
    $r = [System.Windows.Forms.MessageBox]::Show("確定將指向`n$src`n的所有 slug 合併到`n$to ?`n(原資料夾會移入備份區)", 'ClaudeMove', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    Invoke-Engine -Script { Merge-ClaudeProjectSlugs -SourcePath $src -IntoPath $to -Apply }.GetNewClosure() -LogBox $logDed | Out-Null
})

# --- 關窗清理: 停掉背景傳送 job 與計時器 ---
$form.Add_FormClosing({
    $sendTimer.Stop()
    if ($script:sendJob) {
        Stop-Job $script:sendJob -ErrorAction SilentlyContinue
        Remove-Job $script:sendJob -Force -ErrorAction SilentlyContinue
        $script:sendJob = $null
    }
})

# ============================================================ DPI 自動縮放
# 版面以 96 DPI (100%) 設計; 在 125%/150% 縮放的螢幕上, WinForms 會依此把
# 所有座標與尺寸等比放大, 字體則由系統以點數自動縮放 — 兩者同步才不會裁字壓線。
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScaleDimensions = [System.Drawing.SizeF]::new(96, 96)

# ============================================================ 啟動
if ($Screenshot) {
    New-Item -ItemType Directory -Path $Screenshot -Force | Out-Null
    $form.StartPosition = 'Manual'
    $form.Location = [System.Drawing.Point]::new(-4000, -4000)   # 離螢幕渲染
    $form.Show(); [System.Windows.Forms.Application]::DoEvents()
    & $refreshInventory
    $i = 1
    foreach ($tp in $tabs.TabPages) {
        $tabs.SelectedTab = $tp; [System.Windows.Forms.Application]::DoEvents()
        $bmp = [System.Drawing.Bitmap]::new($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, [System.Drawing.Rectangle]::new(0, 0, $form.Width, $form.Height))
        $bmp.Save((Join-Path $Screenshot "tab$i.png")); $bmp.Dispose(); $i++
    }
    $form.Close(); $form.Dispose()
    Write-Output "SCREENSHOT-OK $($i - 1) 張已存至 $Screenshot"
} elseif ($SmokeTest) {
    & $refreshInventory
    Write-Output ("SMOKE-OK 控制項總數: " + $form.Controls.Count + ", 盤點列數: " + $gridInv.Rows.Count + ", 專案清單: " + $clbProjects.Items.Count + ", 分頁: " + $tabs.TabPages.Count)
    $form.Dispose()
} else {
    $form.Add_Shown({
        try {
            [ClaudeMove.Win32Show]::ShowWindow($form.Handle, 9) | Out-Null      # SW_RESTORE: 取消繼承的隱藏狀態
            [ClaudeMove.Win32Show]::SetForegroundWindow($form.Handle) | Out-Null
        } catch {}
        & $refreshInventory
    })
    [void]$form.ShowDialog()
}

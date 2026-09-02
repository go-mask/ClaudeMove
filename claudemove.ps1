# ClaudeMove CLI - Claude Desktop / Claude Code 備份、轉移、合併工具
#
# 用法:
#   .\claudemove.ps1 wizard                                     # 互動式精靈 (推薦新手)
#   .\claudemove.ps1 inventory [-OutFile inventory.json]
#   .\claudemove.ps1 sessions  [-Projects slug1,slug2]          # 列出 session 供自選打包挑選
#   .\claudemove.ps1 export  -OutputPath D:\backup\mypack [-Projects slug1,slug2] [-Sessions id1,id2]
#   .\claudemove.ps1 suggest -PackPath mypack.claudepack.zip [-OutFile map.json]   # 路徑對映建議
#   .\claudemove.ps1 import  -PackPath D:\backup\mypack.claudepack.zip [-MappingFile map.json] [-Mode Merge|Move] [-Apply]
#   .\claudemove.ps1 send    -PackPath mypack.claudepack.zip [-Port 17539]           # 區網傳送 (顯示 token)
#   .\claudemove.ps1 receive -From <ip>[:port] -Token <token> -OutputPath <路徑>     # 區網接收
#   .\claudemove.ps1 dedupe  [-SourcePath <舊路徑> -IntoPath <現路徑> -Apply]        # 跨 slug 去重
#
# import 預設為 dry-run, 只顯示計畫不動檔案; 確認後加 -Apply 執行。

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('wizard', 'inventory', 'sessions', 'export', 'suggest', 'import', 'send', 'receive', 'dedupe')]
    [string]$Command,

    # send / receive
    [int]$Port = 17539,
    [int]$TimeoutSec = 600,
    [string]$From,
    [string]$Token,

    # dedupe
    [string]$SourcePath,
    [string]$IntoPath,

    # wizard (測試/自動化用: 依序回答精靈提示)
    [string[]]$ScriptedAnswers,

    # inventory
    [string]$OutFile,

    # export
    [string]$OutputPath,
    [string[]]$Projects,
    [string[]]$Sessions,

    # import
    [string]$PackPath,
    [string]$MappingFile,
    [ValidateSet('Merge', 'Move')][string]$Mode = 'Merge',
    [string]$TargetUserProfile,
    [switch]$Apply,
    [switch]$NoBackup,

    # 共用 (測試/非標準安裝時覆寫)
    [string]$ClaudeDir,
    [string]$DesktopDir,
    [string]$TargetClaudeDir
)

Import-Module (Join-Path $PSScriptRoot 'src\ClaudeMove.psm1') -Force

switch ($Command) {
    'wizard' {
        $cmdArgs = @{}
        if ($ClaudeDir)       { $cmdArgs.ClaudeDir       = $ClaudeDir }
        if ($DesktopDir)      { $cmdArgs.DesktopDir      = $DesktopDir }
        if ($TargetClaudeDir) { $cmdArgs.TargetClaudeDir = $TargetClaudeDir }
        if ($ScriptedAnswers) { $cmdArgs.ScriptedAnswers = $ScriptedAnswers }
        Invoke-ClaudeMoveWizard @cmdArgs
    }
    'suggest' {
        if (-not $PackPath) { throw "suggest 需要 -PackPath" }
        $sugs = @(Get-ClaudeMappingSuggestions -PackPath $PackPath)
        Write-Host "`n=== 路徑對映建議 ===" -ForegroundColor Yellow
        $sugs | Format-Table slug, sourcePath, status, suggested, reason -AutoSize | Out-String -Width 220 | Write-Host
        if ($OutFile) {
            $map = [ordered]@{}
            foreach ($s in $sugs) { if ($s.status -eq 'suggested') { $map[$s.sourcePath] = $s.suggested } }
            $map | ConvertTo-Json | Set-Content $OutFile -Encoding utf8
            Write-Host "對映草稿已寫入 $OutFile (可手動編輯後用於 import -MappingFile)" -ForegroundColor Green
        }
    }
    'inventory' {
        $cmdArgs = @{}
        if ($ClaudeDir)  { $cmdArgs.ClaudeDir  = $ClaudeDir }
        if ($DesktopDir) { $cmdArgs.DesktopDir = $DesktopDir }
        if ($OutFile)    { $cmdArgs.OutFile    = $OutFile }
        $inv = Get-ClaudeInventory @cmdArgs

        Write-Host "`n=== Claude 資產盤點 ($($inv.machine.computerName)) ===" -ForegroundColor Yellow
        Write-Host ("Claude Code : {0}  (settings: {1}, history: {2})" -f $inv.claudeCode.root, $inv.claudeCode.hasSettings, $inv.claudeCode.hasHistory)
        Write-Host ("設定檔      : {0}  (MCP: {1} 個, 已登錄專案: {2} 個)" -f `
            $(if ($inv.claudeCode.hasConfig) { $inv.claudeCode.configFile } else { '(找不到 .claude.json)' }),
            @($inv.claudeCode.configMcpServers).Count, $inv.claudeCode.configProjectCount)
        Write-Host ("Desktop     : {0}  (MCP 伺服器: {1} 個, Desktop sessions: {2})" -f $inv.desktop.root, @($inv.desktop.mcpServers).Count, $inv.desktop.desktopSessionCount)
        if (@($inv.claudeCode.pluginMarketplaces).Count -gt 0) {
            Write-Host ("外掛市集    : {0}" -f (@($inv.claudeCode.pluginMarketplaces) -join ', '))
        }
        Write-Host "`n專案 (pathSource: config=設定檔權威 / cwd-slug=紀錄比對 / cwd-frequency=推測):" -ForegroundColor Cyan
        $inv.claudeCode.projects | Format-Table `
            @{n='slug'; e={ $_.slug }},
            @{n='realPath'; e={ $_.realPath }},
            @{n='src'; e={ $_.pathSource }},
            @{n='存在'; e={ if ($_.pathExists) { 'Y' } else { '-' } }},
            @{n='git'; e={ if ($_.isGitRepo) { 'Y' } else { '-' } }},
            @{n='sess'; e={ $_.sessionCount }},
            @{n='mem'; e={ $_.memoryCount }},
            @{n='MB'; e={ [math]::Round($_.sizeBytes / 1MB, 1) }} -AutoSize | Out-String -Width 200 | Write-Host
        $ms = @($inv.desktop.mcpServers | Where-Object machineSpecific)
        if ($ms.Count -gt 0) {
            Write-Host "含機器特定絕對路徑的 MCP 伺服器 (換機需調整):" -ForegroundColor Cyan
            $ms | ForEach-Object { Write-Host "  - $($_.name): $($_.absolutePathsUsed -join ', ')" }
        }
        foreach ($w in $inv.warnings) { Write-Warning $w }
    }
    'sessions' {
        $cmdArgs = @{}
        if ($ClaudeDir) { $cmdArgs.ClaudeDir = $ClaudeDir }
        if ($Projects)  { $cmdArgs.Projects  = $Projects }
        $list = Get-ClaudeSessionList @cmdArgs
        if (@($list).Count -eq 0) { Write-Host "沒有找到任何 session。"; break }
        Write-Host "`n=== Claude Code Sessions (自選打包: export -Sessions <sessionId>,...) ===" -ForegroundColor Yellow
        $list | Format-Table slug, sessionId, sizeMB, lastWrite, preview -AutoSize | Out-String -Width 200 | Write-Host
    }
    'export' {
        if (-not $OutputPath) { throw "export 需要 -OutputPath" }
        $cmdArgs = @{ OutputPath = $OutputPath }
        if ($Projects)   { $cmdArgs.Projects   = $Projects }
        if ($Sessions)   { $cmdArgs.Sessions   = $Sessions }
        if ($ClaudeDir)  { $cmdArgs.ClaudeDir  = $ClaudeDir }
        if ($DesktopDir) { $cmdArgs.DesktopDir = $DesktopDir }
        Export-ClaudePack @cmdArgs | Out-Null
    }
    'import' {
        if (-not $PackPath) { throw "import 需要 -PackPath" }
        $cmdArgs = @{ PackPath = $PackPath; Mode = $Mode }
        if ($MappingFile)       { $cmdArgs.MappingFile       = $MappingFile }
        if ($TargetClaudeDir)   { $cmdArgs.TargetClaudeDir   = $TargetClaudeDir }
        if ($TargetUserProfile) { $cmdArgs.TargetUserProfile = $TargetUserProfile }
        if ($Apply)           { $cmdArgs.Apply           = $true }
        if ($NoBackup)        { $cmdArgs.NoBackup        = $true }
        Import-ClaudePack @cmdArgs | Out-Null
    }
    'send' {
        if (-not $PackPath) { throw "send 需要 -PackPath" }
        Send-ClaudePack -PackPath $PackPath -Port $Port -TimeoutSec $TimeoutSec
    }
    'receive' {
        if (-not $From -or -not $Token -or -not $OutputPath) { throw "receive 需要 -From, -Token, -OutputPath" }
        Receive-ClaudePack -From $From -Token $Token -OutputPath $OutputPath | Out-Null
    }
    'dedupe' {
        $cmdArgs = @{}
        if ($ClaudeDir)  { $cmdArgs.ClaudeDir  = $ClaudeDir }
        if ($SourcePath) { $cmdArgs.SourcePath = $SourcePath }
        if ($IntoPath)   { $cmdArgs.IntoPath   = $IntoPath }
        if ($Apply)      { $cmdArgs.Apply      = $true }
        Merge-ClaudeProjectSlugs @cmdArgs | Out-Null
    }
}

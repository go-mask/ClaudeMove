# ClaudeMove - Claude Desktop / Claude Code 備份、轉移、合併引擎
# 架構: 探查(Inventory) -> 匯出(Export) -> 匯入/合併(Import)
# 安全原則: 匯出只讀不寫來源; 匯入預設 dry-run, -Apply 才動手, 動手前先備份受影響檔案。

Set-StrictMode -Version Latest

$script:ToolVersion       = '0.7.1'
$script:PackFormatVersion = 2

# session id = 標準 GUID; 用來辨識專案資料夾內屬於某個 session 的子目錄與檔案
$script:SessionIdPattern = '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

# 永不匯出的機密/快取黑名單 (相對 .claude 根目錄)
# sessions = 執行期 <pid>.key/<pid>.json 金鑰; plugins\marketplaces = 可重新下載的市集 clone
$script:HardExclude = @(
    '.credentials.json', 'cache', 'session-env', 'shell-snapshots',
    'downloads', 'backups', '.last-cleanup', 'mcp-needs-auth-cache.json',
    'sessions', 'claudemove'
)

# ~/.claude.json 只保留這些鍵 (白名單制): 其餘含 userID / machineID / oauthAccount
# 等身分與快取資料, 絕不可跨機複製。
$script:ConfigKeepKeys = @('mcpServers', 'projects')

#region 共用

function Get-ClaudeMoveVersion { return $script:ToolVersion }

function Get-ClaudeDefaultPaths {
    [pscustomobject]@{
        ClaudeDir  = Join-Path $env:USERPROFILE '.claude'
        DesktopDir = Join-Path $env:APPDATA 'Claude'
    }
}

function Get-ClaudeConfigFile {
    # 新版 Claude Code 的核心設定檔: 與 .claude 資料夾同層的 .claude.json
    param([Parameter(Mandatory)][string]$ClaudeDir)
    $parent = Split-Path $ClaudeDir -Parent
    if (-not $parent) { return $null }
    return (Join-Path $parent '.claude.json')
}

function Get-ClaudeConfigProjectMap {
    <#
    .SYNOPSIS
        從 ~/.claude.json 的 projects 清單建出 slug -> 實體路徑 對照表。
        專案資料夾名就是由這些路徑算出來的, 因此 slug 對得上即為權威解答。
    #>
    param([string]$ConfigFile)
    $map = @{}
    if (-not $ConfigFile -or -not (Test-Path $ConfigFile)) { return $map }
    try {
        $cfg = Get-Content $ConfigFile -Raw -Encoding utf8 | ConvertFrom-Json
        if ($cfg.PSObject.Properties['projects']) {
            foreach ($p in $cfg.projects.PSObject.Properties) {
                # .claude.json 內正斜線與反斜線混用, 統一正規化為 Windows 反斜線
                $norm = ($p.Name -replace '/', '\').TrimEnd('\')
                if ($norm) { $map[(ConvertTo-ClaudeSlug $norm)] = $norm }
            }
        }
    } catch { }
    return $map
}

function ConvertTo-ClaudeSlug {
    # Claude Code 將專案絕對路徑轉為資料夾名: 非英數字元一律變 '-'
    param([Parameter(Mandatory)][string]$Path)
    return ($Path -replace '[^A-Za-z0-9]', '-')
}

function Get-ProjectRealPath {
    <#
    .SYNOPSIS
        決定專案的實體路徑, 回傳 @{ path; source; ambiguous }。
    .NOTES
        新版 Claude Code 會在同一個 session 檔內寫入多個 cwd (續聊 / 跨目錄 / 子代理),
        所以舊版「取第一個 cwd」會取到別的專案的路徑, 進而在匯入時把紀錄併錯專案。
        可靠度由高到低:
          1. config        — ~/.claude.json 的 projects 清單 (資料夾名即由此算出)
          2. cwd-slug      — jsonl 內 slug 等於資料夾名的 cwd
          3. cwd-frequency — 出現最多次的 cwd (最後手段, 標記 ambiguous)
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [hashtable]$ConfigProjectMap
    )
    $slug = Split-Path $ProjectDir -Leaf

    if ($ConfigProjectMap -and $ConfigProjectMap.ContainsKey($slug)) {
        return [pscustomobject]@{ path = $ConfigProjectMap[$slug]; source = 'config'; ambiguous = $false }
    }

    $counts = @{}
    foreach ($f in (Get-ChildItem -Path $ProjectDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending)) {
        $reader = [System.IO.StreamReader]::new($f.FullName)
        try {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($line -match '"cwd":"((?:[^"\\]|\\.)*)"') {
                    $v = $Matches[1] -replace '\\\\', '\'
                    # slug 對得上資料夾名即為正解, 立刻回傳 (避免掃完大檔)
                    if ((ConvertTo-ClaudeSlug $v) -eq $slug) {
                        return [pscustomobject]@{ path = $v; source = 'cwd-slug'; ambiguous = $false }
                    }
                    if ($counts.ContainsKey($v)) { $counts[$v]++ } else { $counts[$v] = 1 }
                }
            }
        } finally { $reader.Dispose() }
    }
    if ($counts.Count -eq 0) { return $null }

    $best = ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    return [pscustomobject]@{ path = $best; source = 'cwd-frequency'; ambiguous = $true }
}

function Get-GitRemoteUrl {
    # 讀 .git\config 的第一個 remote url (不依賴 git 指令)
    param([Parameter(Mandatory)][string]$RepoPath)
    $cfg = Join-Path $RepoPath '.git\config'
    if (-not (Test-Path $cfg)) { return $null }
    foreach ($line in (Get-Content $cfg -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*url\s*=\s*(.+)$') { return $Matches[1].Trim() }
    }
    return $null
}

function Get-PackManifest {
    # 只從遷移包抽出 manifest.json, 不解壓全部
    param([Parameter(Mandatory)][string]$PackPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $PackPath).Path)
    try {
        $entry = $zip.GetEntry('manifest.json')
        if (-not $entry) { throw "遷移包缺少 manifest.json" }
        $sr = [System.IO.StreamReader]::new($entry.Open())
        try { return ($sr.ReadToEnd() | ConvertFrom-Json) } finally { $sr.Dispose() }
    } finally { $zip.Dispose() }
}

function Get-ClaudePluginMarketplaces {
    # 新版外掛體系: 列出已安裝的市集名稱 (市集本體可重新下載, 只需帶走清單)
    param([Parameter(Mandatory)][string]$ClaudeDir)
    $dir = Join-Path $ClaudeDir 'plugins\marketplaces'
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
}

function Get-SanitizedClaudeConfig {
    <#
    .SYNOPSIS
        讀 ~/.claude.json 並只保留可跨機攜帶的鍵 (白名單), 剔除 userID / machineID /
        oauthAccount 等身分與快取欄位。找不到檔案或無可留內容時回傳 $null。
    #>
    param([Parameter(Mandatory)][string]$ConfigFile)
    if (-not (Test-Path $ConfigFile)) { return $null }
    try { $cfg = Get-Content $ConfigFile -Raw -Encoding utf8 | ConvertFrom-Json } catch { return $null }
    $out = [ordered]@{}
    foreach ($k in $script:ConfigKeepKeys) {
        if ($cfg.PSObject.Properties[$k]) { $out[$k] = $cfg.$k }
    }
    if ($out.Count -eq 0) { return $null }
    return [pscustomobject]$out
}

# --- 機密遮蔽 ---------------------------------------------------------------
# 設定檔 (MCP 的 headers / env / args / url, settings.json 的 env ...) 常帶 API 金鑰與
# 權杖。遷移包可能放隨身碟或走區網明文傳輸, 所以這些值一律不進包, 改留佔位符,
# 由使用者在目標機重新填入。寧可多遮, 不可漏遮。
$script:RedactedMark     = '<REDACTED-BY-CLAUDEMOVE: 請在目標機重新填入>'
$script:SecretKeyCore    = '(?:token|secret|passw(?:or)?d|passwd|api[_-]?key|authorization|credential|bearer|cookie|private[_-]?key|access[_-]?key|session[_-]?key)'
$script:SecretKeyPattern = '(?i)' + $script:SecretKeyCore
$script:SecretArgPattern = '(?i)^(?<name>[\w\-]*' + $script:SecretKeyCore + '[\w\-]*)\s*(?<sep>[:=])\s*.+$'
$script:SecretContainers = @('headers', 'env')   # 這些物件之下的字串值全部遮蔽

function Protect-ClaudeUrl {
    # 遮蔽 URL 內嵌的帳密與機密查詢參數
    param([string]$Url)
    $u = $Url -replace '(://)[^/@\s]+:[^/@\s]+@', '$1<REDACTED>@'
    $u = [regex]::Replace($u, '(?i)([?&][^=&#]*(token|key|secret|sig|signature|auth|passw)[^=&#]*=)[^&#]+', '$1<REDACTED>')
    return $u
}

function Protect-ClaudeArgs {
    # 遮蔽命令列參數陣列內的機密 (就地修改), 回傳遮蔽數
    param([object[]]$ArgList)
    $n = 0
    $secretNext = $false
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $a = $ArgList[$i]
        if ($a -isnot [string]) { $secretNext = $false; continue }
        if ($secretNext) {
            $ArgList[$i] = $script:RedactedMark; $n++; $secretNext = $false; continue
        }
        if ($a -match '^(?i)(bearer|basic)\s+\S+') {
            $ArgList[$i] = $script:RedactedMark; $n++; continue
        }
        # name: value / name=value 形式 (含 --flag=value 與 "Authorization: Bearer x")
        if ($a -match $script:SecretArgPattern) {
            $ArgList[$i] = $Matches['name'] + $Matches['sep'] + $script:RedactedMark; $n++; continue
        }
        # 旗標後面的下一個參數是機密: --api-key X, --token X, -H / --header X
        if ($a -match '^-{1,2}[\w\-]+$' -and ($a -match $script:SecretKeyPattern -or $a -in '-H', '--header')) {
            $secretNext = $true
        }
    }
    return $n
}

function Protect-ClaudeSecrets {
    <#
    .SYNOPSIS
        遞迴遮蔽 JSON 物件內的機密值 (就地修改), 回傳遮蔽數。
    #>
    param($Node, [string]$ParentKey = '')
    $n = 0
    if ($null -eq $Node) { return 0 }
    if ($Node -is [pscustomobject]) {
        $forceAll = ($script:SecretContainers -contains $ParentKey)
        foreach ($p in @($Node.PSObject.Properties)) {
            $val = $p.Value
            if ($val -is [string]) {
                if ($val.Length -eq 0) { continue }
                if ($forceAll -or $p.Name -match $script:SecretKeyPattern) {
                    $p.Value = $script:RedactedMark; $n++
                } elseif ($p.Name -ieq 'url') {
                    $new = Protect-ClaudeUrl -Url $val
                    if ($new -cne $val) { $p.Value = $new; $n++ }
                }
            } elseif ($val -is [System.Array]) {
                if ($p.Name -ieq 'args') { $n += (Protect-ClaudeArgs -ArgList $val) }
                foreach ($el in $val) { $n += (Protect-ClaudeSecrets -Node $el -ParentKey $p.Name) }
            } elseif ($val -is [pscustomobject]) {
                $n += (Protect-ClaudeSecrets -Node $val -ParentKey $p.Name)
            }
        }
    } elseif ($Node -is [System.Array]) {
        foreach ($el in $Node) { $n += (Protect-ClaudeSecrets -Node $el -ParentKey $ParentKey) }
    }
    return $n
}

function Export-RedactedJson {
    <#
    .SYNOPSIS
        讀一個 JSON 設定檔, 遮蔽機密後寫到目的地; 回傳遮蔽數。
        解析失敗時「不輸出」(寧可缺檔也不把未檢查的原檔放進遷移包) 並回傳 -1。
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    try { $obj = Get-Content $Source -Raw -Encoding utf8 | ConvertFrom-Json } catch { return -1 }
    $count = Protect-ClaudeSecrets -Node $obj
    $dir = Split-Path $Destination -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj | ConvertTo-Json -Depth 30 | Set-Content $Destination -Encoding utf8
    return $count
}

function Get-RunningClaudeProcesses {
    @(Get-Process -Name 'claude', 'Claude' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ProcessName -Unique)
}

function Write-Plan {
    param([array]$Plan)
    $groups = $Plan | Group-Object Action | Sort-Object Name
    foreach ($g in $groups) {
        Write-Host ("  {0,-14} x {1}" -f $g.Name, $g.Count) -ForegroundColor Cyan
    }
    foreach ($item in $Plan) {
        Write-Host ("  [{0}] {1}" -f $item.Action, $item.Detail)
    }
}

#endregion

#region 探查層

function Get-ClaudeInventory {
    <#
    .SYNOPSIS
        唯讀掃描本機 Claude Code / Claude Desktop 資產, 產出盤點清單。
    #>
    [CmdletBinding()]
    param(
        [string]$ClaudeDir,
        [string]$DesktopDir,
        [string]$OutFile
    )
    $defaults = Get-ClaudeDefaultPaths
    if (-not $ClaudeDir)  { $ClaudeDir  = $defaults.ClaudeDir }
    if (-not $DesktopDir) { $DesktopDir = $defaults.DesktopDir }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $running = @(Get-RunningClaudeProcesses)
    if ($running.Count -gt 0) {
        $warnings.Add("偵測到執行中的 Claude 程序 ($($running -join ', ')) — 匯出/匯入前建議關閉, 避免複製到寫入中的檔案。")
    }

    # --- Claude Code (~/.claude 與同層的 .claude.json) ---
    $configFile = Get-ClaudeConfigFile -ClaudeDir $ClaudeDir
    $configMap  = Get-ClaudeConfigProjectMap -ConfigFile $configFile
    $configMcp  = @()
    if ($configFile -and (Test-Path $configFile)) {
        try {
            $cfgJson = Get-Content $configFile -Raw -Encoding utf8 | ConvertFrom-Json
            if ($cfgJson.PSObject.Properties['mcpServers']) {
                $configMcp = @($cfgJson.mcpServers.PSObject.Properties.Name)
            }
        } catch { $warnings.Add(".claude.json 解析失敗: $($_.Exception.Message)") }
    } else {
        $warnings.Add("找不到 .claude.json (新版 Claude Code 的核心設定檔), 路徑反推將只依賴 session 紀錄。")
    }

    $projects = [System.Collections.Generic.List[object]]::new()
    $projectsRoot = Join-Path $ClaudeDir 'projects'
    if (Test-Path $projectsRoot) {
        foreach ($dir in (Get-ChildItem $projectsRoot -Directory)) {
            $resolved = Get-ProjectRealPath -ProjectDir $dir.FullName -ConfigProjectMap $configMap
            $realPath   = $null
            $pathSource = 'none'
            if ($resolved) { $realPath = $resolved.path; $pathSource = $resolved.source }
            if (-not $realPath) {
                $warnings.Add("專案 $($dir.Name) 無法反推實體路徑 (.claude.json 與 session 紀錄皆無), 合併時不做路徑改寫。")
            } elseif ($resolved.ambiguous) {
                $warnings.Add("專案 $($dir.Name) 的紀錄含多個不同 cwd 且無一與資料夾名相符, 已取出現最多者 ($realPath) — 匯入前請於計畫中確認。")
            }
            $sessions = @(Get-ChildItem $dir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
            $memDir = Join-Path $dir.FullName 'memory'
            $memFiles = @()
            if (Test-Path $memDir) { $memFiles = @(Get-ChildItem $memDir -File -Recurse) }
            $allFiles = @(Get-ChildItem $dir.FullName -File -Recurse -ErrorAction SilentlyContinue)
            $pathExists = $false
            $isGitRepo  = $false
            $gitRemote  = $null
            if ($realPath) {
                $pathExists = Test-Path $realPath
                $isGitRepo  = Test-Path (Join-Path $realPath '.git')
                if ($isGitRepo) { $gitRemote = Get-GitRemoteUrl -RepoPath $realPath }
            }
            $lastActivity = $null
            if ($sessions.Count -gt 0) {
                $lastActivity = ($sessions | Sort-Object LastWriteTime -Descending)[0].LastWriteTime.ToString('o')
            }
            $projects.Add([pscustomobject]@{
                slug         = $dir.Name
                realPath     = $realPath
                pathSource   = $pathSource
                pathExists   = $pathExists
                isGitRepo    = $isGitRepo
                gitRemote    = $gitRemote
                sessionCount = $sessions.Count
                memoryCount  = $memFiles.Count
                sizeBytes    = ($allFiles | Measure-Object Length -Sum).Sum
                lastActivity = $lastActivity
            })
        }
    }

    # --- Claude Desktop (%APPDATA%\Claude) ---
    $mcpServers = [System.Collections.Generic.List[object]]::new()
    $desktopConfigPath = Join-Path $DesktopDir 'claude_desktop_config.json'
    if (Test-Path $desktopConfigPath) {
        try {
            $cfg = Get-Content $desktopConfigPath -Raw | ConvertFrom-Json
            if ($cfg.PSObject.Properties['mcpServers']) {
                foreach ($p in $cfg.mcpServers.PSObject.Properties) {
                    $cmd = [string]$p.Value.command
                    $srvArgs = @(); if ($p.Value.PSObject.Properties['args']) { $srvArgs = @($p.Value.args) }
                    $absPaths = @(@($cmd) + $srvArgs | Where-Object { $_ -match '^[A-Za-z]:[\\/]' })
                    $mcpServers.Add([pscustomobject]@{
                        name              = $p.Name
                        command           = $cmd
                        machineSpecific   = ($absPaths.Count -gt 0)
                        absolutePathsUsed = $absPaths
                    })
                }
            }
        } catch { $warnings.Add("claude_desktop_config.json 解析失敗: $($_.Exception.Message)") }
    }
    $desktopSessionsDir = Join-Path $DesktopDir 'claude-code-sessions'
    $desktopSessionCount = if (Test-Path $desktopSessionsDir) { @(Get-ChildItem $desktopSessionsDir -Directory).Count } else { 0 }

    $inv = [pscustomobject]@{
        formatVersion = $script:PackFormatVersion
        toolVersion   = $script:ToolVersion
        scannedAt     = (Get-Date).ToString('o')
        machine       = [pscustomobject]@{
            computerName = $env:COMPUTERNAME
            userName     = $env:USERNAME
            userProfile  = $env:USERPROFILE
            os           = [System.Environment]::OSVersion.VersionString
        }
        claudeCode = [pscustomobject]@{
            root               = $ClaudeDir
            exists             = (Test-Path $ClaudeDir)
            hasSettings        = (Test-Path (Join-Path $ClaudeDir 'settings.json'))
            hasHistory         = (Test-Path (Join-Path $ClaudeDir 'history.jsonl'))
            configFile         = $configFile
            hasConfig          = ($configFile -and (Test-Path $configFile))
            configMcpServers   = $configMcp
            configProjectCount = $configMap.Count
            pluginMarketplaces = @(Get-ClaudePluginMarketplaces -ClaudeDir $ClaudeDir)
            projects           = $projects
        }
        desktop = [pscustomobject]@{
            root                = $DesktopDir
            exists              = (Test-Path $DesktopDir)
            hasConfig           = (Test-Path $desktopConfigPath)
            mcpServers          = $mcpServers
            desktopSessionCount = $desktopSessionCount
        }
        warnings = $warnings
    }

    if ($OutFile) {
        $inv | ConvertTo-Json -Depth 10 | Set-Content -Path $OutFile -Encoding utf8
        Write-Verbose "inventory 已寫入 $OutFile"
    }
    return $inv
}

function Get-SessionPreview {
    # 從 session jsonl 取第一則使用者訊息的前段文字, 讓人能辨識這個 session 在談什麼
    param([Parameter(Mandatory)][string]$FilePath, [int]$MaxLength = 50)
    $reader = [System.IO.StreamReader]::new($FilePath)
    try {
        $n = 0
        while (-not $reader.EndOfStream -and $n -lt 100) {
            $line = $reader.ReadLine(); $n++
            if ($line -notmatch '"type":"user"' -and $line -notmatch '"operation":"enqueue"') { continue }
            $text = $null
            if ($line -match '"content":"((?:[^"\\]|\\.)*)"') { $text = $Matches[1] }
            elseif ($line -match '"text":"((?:[^"\\]|\\.)*)"') { $text = $Matches[1] }
            if ($text) {
                $text = $text -replace '\\n', ' ' -replace '\\"', '"' -replace '\\\\', '\'
                if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) + '…' }
                return $text
            }
        }
    } finally { $reader.Dispose() }
    return ''
}

function Get-ClaudeSessionList {
    <#
    .SYNOPSIS
        列出各專案的 Claude Code session (含內容預覽), 供自選打包時挑選。
    #>
    [CmdletBinding()]
    param(
        [string]$ClaudeDir,
        [string[]]$Projects
    )
    if (-not $ClaudeDir) { $ClaudeDir = (Get-ClaudeDefaultPaths).ClaudeDir }
    $projectsRoot = Join-Path $ClaudeDir 'projects'
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path $projectsRoot)) { return $result }
    foreach ($dir in (Get-ChildItem $projectsRoot -Directory)) {
        if ($Projects -and $Projects -notcontains $dir.Name) { continue }
        foreach ($f in (Get-ChildItem $dir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            $result.Add([pscustomobject]@{
                slug      = $dir.Name
                sessionId = $f.BaseName
                sizeMB    = [math]::Round($f.Length / 1MB, 2)
                lastWrite = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                preview   = (Get-SessionPreview -FilePath $f.FullName)
            })
        }
    }
    return $result
}

#endregion

#region 匯出層

function Export-ClaudePack {
    <#
    .SYNOPSIS
        將本機 Claude 資產打包為可攜遷移包 (.claudepack.zip)。只讀取來源, 不寫入任何來源檔案。
    .PARAMETER Projects
        要打包的專案 slug 清單, 省略 = 全部。
    .PARAMETER Sessions
        要打包的 session id 清單 (jsonl 檔名, 可含或不含副檔名), 省略 = 選定專案的全部 session。
        指定時只打包含有所選 session 的專案 (該專案的記憶 memory 一併帶上)。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [string[]]$Projects,
        [string[]]$Sessions,
        [string]$ClaudeDir,
        [string]$DesktopDir
    )
    $defaults = Get-ClaudeDefaultPaths
    if (-not $ClaudeDir)  { $ClaudeDir  = $defaults.ClaudeDir }
    if (-not $DesktopDir) { $DesktopDir = $defaults.DesktopDir }
    if (-not (Test-Path $ClaudeDir)) { throw "找不到 Claude Code 資料夾: $ClaudeDir" }

    $inv = Get-ClaudeInventory -ClaudeDir $ClaudeDir -DesktopDir $DesktopDir
    foreach ($w in $inv.warnings) { Write-Warning $w }

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("claudemove-export-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        # 1. 專案 session + 記憶 (指定 -Sessions 時只打包所選 session, 記憶一併帶上)
        $sessionSet = $null
        if ($Sessions) {
            $sessionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($s in $Sessions) { [void]$sessionSet.Add(($s -replace '\.jsonl$', '')) }
        }
        $selected = @($inv.claudeCode.projects | Where-Object { -not $Projects -or $Projects -contains $_.slug })
        if ($sessionSet) {
            $selected = @($selected | Where-Object {
                $projDir = Join-Path (Join-Path $ClaudeDir 'projects') $_.slug
                @(Get-ChildItem $projDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                    Where-Object { $sessionSet.Contains($_.BaseName) }).Count -gt 0
            })
        }
        if ($selected.Count -eq 0) { throw "沒有符合的專案可匯出。" }
        $estStage = ($selected | Measure-Object sizeBytes -Sum).Sum
        $stageRoot = [System.IO.Path]::GetPathRoot($staging)
        $stageFree = ([System.IO.DriveInfo]::new($stageRoot)).AvailableFreeSpace
        if ($stageFree -lt ($estStage + 200MB)) {
            throw ("暫存磁碟 {0} 空間不足 (需約 {1:N0} MB, 剩 {2:N0} MB)。可清理磁碟或縮小打包範圍。" -f $stageRoot, (($estStage + 200MB) / 1MB), ($stageFree / 1MB))
        }
        $exportedSessions = [System.Collections.Generic.List[string]]::new()
        foreach ($proj in $selected) {
            $src = Join-Path (Join-Path $ClaudeDir 'projects') $proj.slug
            $dst = Join-Path $staging "claude\projects\$($proj.slug)"
            Copy-Item -Path $src -Destination $dst -Recurse -Force
            # 以下剔除都只動暫存區, 不動來源
            # (a) Desktop 的刪除標記 <sid>.desktop-released.json 是本機狀態, 不跨機
            foreach ($f in (Get-ChildItem $dst -Filter '*.desktop-released.json' -File -Recurse)) {
                Remove-Item -LiteralPath $f.FullName -Force
            }
            # (b) 自選模式: 未選 session 的 jsonl 與其附屬資料一併剔除。
            #     新版把 session 附屬資料放在 <專案>\<sessionId>\ (自訂標題, tool-results 的
            #     截圖 / PDF ...), 只刪 jsonl 會把沒選的對話素材夾帶出去。
            if ($sessionSet) {
                foreach ($d in (Get-ChildItem $dst -Directory)) {
                    if ($d.Name -match $script:SessionIdPattern -and -not $sessionSet.Contains($d.Name)) {
                        Remove-Item -LiteralPath $d.FullName -Recurse -Force
                    }
                }
                foreach ($f in (Get-ChildItem $dst -File)) {
                    # 檔名以 session id 開頭者 (<sid>.jsonl, <sid>.xxx.json ...) 視為該 session 所有
                    $sid = ($f.Name -split '\.', 2)[0]
                    if ($sid -match $script:SessionIdPattern -and -not $sessionSet.Contains($sid)) {
                        Remove-Item -LiteralPath $f.FullName -Force
                    }
                }
            }
            foreach ($f in (Get-ChildItem $dst -Filter '*.jsonl' -File)) { $exportedSessions.Add($f.BaseName) }
        }
        if ($sessionSet) {
            $notFound = @($Sessions | ForEach-Object { $_ -replace '\.jsonl$', '' } | Where-Object { $exportedSessions -notcontains $_ })
            foreach ($nf in $notFound) { Write-Warning "找不到 session: $nf (未包含在遷移包中)" }
        }

        # 2. 全域檔案 (白名單)
        $redacted = 0   # 被遮蔽的機密值總數 (API 金鑰 / 權杖不進遷移包)
        $histSrc = Join-Path $ClaudeDir 'history.jsonl'
        if (Test-Path $histSrc) { Copy-Item $histSrc -Destination (Join-Path $staging 'claude\history.jsonl') -Force }
        $setSrc = Join-Path $ClaudeDir 'settings.json'
        if (Test-Path $setSrc) {
            $r = Export-RedactedJson -Source $setSrc -Destination (Join-Path $staging 'claude\settings.json')
            if ($r -lt 0) { Write-Warning "settings.json 無法解析, 為避免夾帶未檢查的機密, 未放入遷移包。" } else { $redacted += $r }
        }

        # 3. ~/.claude.json 的可攜部分 (mcpServers + 每專案工具授權/信任狀態)
        #    白名單過濾, 絕不含 userID / machineID / oauthAccount; MCP 的 headers / env 等
        #    機密值遮蔽為佔位符; 匯入時只進待審閱區。
        $configFile = Get-ClaudeConfigFile -ClaudeDir $ClaudeDir
        if ($configFile -and (Test-Path $configFile)) {
            $sanitized = Get-SanitizedClaudeConfig -ConfigFile $configFile
            if ($sanitized) {
                $redacted += (Protect-ClaudeSecrets -Node $sanitized)
                $sanitized | ConvertTo-Json -Depth 30 |
                    Set-Content (Join-Path $staging 'claude\claude.json.portable') -Encoding utf8
            }
        }

        # 4. 外掛市集清單 (市集本體可重新下載, 只帶清單)
        $mkts = @(Get-ClaudePluginMarketplaces -ClaudeDir $ClaudeDir)
        $knownMkt = Join-Path $ClaudeDir 'plugins\known_marketplaces.json'
        if ($mkts.Count -gt 0 -or (Test-Path $knownMkt)) {
            $mktInfo = [ordered]@{ marketplaces = $mkts }
            if (Test-Path $knownMkt) {
                try { $mktInfo['known'] = (Get-Content $knownMkt -Raw -Encoding utf8 | ConvertFrom-Json) } catch { }
            }
            [pscustomobject]$mktInfo | ConvertTo-Json -Depth 12 |
                Set-Content (Join-Path $staging 'claude\plugins.marketplaces.json') -Encoding utf8
        }

        # 5. Desktop MCP 設定 (僅供目標機審閱, 匯入時不自動套用)
        $desktopCfg = Join-Path $DesktopDir 'claude_desktop_config.json'
        if (Test-Path $desktopCfg) {
            $r = Export-RedactedJson -Source $desktopCfg -Destination (Join-Path $staging 'desktop\claude_desktop_config.json')
            if ($r -lt 0) { Write-Warning "claude_desktop_config.json 無法解析, 為避免夾帶未檢查的機密, 未放入遷移包。" } else { $redacted += $r }
        }

        # 6. 黑名單保險: 從暫存區移除任何漏網的機密/快取
        foreach ($ex in $script:HardExclude) {
            $p = Join-Path $staging "claude\$ex"
            if (Test-Path $p) { Remove-Item $p -Recurse -Force }
        }

        # 7. manifest + inventory
        $inv | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $staging 'inventory.json') -Encoding utf8
        $sessionFilter = $null
        if ($sessionSet) { $sessionFilter = @($exportedSessions) }
        [pscustomobject]@{
            packFormatVersion = $script:PackFormatVersion
            toolVersion       = $script:ToolVersion
            createdAt         = (Get-Date).ToString('o')
            sourceMachine     = $inv.machine
            projects          = @($selected | ForEach-Object { [pscustomobject]@{ slug = $_.slug; realPath = $_.realPath; pathSource = $_.pathSource; gitRemote = $_.gitRemote } })
            sessionFilter     = $sessionFilter   # null = 全部 session
            redactedSecrets   = $redacted        # 設定檔中被遮蔽的機密值數量, 需在目標機重新填入
            excluded          = $script:HardExclude
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $staging 'manifest.json') -Encoding utf8

        # 6. 壓縮 (前置: 輸出磁碟空間預警, 壓縮後通常遠小於原始大小)
        if (-not $OutputPath.EndsWith('.zip')) { $OutputPath = "$OutputPath.claudepack.zip" }
        $estBytes = ($selected | Measure-Object sizeBytes -Sum).Sum
        $outRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($OutputPath))
        $outFree = ([System.IO.DriveInfo]::new($outRoot)).AvailableFreeSpace
        if ($outFree -lt $estBytes) {
            Write-Warning ("輸出磁碟 {0} 剩餘 {1:N0} MB, 低於資料原始大小 {2:N0} MB, 壓縮後可能仍不足。" -f $outRoot, ($outFree / 1MB), ($estBytes / 1MB))
        }
        $outDir = Split-Path $OutputPath -Parent
        if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutputPath -CompressionLevel Optimal

        $size = (Get-Item $OutputPath).Length
        Write-Host ("匯出完成: {0} ({1:N1} MB, {2} 個專案, {3} 個 session)" -f $OutputPath, ($size / 1MB), $selected.Count, $exportedSessions.Count) -ForegroundColor Green
        if ($redacted -gt 0) {
            Write-Host ("已遮蔽設定檔中的 {0} 個機密值 (API 金鑰 / 權杖不進遷移包, 請在目標機重新填入)。" -f $redacted) -ForegroundColor Yellow
        }
        return Get-Item $OutputPath
    }
    finally {
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region 匯入/合併層

function Get-PathRewriteVariants {
    # 產生 jsonl 內可能出現的路徑寫法 (JSON 轉義反斜線 / 正斜線 / 原樣)
    # 注意順序: 先取代雙反斜線 (JSON 轉義) 再取代原樣, 避免原樣規則吃掉轉義形式的一半
    param([string]$Old, [string]$New)
    @(
        @{ From = $Old.Replace('\', '\\'); To = $New.Replace('\', '\\') }  # "E:\\x" JSON 轉義
        @{ From = $Old.Replace('\', '/');  To = $New.Replace('\', '/') }   # E:/x
        @{ From = $Old;                    To = $New }                     # E:\x 原樣
    )
}

function New-SlugRewritePair {
    # 紀錄會以絕對路徑引用自己的資料夾 (...\.claude\projects\<slug>\<sid>\tool-results\...,
    # 記憶目錄等)。專案換路徑後 slug 跟著變, 這些引用要一起改, 否則指向不存在的位置。
    param([Parameter(Mandatory)][string]$OldSlug, [Parameter(Mandatory)][string]$NewSlug)
    return @{ Old = ".claude\projects\$OldSlug"; New = ".claude\projects\$NewSlug"; Kind = 'slug' }
}

function Invoke-PathRewrite {
    <#
    .SYNOPSIS
        對文字套用一組路徑改寫規則 (每條規則含 JSON 轉義 / 正斜線 / 原樣三種寫法)。
    .NOTES
        Kind='slug' 的規則要求後面不能再接 slug 字元 (英數或 '-'), 避免
        F--AI 誤傷 F--AI-Tools 這類以前者為字首的另一個專案。
    #>
    param([string]$Text, $Pairs)
    if (-not $Pairs) { return $Text }
    foreach ($pair in $Pairs) {
        $isSlug = ($pair.ContainsKey('Kind') -and $pair['Kind'] -eq 'slug')
        foreach ($v in (Get-PathRewriteVariants -Old $pair['Old'] -New $pair['New'])) {
            if ($isSlug) {
                $Text = [regex]::Replace($Text, [regex]::Escape($v.From) + '(?![A-Za-z0-9\-])', $v.To.Replace('$', '$$'))
            } else {
                $Text = $Text.Replace($v.From, $v.To)
            }
        }
    }
    return $Text
}

function Import-ClaudePack {
    <#
    .SYNOPSIS
        將遷移包合併進目標機的 .claude。預設 dry-run 只顯示計畫; 加 -Apply 才執行, 執行前自動備份受影響檔案。
    .PARAMETER MappingFile
        JSON 路徑對映檔: { "來源機專案路徑": "目標機專案路徑", ... }。未列出的專案沿用原路徑。
    .PARAMETER Mode
        Merge (預設): 聯集合併, 同名檔案新的優先。 Move: 僅在目標不存在該專案時複製, 已存在則整案跳過。
    .PARAMETER TargetUserProfile
        目標機使用者設定檔路徑, 預設當前使用者。與遷移包來源不同時自動改寫紀錄內的使用者路徑。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackPath,
        [string]$TargetClaudeDir,
        [string]$MappingFile,
        [hashtable]$Mapping,
        [ValidateSet('Merge', 'Move')][string]$Mode = 'Merge',
        [string]$TargetUserProfile = $env:USERPROFILE,
        [switch]$Apply,
        [switch]$NoBackup
    )
    if (-not $TargetClaudeDir) { $TargetClaudeDir = (Get-ClaudeDefaultPaths).ClaudeDir }
    if (-not (Test-Path $PackPath)) { throw "找不到遷移包: $PackPath" }

    $running = @(Get-RunningClaudeProcesses)
    if ($Apply -and $running.Count -gt 0) {
        Write-Warning "Claude 正在執行 ($($running -join ', '))。強烈建議先關閉再匯入。"
    }

    $pathMap = @{}
    if ($MappingFile) {
        $raw = Get-Content $MappingFile -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $pathMap[$p.Name] = [string]$p.Value }
    }
    if ($Mapping) {
        foreach ($k in $Mapping.Keys) { $pathMap[$k] = [string]$Mapping[$k] }
    }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("claudemove-import-" + [guid]::NewGuid().ToString('N'))
    Expand-Archive -Path $PackPath -DestinationPath $work -Force
    try {
        $manifest = Get-Content (Join-Path $work 'manifest.json') -Raw | ConvertFrom-Json
        if ($manifest.packFormatVersion -gt $script:PackFormatVersion) {
            throw "遷移包格式版本 $($manifest.packFormatVersion) 比本工具支援的 $($script:PackFormatVersion) 新, 請更新工具。"
        }
        Write-Host ("遷移包來源: {0}\{1} (建立於 {2})" -f $manifest.sourceMachine.computerName, $manifest.sourceMachine.userName, $manifest.createdAt)

        # --- 帳號設定檔差異偵測 (不同 Windows 登入帳號 => C:\Users\<name> 路徑不同) ---
        $profilePair = $null
        $srcProfile = $null
        if ($manifest.sourceMachine.PSObject.Properties['userProfile']) { $srcProfile = [string]$manifest.sourceMachine.userProfile }
        if ($srcProfile -and $TargetUserProfile -and -not $srcProfile.Equals($TargetUserProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
            $profilePair = @{ Old = $srcProfile; New = $TargetUserProfile }
            Write-Host ("偵測到使用者帳號差異: {0} -> {1}, 紀錄內的使用者路徑將自動改寫。" -f $srcProfile, $TargetUserProfile) -ForegroundColor Yellow
        }
        $srcProfileSlug = if ($srcProfile) { ConvertTo-ClaudeSlug $srcProfile } else { $null }

        $plan = [System.Collections.Generic.List[object]]::new()
        $globalPairs = [System.Collections.Generic.List[object]]::new()
        if ($profilePair) { $globalPairs.Add($profilePair) }

        # --- 專案計畫 ---
        foreach ($proj in $manifest.projects) {
            $oldPath = $proj.realPath
            $newPath = $oldPath
            if ($oldPath -and $pathMap.ContainsKey($oldPath)) {
                $newPath = $pathMap[$oldPath]
            } elseif ($oldPath -and $profilePair -and $oldPath.StartsWith($profilePair.Old, [System.StringComparison]::OrdinalIgnoreCase)) {
                $newPath = $TargetUserProfile + $oldPath.Substring($profilePair.Old.Length)
            }
            $newSlug = if ($newPath) { ConvertTo-ClaudeSlug $newPath } else { $proj.slug }
            # 特例: 專案就是使用者主目錄本身 (無 cwd 可反推時以 slug 比對)
            if (-not $oldPath -and $srcProfileSlug -and $proj.slug -eq $srcProfileSlug -and $profilePair) {
                $newSlug = ConvertTo-ClaudeSlug $TargetUserProfile
            }
            $pairs = [System.Collections.Generic.List[object]]::new()
            if ($newSlug -cne $proj.slug) {
                $slugPair = New-SlugRewritePair -OldSlug $proj.slug -NewSlug $newSlug
                $pairs.Add($slugPair)
                $globalPairs.Add($slugPair)
            }
            if ($oldPath -and $newPath -and ($oldPath -ne $newPath)) {
                $pairs.Add(@{ Old = $oldPath; New = $newPath })
                $globalPairs.Add(@{ Old = $oldPath; New = $newPath })
            }
            if ($profilePair) { $pairs.Add($profilePair) }
            $rewrite = ($pairs.Count -gt 0)
            $srcDir  = Join-Path $work "claude\projects\$($proj.slug)"
            $dstDir  = Join-Path $TargetClaudeDir "projects\$newSlug"
            $dstExists = Test-Path $dstDir

            if ($Mode -eq 'Move' -and $dstExists) {
                $plan.Add([pscustomobject]@{ Action='SkipProject'; Detail="$($proj.slug): 目標已存在 (Move 模式整案跳過)"; Src=$null; Dst=$null; Rewrite=$false; Pairs=$null })
                continue
            }
            foreach ($f in (Get-ChildItem $srcDir -File -Recurse)) {
                # 舊版遷移包可能夾帶 Desktop 的刪除標記 (來源機的本機狀態), 不匯入
                if ($f.Name -like '*.desktop-released.json') { continue }
                $rel = $f.FullName.Substring($srcDir.Length + 1)
                $dstFile = Join-Path $dstDir $rel
                $isMemoryIndex = ($rel -ieq 'memory\MEMORY.md')
                $item = [pscustomobject]@{ Action=$null; Detail=$null; Src=$f.FullName; Dst=$dstFile; Rewrite=($rewrite -and $f.Extension -in '.jsonl','.json','.md'); Pairs=$pairs }
                if (-not (Test-Path $dstFile)) {
                    $item.Action = 'CopyNew'; $item.Detail = "$newSlug\$rel"
                } elseif ($isMemoryIndex) {
                    $item.Action = 'MergeIndex'; $item.Detail = "$newSlug\$rel (聯集兩邊索引行)"
                } else {
                    $dstInfo = Get-Item $dstFile
                    if ($dstInfo.Length -eq $f.Length -and [Math]::Abs(($dstInfo.LastWriteTimeUtc - $f.LastWriteTimeUtc).TotalSeconds) -lt 2) {
                        $item.Action = 'Skip'; $item.Detail = "$newSlug\$rel (相同)"
                    } elseif ($f.LastWriteTimeUtc -gt $dstInfo.LastWriteTimeUtc) {
                        $item.Action = 'Overwrite'; $item.Detail = "$newSlug\$rel (遷移包較新)"
                    } else {
                        $item.Action = 'Skip'; $item.Detail = "$newSlug\$rel (目標較新, 保留目標)"
                    }
                }
                $plan.Add($item)
            }
        }

        # --- history.jsonl: 聯集去重 (套用全部路徑改寫規則後再比對) ---
        $packHistory = Join-Path $work 'claude\history.jsonl'
        if (Test-Path $packHistory) {
            $plan.Add([pscustomobject]@{ Action='MergeHistory'; Detail='history.jsonl (附加目標缺少的行)'; Src=$packHistory; Dst=(Join-Path $TargetClaudeDir 'history.jsonl'); Rewrite=($globalPairs.Count -gt 0); Pairs=$globalPairs })
        }

        # --- 機器特定設定 -> 待審閱區, 永不自動套用 ---
        # 第三欄 = 是否套用路徑改寫 (含專案絕對路徑者改寫後才能直接沿用)
        $reviewDir = Join-Path $TargetClaudeDir ("claudemove\review\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $reviewSet = @(
            @('claude\settings.json',                  'settings.incoming.json',               $false),
            @('claude\claude.json.portable',           'claude.json.portable.json',            $true),
            @('claude\plugins.marketplaces.json',      'plugins.marketplaces.json',            $false),
            @('desktop\claude_desktop_config.json',    'claude_desktop_config.incoming.json',  $false)
        )
        foreach ($cfg in $reviewSet) {
            $src = Join-Path $work $cfg[0]
            if (-not (Test-Path $src)) { continue }
            $doRewrite = ($cfg[2] -and $globalPairs.Count -gt 0)
            $note = if ($cfg[2]) { '含專案路徑, 已套用對映改寫' } else { '含機器特定內容, 不自動套用' }
            $plan.Add([pscustomobject]@{ Action='ReviewCopy'; Detail="$($cfg[1]) -> 待審閱區 ($note)"; Src=$src; Dst=(Join-Path $reviewDir $cfg[1]); Rewrite=$doRewrite; Pairs=$globalPairs })
        }

        # --- 磁碟空間探查 ---
        $requiredBytes = 0
        foreach ($item in $plan) {
            if ($item.Src -and $item.Action -ne 'Skip') { $requiredBytes += (Get-Item $item.Src).Length }
            if ($item.Action -in 'Overwrite','MergeIndex','MergeHistory' -and $item.Dst -and (Test-Path $item.Dst)) {
                $requiredBytes += (Get-Item $item.Dst).Length   # 備份既有檔案也需要空間
            }
        }
        $targetRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($TargetClaudeDir))
        $freeBytes = ([System.IO.DriveInfo]::new($targetRoot)).AvailableFreeSpace
        $marginBytes = 100MB

        # --- 顯示計畫 ---
        Write-Host "`n=== 匯入計畫 (模式: $Mode) ===" -ForegroundColor Yellow
        Write-Plan -Plan $plan
        Write-Host ("`n空間需求 (含備份): {0:N1} MB, 目標磁碟 {1} 剩餘: {2:N1} GB" -f ($requiredBytes / 1MB), $targetRoot, ($freeBytes / 1GB)) -ForegroundColor Cyan
        if ($freeBytes -lt ($requiredBytes + $marginBytes)) {
            $msg = "目標磁碟空間不足: 需要約 {0:N0} MB (含 100MB 安全餘裕), 僅剩 {1:N0} MB。" -f (($requiredBytes + $marginBytes) / 1MB), ($freeBytes / 1MB)
            if ($Apply) { throw $msg } else { Write-Warning $msg }
        }
        if (-not $Apply) {
            Write-Host "`nDry-run 結束, 未變更任何檔案。加上 -Apply 執行。" -ForegroundColor Yellow
            return $plan
        }

        # --- 備份受影響的既有檔案 ---
        # 注意: 官方會自行管理 ~/.claude\backups, 所以 ClaudeMove 的產出一律收在 claudemove\ 之下
        $logDir = Join-Path $TargetClaudeDir 'claudemove\logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        if (-not $NoBackup) {
            $backupDir = Join-Path $TargetClaudeDir "claudemove\backups\import-$ts"
            $affected = @($plan | Where-Object { $_.Action -in 'Overwrite','MergeIndex','MergeHistory' -and $_.Dst -and (Test-Path $_.Dst) })
            foreach ($item in $affected) {
                $rel = $item.Dst.Substring($TargetClaudeDir.Length + 1)
                $bak = Join-Path $backupDir $rel
                New-Item -ItemType Directory -Path (Split-Path $bak -Parent) -Force | Out-Null
                Copy-Item $item.Dst $bak -Force
            }
            if ($affected.Count -gt 0) { Write-Host "已備份 $($affected.Count) 個將被修改的檔案至 $backupDir" -ForegroundColor Green }
        }

        # --- 執行 ---
        $log = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $plan) {
            switch ($item.Action) {
                { $_ -in 'Skip', 'SkipProject' } { continue }
                { $_ -in 'CopyNew', 'Overwrite', 'ReviewCopy' } {
                    New-Item -ItemType Directory -Path (Split-Path $item.Dst -Parent) -Force | Out-Null
                    if ($item.Rewrite) {
                        $text = Invoke-PathRewrite -Text ([System.IO.File]::ReadAllText($item.Src)) -Pairs $item.Pairs
                        [System.IO.File]::WriteAllText($item.Dst, $text)
                    } else {
                        Copy-Item $item.Src $item.Dst -Force
                    }
                    $log.Add("$($item.Action): $($item.Detail)")
                }
                'MergeIndex' {
                    $existing = @(Get-Content $item.Dst -Encoding utf8)
                    $incomingText = [System.IO.File]::ReadAllText($item.Src)
                    if ($item.Rewrite) { $incomingText = Invoke-PathRewrite -Text $incomingText -Pairs $item.Pairs }
                    $incoming = $incomingText -split "`r?`n"
                    $missing = @($incoming | Where-Object { $_.Trim() -and ($existing -notcontains $_) })
                    if ($missing.Count -gt 0) { Add-Content -Path $item.Dst -Value $missing -Encoding utf8 }
                    $log.Add("MergeIndex: $($item.Detail) (+$($missing.Count) 行)")
                }
                'MergeHistory' {
                    $incomingText = [System.IO.File]::ReadAllText($item.Src)
                    if ($item.Rewrite) { $incomingText = Invoke-PathRewrite -Text $incomingText -Pairs $item.Pairs }
                    if (-not (Test-Path $item.Dst)) {
                        [System.IO.File]::WriteAllText($item.Dst, $incomingText)
                        $log.Add("MergeHistory: 目標無 history.jsonl, 直接複製")
                    } else {
                        $existingSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-Content $item.Dst -Encoding utf8))
                        $missing = @(($incomingText -split "`r?`n") | Where-Object { $_.Trim() -and -not $existingSet.Contains($_) })
                        if ($missing.Count -gt 0) { Add-Content -Path $item.Dst -Value $missing -Encoding utf8 }
                        $log.Add("MergeHistory: +$($missing.Count) 行")
                    }
                }
            }
        }
        $logFile = Join-Path $logDir "import-$ts.log"
        $log | Set-Content $logFile -Encoding utf8
        Write-Host "`n匯入完成: 執行 $($log.Count) 項動作, 日誌: $logFile" -ForegroundColor Green
        $review = @($plan | Where-Object Action -eq 'ReviewCopy')
        if ($review.Count -gt 0) {
            Write-Host "注意: $($review.Count) 個設定檔含機器特定內容, 已放入待審閱區 $reviewDir, 請人工比對後手動套用。" -ForegroundColor Yellow
        }
        return $plan
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region 網路傳輸 (區網直連, 遷移包格式不變, 只是多一種通道)

function Read-NetLine {
    # 逐位元組讀一行, 避免 StreamReader 預讀緩衝吃掉後續檔案位元組
    param([System.IO.Stream]$Stream)
    $bytes = [System.Collections.Generic.List[byte]]::new()
    while (($b = $Stream.ReadByte()) -ge 0) {
        if ($b -eq 10) { break }
        $bytes.Add([byte]$b)
    }
    return [System.Text.UTF8Encoding]::new($false).GetString($bytes.ToArray()).TrimEnd("`r")
}

function Write-NetLine {
    param([System.IO.Stream]$Stream, [string]$Text)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text + "`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Send-ClaudePack {
    <#
    .SYNOPSIS
        在區網等待另一台電腦連入並傳送遷移包。一次性 token 驗證 + SHA256 校驗, 傳完即停止。
    .NOTES
        使用原生 TCP, 不需管理員權限; Windows 防火牆首次可能跳出允許提示, 需允許。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackPath,
        [int]$Port = 17539,
        [int]$TimeoutSec = 600
    )
    if (-not (Test-Path $PackPath)) { throw "找不到遷移包: $PackPath" }
    $file = Get-Item $PackPath
    $sha256 = (Get-FileHash $PackPath -Algorithm SHA256).Hash
    $token = -join ((1..8) | ForEach-Object { '0123456789abcdefghjkmnpqrstuvwxyz'[(Get-Random -Maximum 33)] })

    $ips = @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object IPAddressToString)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
    $listener.Start()
    try {
        Write-Host "等待接收端連入 (逾時 $TimeoutSec 秒)..." -ForegroundColor Yellow
        Write-Host ("本機位址: {0}  連接埠: {1}" -f ($ips -join ', '), $Port) -ForegroundColor Cyan
        Write-Host ("接收端指令: claudemove.ps1 receive -From <本機IP>:{0} -Token {1} -OutputPath <存檔路徑>" -f $Port, $token) -ForegroundColor Cyan
        Write-Host ("Token: {0}" -f $token) -ForegroundColor Green

        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while (-not $listener.Pending()) {
            if ((Get-Date) -gt $deadline) { throw "等待逾時, 沒有接收端連入。" }
            Start-Sleep -Milliseconds 300
        }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $hello = Read-NetLine -Stream $stream
            if ($hello -ne "CLAUDEMOVE1 $token") {
                Write-NetLine -Stream $stream -Text 'ERR token 錯誤'
                throw "接收端 token 驗證失敗, 已拒絕連線。"
            }
            Write-NetLine -Stream $stream -Text ("OK {0}|{1}|{2}" -f $file.Name, $file.Length, $sha256)
            $fs = [System.IO.File]::OpenRead($file.FullName)
            try { $fs.CopyTo($stream) } finally { $fs.Dispose() }
            $stream.Flush()
            Write-Host ("傳送完成: {0} ({1:N1} MB) 已送出, SHA256 校驗由接收端執行。" -f $file.Name, ($file.Length / 1MB)) -ForegroundColor Green
        } finally { $client.Dispose() }
    } finally { $listener.Stop() }
}

function Receive-ClaudePack {
    <#
    .SYNOPSIS
        從區網另一台電腦接收遷移包 (對方須正在執行 send), 完成後以 SHA256 驗證完整性。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$From,      # ip 或 ip:port
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$OutputPath # 目錄或完整檔名
    )
    $ip = $From; $port = 17539
    if ($From -match '^(.+):(\d+)$') { $ip = $Matches[1]; $port = [int]$Matches[2] }
    $client = [System.Net.Sockets.TcpClient]::new()
    $client.Connect($ip, $port)
    try {
        $stream = $client.GetStream()
        Write-NetLine -Stream $stream -Text "CLAUDEMOVE1 $Token"
        $resp = Read-NetLine -Stream $stream
        if ($resp -notmatch '^OK (.+)\|(\d+)\|([0-9A-Fa-f]{64})$') { throw "傳送端拒絕或回應異常: $resp" }
        $name = $Matches[1]; $size = [long]$Matches[2]; $expectedHash = $Matches[3]

        $dest = $OutputPath
        if (Test-Path $OutputPath -PathType Container) {
            $dest = Join-Path $OutputPath $name
        } elseif (-not [System.IO.Path]::GetExtension($OutputPath)) {
            # 無副檔名視為目錄
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
            $dest = Join-Path $OutputPath $name
        }
        $destDir = Split-Path $dest -Parent
        if ($destDir -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        # 同名檔已存在時自動改名, 不無聲覆蓋
        if (Test-Path $dest) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($dest)
            $ext = [System.IO.Path]::GetExtension($dest)
            $n = 2
            while (Test-Path (Join-Path $destDir "$base ($n)$ext")) { $n++ }
            $dest = Join-Path $destDir "$base ($n)$ext"
        }

        Write-Host ("接收中: {0} ({1:N1} MB)..." -f $name, ($size / 1MB)) -ForegroundColor Yellow
        $fs = [System.IO.File]::Create($dest)
        try {
            $received = 0L
            $buf = New-Object byte[] 81920
            while ($received -lt $size) {
                $n = $stream.Read($buf, 0, [Math]::Min($buf.Length, $size - $received))
                if ($n -le 0) { throw "連線中斷, 已收到 $received / $size bytes。" }
                $fs.Write($buf, 0, $n)
                $received += $n
            }
        } finally { $fs.Dispose() }

        $actualHash = (Get-FileHash $dest -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash) {
            throw "SHA256 校驗失敗! 檔案可能損毀: $dest"
        }
        Write-Host ("接收完成並通過 SHA256 校驗: {0}" -f $dest) -ForegroundColor Green
        return Get-Item $dest
    } finally { $client.Dispose() }
}

#endregion

#region 跨 slug 去重 (同一實體路徑被記成多個 slug 時合併)

function Merge-ClaudeProjectSlugs {
    <#
    .SYNOPSIS
        處理專案搬移後的殘留: 多個 slug 指向同一實體路徑時, 將其合併為一個。
        無參數 = 列出偵測到的重複群組; 指定 -SourcePath 與 -IntoPath 並加 -Apply 才執行。
    .PARAMETER SourcePath
        紀錄中的舊路徑 (jsonl cwd 所指), 所有指向此路徑的 slug 都會被合併。
    .PARAMETER IntoPath
        合併目的地的實體路徑 (通常是專案現在真正的位置), 內容會改寫至此路徑並放入對應 slug。
    #>
    [CmdletBinding()]
    param(
        [string]$ClaudeDir,
        [string]$SourcePath,
        [string]$IntoPath,
        [switch]$Apply
    )
    if (-not $ClaudeDir) { $ClaudeDir = (Get-ClaudeDefaultPaths).ClaudeDir }
    $inv = Get-ClaudeInventory -ClaudeDir $ClaudeDir 3>$null

    # 模式一: 列出重複群組
    if (-not $SourcePath) {
        $groups = @($inv.claudeCode.projects | Where-Object realPath |
            Group-Object realPath | Where-Object Count -gt 1)
        if ($groups.Count -eq 0) { Write-Host "沒有偵測到指向同一路徑的多個 slug。" -ForegroundColor Green; return @() }
        Write-Host "`n=== 偵測到重複群組 ===" -ForegroundColor Yellow
        foreach ($g in $groups) {
            Write-Host ("路徑 {0} (存在: {1}) 被 {2} 個 slug 指向:" -f $g.Name, (Test-Path $g.Name), $g.Count) -ForegroundColor Cyan
            foreach ($p in $g.Group) { Write-Host ("  - {0} ({1} sessions, {2} 記憶)" -f $p.slug, $p.sessionCount, $p.memoryCount) }
            Write-Host ("  合併指令: claudemove.ps1 dedupe -SourcePath `"{0}`" -IntoPath `"<專案現在的實際路徑>`" -Apply" -f $g.Name) -ForegroundColor DarkGray
        }
        return $groups
    }

    if (-not $IntoPath) { throw "指定 -SourcePath 時必須同時指定 -IntoPath (合併目的地的實體路徑)。" }
    $targetSlug = ConvertTo-ClaudeSlug $IntoPath
    $targetDir = Join-Path (Join-Path $ClaudeDir 'projects') $targetSlug
    $sources = @($inv.claudeCode.projects | Where-Object { $_.realPath -eq $SourcePath -and $_.slug -ne $targetSlug })
    if ($sources.Count -eq 0) { Write-Host "沒有 slug 的紀錄指向 $SourcePath (或都已在目標 slug 內), 無事可做。" -ForegroundColor Green; return }

    $rewrite = ($SourcePath -ne $IntoPath)
    Write-Host "`n=== 去重計畫 ===" -ForegroundColor Yellow
    foreach ($s in $sources) {
        Write-Host ("  {0} -> {1}  (路徑改寫: {2} -> {3})" -f $s.slug, $targetSlug, $SourcePath, $IntoPath)
    }
    if (-not $Apply) { Write-Host "`nDry-run 結束, 未變更任何檔案。加上 -Apply 執行。" -ForegroundColor Yellow; return }

    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bakRoot = Join-Path $ClaudeDir "claudemove\backups\dedupe-$ts"
    New-Item -ItemType Directory -Path $bakRoot -Force | Out-Null
    # 目標 slug 既有內容先快照備份 (其自身檔案也可能含舊路徑, 待會一併改寫)
    if (Test-Path $targetDir) {
        Copy-Item $targetDir (Join-Path $bakRoot "$targetSlug.before") -Recurse -Force
    }
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    $moved = 0
    $pathPairs = [System.Collections.Generic.List[object]]::new()
    if ($rewrite) { $pathPairs.Add(@{ Old = $SourcePath; New = $IntoPath }) }
    $allPairs = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $sources) {
        $srcDir = Join-Path (Join-Path $ClaudeDir 'projects') $s.slug
        # 紀錄內嵌的 ...\.claude\projects\<來源 slug>\... 也要改指向目標 slug
        $pairs = [System.Collections.Generic.List[object]]::new()
        $slugPair = New-SlugRewritePair -OldSlug $s.slug -NewSlug $targetSlug
        $pairs.Add($slugPair); $allPairs.Add($slugPair)
        foreach ($pp in $pathPairs) { $pairs.Add($pp) }
        foreach ($f in (Get-ChildItem $srcDir -File -Recurse)) {
            if ($f.Name -like '*.desktop-released.json') { continue }   # Desktop 的刪除標記不合併
            $rel = $f.FullName.Substring($srcDir.Length + 1)
            $dst = Join-Path $targetDir $rel
            if (Test-Path $dst) {
                if ($rel -ieq 'memory\MEMORY.md') {
                    # 索引檔逐行聯集
                    $existing = @(Get-Content $dst -Encoding utf8)
                    $incomingText = Invoke-PathRewrite -Text ([System.IO.File]::ReadAllText($f.FullName)) -Pairs $pairs
                    $missing = @(($incomingText -split "`r?`n") | Where-Object { $_.Trim() -and ($existing -notcontains $_) })
                    if ($missing.Count -gt 0) { Add-Content -Path $dst -Value $missing -Encoding utf8 }
                    continue
                }
                # 同名檔已存在目標: 保留較新者
                if ((Get-Item $dst).LastWriteTimeUtc -ge $f.LastWriteTimeUtc) { continue }
            }
            New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
            if ($f.Extension -in '.jsonl', '.json', '.md') {
                $text = Invoke-PathRewrite -Text ([System.IO.File]::ReadAllText($f.FullName)) -Pairs $pairs
                [System.IO.File]::WriteAllText($dst, $text)
            } else {
                Copy-Item $f.FullName $dst -Force
            }
        }
        # 原 slug 資料夾整個移入備份區 (不刪除)
        Move-Item $srcDir (Join-Path $bakRoot $s.slug) -Force
        $moved++
    }
    # 目標 slug 自身檔案若仍殘留舊路徑 / 舊 slug 引用, 一併改寫
    $fixed = 0
    foreach ($pp in $pathPairs) { $allPairs.Add($pp) }
    foreach ($f in (Get-ChildItem $targetDir -File -Recurse | Where-Object { $_.Extension -in '.jsonl', '.json', '.md' })) {
        $orig = [System.IO.File]::ReadAllText($f.FullName)
        $text = Invoke-PathRewrite -Text $orig -Pairs $allPairs
        if ($text -cne $orig) { [System.IO.File]::WriteAllText($f.FullName, $text); $fixed++ }
    }
    Write-Host ("去重完成: {0} 個 slug 已合併進 {1}, 另修正 {2} 個殘留舊路徑的檔案, 備份於 {3}" -f $moved, $targetSlug, $fixed, $bakRoot) -ForegroundColor Green
}

#endregion

#region 建議引擎與互動精靈

function Get-ClaudeMappingSuggestions {
    <#
    .SYNOPSIS
        探查目標機, 為遷移包中不存在於本機的專案路徑自動找出候選並給建議。
        評分: git remote 相符 > 其他磁碟同相對路徑 > 同名資料夾。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackPath,
        [string]$TargetUserProfile = $env:USERPROFILE,
        [int]$ScanDepth = 2
    )
    $manifest = Get-PackManifest -PackPath $PackPath
    $srcProfile = $null
    if ($manifest.sourceMachine.PSObject.Properties['userProfile']) { $srcProfile = [string]$manifest.sourceMachine.userProfile }
    $fixedDrives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName })

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($proj in $manifest.projects) {
        if (-not $proj.realPath) {
            $result.Add([pscustomobject]@{ slug=$proj.slug; sourcePath=$null; status='unknown'; suggested=$null; reason='無法從紀錄反推來源路徑'; candidates=@() })
            continue
        }
        # 先套用帳號差異調整 (與 Import 相同邏輯)
        $expected = [string]$proj.realPath
        if ($srcProfile -and $TargetUserProfile -and
            $expected.StartsWith($srcProfile, [System.StringComparison]::OrdinalIgnoreCase) -and
            -not $srcProfile.Equals($TargetUserProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
            $expected = $TargetUserProfile + $expected.Substring($srcProfile.Length)
        }
        if (Test-Path $expected) {
            $result.Add([pscustomobject]@{ slug=$proj.slug; sourcePath=$proj.realPath; status='exists'; suggested=$null; reason='目標機已有相同路徑, 免對映'; candidates=@() })
            continue
        }

        $gitRemote = $null
        if ($proj.PSObject.Properties['gitRemote']) { $gitRemote = [string]$proj.gitRemote }
        $leaf = Split-Path $expected -Leaf
        $srcRoot = [System.IO.Path]::GetPathRoot($expected)
        $rel = $expected.Substring($srcRoot.Length)
        $cands = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        # 候選一: 其他磁碟的相同相對路徑
        foreach ($d in $fixedDrives) {
            $p = Join-Path $d $rel
            if ((Test-Path $p) -and $seen.Add($p)) {
                $cands.Add([pscustomobject]@{ path=$p; score=70; reason='其他磁碟同路徑' })
            }
        }
        # 候選二: 各磁碟淺層掃描同名資料夾
        foreach ($d in $fixedDrives) {
            $hits = @(Get-ChildItem -Path $d -Directory -Depth $ScanDepth -Filter $leaf -ErrorAction SilentlyContinue)
            foreach ($hit in $hits) {
                if ($seen.Add($hit.FullName)) {
                    $cands.Add([pscustomobject]@{ path=$hit.FullName; score=50; reason='同名資料夾' })
                }
            }
        }
        # 加權: git remote 相符最可信
        if ($gitRemote) {
            foreach ($c in $cands) {
                $r = Get-GitRemoteUrl -RepoPath $c.path
                if ($r -and $r -eq $gitRemote) { $c.score += 50; $c.reason = "git remote 相符 ($($c.reason))" }
            }
        }

        $sorted = @($cands | Sort-Object score -Descending)
        if ($sorted.Count -gt 0) {
            $best = $sorted[0]
            $result.Add([pscustomobject]@{ slug=$proj.slug; sourcePath=$proj.realPath; status='suggested'; suggested=$best.path; reason=$best.reason; candidates=$sorted })
        } else {
            $result.Add([pscustomobject]@{ slug=$proj.slug; sourcePath=$proj.realPath; status='not-found'; suggested=$null; reason='目標機找不到候選資料夾'; candidates=@() })
        }
    }
    return $result
}

function Invoke-ClaudeMoveWizard {
    <#
    .SYNOPSIS
        互動式精靈: 數字選單挑專案/session 匯出, 或匯入時自動建議路徑對映並確認執行。
    .PARAMETER ScriptedAnswers
        測試/自動化用: 依序作為每個提示的回答, 用完後改回互動輸入。
    #>
    [CmdletBinding()]
    param(
        [string]$ClaudeDir,
        [string]$DesktopDir,
        [string]$TargetClaudeDir,
        [string[]]$ScriptedAnswers
    )
    $queue = $null
    if ($ScriptedAnswers) { $queue = [System.Collections.Generic.Queue[string]]::new([string[]]$ScriptedAnswers) }
    $ask = {
        param($prompt)
        if ($queue -and $queue.Count -gt 0) {
            $a = $queue.Dequeue()
            Write-Host ("{0}: {1}   [自動回答]" -f $prompt, $a) -ForegroundColor DarkGray
            return $a
        }
        return (Read-Host $prompt)
    }
    $parseIndexes = {
        param($raw, $max)
        if ($raw.Trim() -ieq 'all' -or $raw.Trim() -eq '') { return @(1..$max) }
        $idx = [System.Collections.Generic.List[int]]::new()
        foreach ($tok in ($raw -split '[,，\s]+')) {
            if ($tok -match '^\d+$') { $n = [int]$tok; if ($n -ge 1 -and $n -le $max) { $idx.Add($n) } }
        }
        return @($idx | Select-Object -Unique)
    }

    Write-Host "`n=== ClaudeMove 精靈 ===" -ForegroundColor Yellow
    $mode = & $ask "選擇操作 (1=匯出打包, 2=匯入合併)"

    if ($mode -eq '1') {
        # ---------- 匯出流程 ----------
        $invArgs = @{}
        if ($ClaudeDir)  { $invArgs.ClaudeDir  = $ClaudeDir }
        if ($DesktopDir) { $invArgs.DesktopDir = $DesktopDir }
        $inv = Get-ClaudeInventory @invArgs
        $projs = @($inv.claudeCode.projects)
        Write-Host "`n本機專案:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $projs.Count; $i++) {
            Write-Host ("  [{0}] {1}  ({2} sessions, {3} 記憶, {4:N1} MB)" -f ($i + 1), $projs[$i].slug, $projs[$i].sessionCount, $projs[$i].memoryCount, ($projs[$i].sizeBytes / 1MB))
        }
        $selIdx = & $parseIndexes (& $ask "選擇專案 (逗號分隔編號, all=全部)") $projs.Count
        if (@($selIdx).Count -eq 0) { Write-Host "未選擇任何專案, 結束。" -ForegroundColor Yellow; return }
        $selSlugs = @($selIdx | ForEach-Object { $projs[$_ - 1].slug })

        $sessionIds = $null
        $allSess = & $ask "打包所選專案的全部 session? (Y/n)"
        if ($allSess -match '^[nN]') {
            $listArgs = @{ Projects = $selSlugs }
            if ($ClaudeDir) { $listArgs.ClaudeDir = $ClaudeDir }
            $sessList = @(Get-ClaudeSessionList @listArgs)
            Write-Host "`nSessions:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $sessList.Count; $i++) {
                Write-Host ("  [{0}] {1} | {2} | {3:N1} MB | {4}" -f ($i + 1), $sessList[$i].slug, $sessList[$i].lastWrite, $sessList[$i].sizeMB, $sessList[$i].preview)
            }
            $sIdx = & $parseIndexes (& $ask "選擇 session (逗號分隔編號, all=全部)") $sessList.Count
            if (@($sIdx).Count -eq 0) { Write-Host "未選擇任何 session, 結束。" -ForegroundColor Yellow; return }
            $sessionIds = @($sIdx | ForEach-Object { $sessList[$_ - 1].sessionId })
        }

        $out = & $ask "輸出路徑 (例如 D:\backup\mypack)"
        if (-not $out) { Write-Host "未提供輸出路徑, 結束。" -ForegroundColor Yellow; return }
        $expArgs = @{ OutputPath = $out; Projects = $selSlugs }
        if ($sessionIds) { $expArgs.Sessions   = $sessionIds }
        if ($ClaudeDir)  { $expArgs.ClaudeDir  = $ClaudeDir }
        if ($DesktopDir) { $expArgs.DesktopDir = $DesktopDir }
        Export-ClaudePack @expArgs | Out-Null
        return
    }

    if ($mode -eq '2') {
        # ---------- 匯入流程 ----------
        $pack = & $ask "遷移包路徑 (.claudepack.zip)"
        if (-not (Test-Path $pack)) { Write-Host "找不到遷移包: $pack" -ForegroundColor Red; return }

        Write-Host "`n正在探查目標機, 產生路徑對映建議..." -ForegroundColor Cyan
        $sugs = @(Get-ClaudeMappingSuggestions -PackPath $pack)
        $mapping = @{}
        foreach ($s in $sugs) {
            switch ($s.status) {
                'exists'    { Write-Host ("  [免對映] {0} -> {1}" -f $s.slug, $s.sourcePath) -ForegroundColor Green }
                'unknown'   { Write-Host ("  [略過]   {0}: {1}" -f $s.slug, $s.reason) -ForegroundColor DarkGray }
                'suggested' {
                    Write-Host ("  [建議]   {0}: 原路徑 {1} 不存在" -f $s.slug, $s.sourcePath) -ForegroundColor Yellow
                    $a = & $ask ("           建議對映到 {0} ({1})。採用? (Y=採用/n=略過/或輸入自訂路徑)" -f $s.suggested, $s.reason)
                    if ($a -eq '' -or $a -match '^[yY]') { $mapping[$s.sourcePath] = $s.suggested }
                    elseif ($a -match '^[a-zA-Z]:[\\/]') { $mapping[$s.sourcePath] = $a }
                }
                'not-found' {
                    $a = & $ask ("  [無建議] {0}: 原路徑 {1} 不存在且找不到候選。輸入自訂路徑或 Enter 略過" -f $s.slug, $s.sourcePath)
                    if ($a -match '^[a-zA-Z]:[\\/]') { $mapping[$s.sourcePath] = $a }
                }
            }
        }

        $impArgs = @{ PackPath = $pack }
        if ($mapping.Count -gt 0) { $impArgs.Mapping = $mapping }
        if ($TargetClaudeDir)     { $impArgs.TargetClaudeDir = $TargetClaudeDir }
        Import-ClaudePack @impArgs | Out-Null   # dry-run 顯示計畫

        $go = & $ask "`n確認執行匯入? (y/N)"
        if ($go -match '^[yY]') {
            Import-ClaudePack @impArgs -Apply | Out-Null
        } else {
            Write-Host "已取消, 未變更任何檔案。" -ForegroundColor Yellow
        }
        return
    }
    Write-Host "無效的選擇: $mode" -ForegroundColor Red
}

#endregion

Export-ModuleMember -Function Get-ClaudeInventory, Get-ClaudeSessionList, Get-ClaudeMappingSuggestions, Invoke-ClaudeMoveWizard, Export-ClaudePack, Import-ClaudePack, Send-ClaudePack, Receive-ClaudePack, Merge-ClaudeProjectSlugs, ConvertTo-ClaudeSlug, Get-ClaudeMoveVersion, Get-SanitizedClaudeConfig, Get-ClaudeConfigProjectMap

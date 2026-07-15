# ClaudeMove

在多台 Windows 電腦之間**備份、轉移、合併** Claude Desktop / Claude Code 本地資料的工具。

## 它解決什麼問題

Claude 的資料分三種同步狀態:

| 資料 | 存放位置 | 換電腦會怎樣 |
|---|---|---|
| claude.ai 對話、雲端專案 | Anthropic 雲端 | 登入即同步,**不需要本工具** |
| 程式碼 | 你的專案資料夾 | 請用 git + 遠端倉庫,**不建議用本工具搬** |
| Claude Code session 紀錄、記憶、設定、MCP 配置 | `~\.claude` 與 `%APPDATA%\Claude` | **會遺失 — 本工具負責這塊** |

## 安裝

執行 `dist\ClaudeMove-Setup-<版本>.exe`(免系統管理員權限,安裝到使用者目錄),會建立開始功能表與桌面捷徑。移除從「設定 → 應用程式」即可。前置需求:PowerShell 7(`winget install Microsoft.PowerShell`),安裝程式會自動檢查並提示。

重新產生安裝檔(需 Inno Setup 6):`ISCC.exe installer\claudemove.iss`

## 最簡單的用法:GUI(安裝後點捷徑,或雙擊 `ClaudeMove-GUI.cmd`)

圖形介面五個分頁:**盤點**(本機資產一覽)、**匯出打包**(勾選專案/session)、**匯入合併**(分析建議 → 編輯對映 → Dry-run → 執行)、**網路傳輸**(區網直傳)、**slug 去重**。所有操作與 CLI 共用同一套引擎。需要 PowerShell 7(`winget install Microsoft.PowerShell`)。

## 終端機用法:互動式精靈

```powershell
.\claudemove.ps1 wizard
```

精靈會一步步引導:選匯出或匯入 → 數字選單挑專案/session → 匯入時**自動探查目標機並建議路徑對映**(換磁碟同路徑、同名資料夾、git remote 相符加權)→ 先看 dry-run 計畫 → 確認才執行。一路按 Enter 即採用建議值。

## 指令式用法(進階/自動化)

```powershell
# 1.(兩台機器皆可)盤點本機 Claude 資產 — 純唯讀
.\claudemove.ps1 inventory

# 2.(來源機)匯出遷移包 — 只讀取,不改動來源
.\claudemove.ps1 export -OutputPath D:\backup\mypack
#    只挑部分專案:  -Projects "E--Claude-Move-Merge","D--Reel-Maker"
#    自選 session:  先用 sessions 指令列出清單(含內容預覽), 再挑要打包的 id
.\claudemove.ps1 sessions
.\claudemove.ps1 export -OutputPath D:\backup\mypack -Sessions "5f5f91a8-...","f617e63e-..."
#    指定 -Sessions 時只打包含所選 session 的專案(該專案的記憶會一併帶上)

# 3. 把 mypack.claudepack.zip 帶到目標機 — 隨身碟 / 雲端硬碟, 或區網直傳:
#    來源機:  .\claudemove.ps1 send -PackPath mypack.claudepack.zip     (顯示 IP 與一次性 Token)
#    目標機:  .\claudemove.ps1 receive -From <IP>:17539 -Token <token> -OutputPath D:\backup
#    (原生 TCP + SHA256 完整性校驗; 首次使用允許 Windows 防火牆提示即可)

# 4.(目標機)先 dry-run 看計畫 — 不動任何檔案
.\claudemove.ps1 import -PackPath .\mypack.claudepack.zip

# 5. 確認計畫後執行(執行前自動備份將被修改的檔案)
.\claudemove.ps1 import -PackPath .\mypack.claudepack.zip -Apply
```

### 兩台機器的專案路徑不同時

建立路徑對映檔 `map.json`(來源路徑 → 目標路徑):

```json
{
  "E:\\Claude_Move_Merge": "D:\\Work\\Claude_Move_Merge"
}
```

```powershell
.\claudemove.ps1 import -PackPath .\mypack.claudepack.zip -MappingFile .\map.json -Apply
```

工具會自動改名專案資料夾(slug),並改寫 session 紀錄內的所有路徑引用。
**建議:讓所有電腦的專案路徑保持一致,即可完全省略對映檔。**

不想手寫對映檔?用 `suggest` 自動產生草稿:

```powershell
.\claudemove.ps1 suggest -PackPath mypack.claudepack.zip -OutFile map.json
# 檢視/編輯 map.json 後:
.\claudemove.ps1 import -PackPath mypack.claudepack.zip -MappingFile map.json -Apply
```

### 兩台電腦的 Windows 登入帳號不同時

**不需要任何設定**——遷移包記錄了來源機的使用者設定檔路徑(如 `C:\Users\gomask`),匯入時自動偵測與目標機帳號的差異,並:

- 自動改寫紀錄內所有使用者路徑(`C:\Users\舊帳號` → `C:\Users\新帳號`)
- 位於使用者目錄下的專案自動套用新路徑與新 slug
- 測試或特殊情境可用 `-TargetUserProfile` 手動指定

### 磁碟空間探查

- **匯入前**自動計算所需空間(複製 + 備份)並與目標磁碟剩餘空間比對,顯示於計畫中;空間不足時 dry-run 警告、`-Apply` 直接中止
- **匯出前**檢查輸出磁碟剩餘空間,不足時警告

## 合併規則(Mode 預設 Merge)

- **session 紀錄(.jsonl)**:檔名是唯一 UUID,兩邊取聯集;同名檔案「較新的優先」,被覆蓋前先備份
- **記憶(memory/)**:一檔一記憶,取聯集;索引 `MEMORY.md` 逐行聯集合併
- **history.jsonl**:逐行去重後附加
- **settings.json、claude_desktop_config.json**:含機器特定路徑,**永不自動套用**,放入 `~\.claude\claudemove-review\` 待人工審閱
- `-Mode Move`:目標已有同專案時整案跳過(適合單純搬新機,不想碰既有資料)

## 安全設計

- 憑證(`.credentials.json`)、快取、shell snapshots **永不匯出**(硬性黑名單)
- import 預設 dry-run,`-Apply` 才動手
- 執行前自動備份受影響檔案至 `~\.claude\backups\claudemove-<時間戳>\`
- 全部動作寫入 `~\.claude\claudemove-logs\`
- 偵測到 Claude 執行中會警告(避免複製寫入中的檔案)

## 限制與注意

- 兩台電腦需登入**同一個 Claude 帳號**,否則雲端側對話本來就不同步
- 若專案曾被搬移過,可能有**多個 slug 指向同一實體路徑**(例如 `D--Deep-Live-Cam` 與 `F--Deep-Live-Cam` 都指向 `D:\Deep-Live-Cam`)。用 `dedupe` 整併:

  ```powershell
  .\claudemove.ps1 dedupe                                    # 列出重複群組
  .\claudemove.ps1 dedupe -SourcePath "D:\Deep-Live-Cam" -IntoPath "F:\Deep-Live-Cam" -Apply
  ```

  會把所有指向舊路徑的 slug 合併進現路徑的 slug、改寫全部路徑引用、原資料夾移入備份區
- `~\.claude` 為未文件化的內部格式,Claude 改版後結構可能變動;遷移包內含格式版本號,不相容時工具會拒絕匯入而非損毀資料
- 匯入後**建議重開 Claude Desktop** 再確認結果

## 專案結構

```
dist\ClaudeMove-Setup-*.exe   Windows 安裝檔 (Inno Setup 產出)
installer\claudemove.iss      安裝檔腳本
ClaudeMove-GUI.vbs / .cmd     GUI 啟動器 (vbs 無黑窗, 捷徑使用)
claudemove-gui.ps1            圖形介面 (盤點 / 匯出 / 匯入 / 網路 / 去重)
claudemove.ico                應用程式圖示
claudemove.ps1                CLI 入口 (wizard / inventory / sessions / export / suggest / import / send / receive / dedupe)
src\ClaudeMove.psm1           引擎 (探查、session 列表、匯出、對映建議、匯入合併、路徑改寫、網路傳輸、去重、精靈)
```

## 已知取捨與路線圖

- **同一 session 在兩台電腦各自續聊**:合併時「較新的檔案優先」,較舊那份會進備份區而非智慧合線(session 內部有訊息鏈結構,貿然合線風險高)
- **history.jsonl 合併後順序**:去重附加在檔尾,不保證嚴格時間序(Claude Code 讀取不受影響)
- **中文/特殊字元專案路徑**:slug 演算法對非英數字元的處理是以現有資料反推的,極端字元組合建議先 dry-run 確認
- 網路傳輸加密層(目前為區網明文 TCP + token 驗證 + SHA256 校驗,適合家用/信任網路)

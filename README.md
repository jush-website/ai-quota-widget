# AI 額度小工具 · ai-quota-widget

常駐在 Windows 螢幕右下角的小工具，一眼看到這台電腦登入的 **Codex**、**Claude Code**、**Antigravity** 額度，以及 **CPU／GPU／RAM／GPU 溫度／顯存**。同時附一個區網網頁儀表板，手機也能看。

- 三種樣式：條狀、指針、純數字（右鍵切換）
- 可放在螢幕右側或頂部並收合到邊緣：滑鼠移過自動滑出，點圖釘固定；收合時把手上的燈號點點顯示各項狀態（藍 <50%、綠 50–74%、黃 75–89%、紅 ≥90% 並快閃）
- 開機（登入 Windows 後）自動啟動
- 有新版時小工具會提示「有新版」，MSI 版在右鍵選單按「更新」就會自動下載安裝（可攜版則開啟下載頁）
- 可攜版內附 Node.js，不需要安裝任何東西

## 下載與使用

到 [Releases](https://github.com/jush-website/ai-quota-widget/releases/latest) 下載，兩種擇一：

### 安裝程式 `.msi`（推薦）

1. 下載 `ai-quota-widget-*-windows.msi`，雙擊安裝（不需要管理員權限，裝在 `%LocalAppData%\Programs\ai-quota-widget`）。
   - 安裝程式沒有數位簽章，Windows 可能顯示「Windows 已保護您的電腦」：點「其他資訊」→「仍要執行」。
2. 裝好會自動開啟小工具，並建立開始功能表、桌面與開機自動啟動捷徑。
3. 要連結 Claude 帳號或讓手機連線：開始功能表 →「AI 額度小工具 設定」。

更新：直接安裝新版的 `.msi`，設定會保留。解除安裝：「設定 → 應用程式」找「AI 額度小工具」。

### 可攜版 `.zip`

1. 下載 `ai-quota-widget-*-windows.zip`，解壓縮到固定的位置（建議不要放在 OneDrive 等同步資料夾）。
2. 雙擊 `啟動儀表板.bat`。
   - 第一次執行會建立桌面捷徑與開機自動啟動。
   - 若要讓手機連線，會詢問一次管理員權限來開放區網防火牆；按「否」也不影響電腦本機使用。
   - 若電腦有 Claude Code 但還沒登入，畫面會引導用自己的帳號完成官方 OAuth 登入。

換新版：先雙擊舊資料夾的 `停止儀表板.bat`，解壓縮新版，再在新資料夾雙擊一次 `啟動儀表板.bat`。

> 兩種方式擇一使用就好；同時裝的話，開機自動啟動會以最後設定的那一個為準。

完整說明（右鍵選單、收合、資料來源、多人使用、安全設定）請看 [使用說明.md](使用說明.md)。

## 需求

- Windows 10 或 11
- 至少安裝並登入其中一個：Codex CLI、Claude Code（或內含 Claude Code 的 Claude 桌面版）、Antigravity
- GPU 溫度目前支援 NVIDIA 顯示卡（透過驅動內附的 `nvidia-smi`）

## 資料與隱私

- 每台電腦只讀取**自己**登入的帳號額度，不會讀取或上傳別人的資料。
- 額度直接向官方查詢：Codex 查 `chatgpt.com`，Claude 查 `api.anthropic.com`，Antigravity 只查本機執行中的 Antigravity 服務。不會把資料送到其他伺服器。
- 網頁儀表板只接受本機與同一區域網路的連線；可在 `.env` 設定 `ACCESS_KEY` 存取密碼。請勿設定路由器連接埠轉發把它公開到網際網路。

## 解除安裝

MSI 版：「設定 → 應用程式」解除安裝即可，捷徑與記錄檔會一併移除。可攜版：依序雙擊 `停止儀表板.bat`、`取消自動啟動.bat`、`關閉手機存取.bat`，再刪除資料夾與桌面上的「AI Usage Widget」捷徑。

## 從原始碼執行

需要 Node.js 20 以上（repo 不含可攜版內附的 `runtime/node.exe`，`start.ps1` 會改用系統安裝的 Node）。

```powershell
npm start      # 啟動伺服器（http://localhost:3456）
npm test       # 執行測試
powershell -STA -ExecutionPolicy Bypass -File .\widget.ps1   # 開啟桌面小工具
```

建置 MSI：安裝 WiX v5（`dotnet tool install --global wix --version 5.0.2`、`wix extension add --global WixToolset.Util.wixext/5.0.2`），把可攜版的 `node.exe` 放到 `runtime\`，再執行 `installer\build.ps1`，輸出在 `installer\out\`。

## 聲明

這是個人製作的非官方工具，與 OpenAI、Anthropic、Google 無關。各家的額度查詢方式並非公開 API，日後可能變動而導致無法顯示。

## 授權

[MIT](LICENSE)

# CLI 入口點

## 概述

`bin/nemoclaw.js` 是 NemoClaw 的使用者介面入口點，以 CommonJS Node.js 模組實作。核心邏輯正漸進遷移至 `src/lib/` 的 TypeScript 模組，`bin/lib/` 下的 CJS 模組逐步轉為薄 shim。

## 命令分派系統

### 全域命令

```
nemoclaw onboard          # Onboard 精靈（含第三方軟體接受）
nemoclaw list             # 列出已註冊沙箱（含即時閘道模型/提供者）
nemoclaw deploy           # 部署至遠端 GPU（實驗性，透過 Brev）
nemoclaw setup-spark      # DGX Spark 專用設定
nemoclaw start            # 啟動服務（Telegram Bridge 等）
nemoclaw stop             # 停止服務
nemoclaw status           # 全域狀態（沙箱列表 + 輔助服務）
nemoclaw debug [--quick] [--sandbox NAME] [--output PATH]  # 蒐集診斷資訊
nemoclaw uninstall [--yes] [--keep-openshell] [--delete-models]  # 解除安裝
nemoclaw help | --help    # 顯示說明
nemoclaw --version        # 顯示版本（從 git tag 衍生）
nemoclaw setup            # 已棄用，轉交至 onboard
```

### 沙箱範圍命令

```
nemoclaw <sandbox-name> connect       # 連線至沙箱 Shell
nemoclaw <sandbox-name> status        # 沙箱健康狀態 + 即時推論狀態
nemoclaw <sandbox-name> logs [--follow] # 串流日誌
nemoclaw <sandbox-name> policy-add    # 互動式策略選擇（支援數字序號）
nemoclaw <sandbox-name> policy-list   # 列出已套用策略
nemoclaw <sandbox-name> destroy [--yes|--force] # 刪除沙箱
```

### 分派流程

```javascript
// process.argv.slice(2) → [cmd, ...args]
// 1. 無命令 → 顯示說明
// 2. GLOBAL_COMMANDS 集合 → switch 分派
// 3. 非全域命令 → 視為 sandbox-name，第二參數為 action
// 4. 未知命令 → 錯誤訊息 + 建議
```

## 色彩輸出系統

```javascript
// 偵測色彩支援
_useColor = !process.env.NO_COLOR && !!process.stdout.isTTY
_tc = _useColor && (COLORTERM === "truecolor" || COLORTERM === "24bit")

// ANSI 色碼
G  = NVIDIA 品牌綠 (#76B900)     // Truecolor: \x1b[38;2;118;185;0m / 256色: \x1b[38;5;148m
B  = 粗體 (\x1b[1m)
D  = 暗淡 (\x1b[2m)
R  = 重設 (\x1b[0m)
RD = 紅色粗體 (\x1b[1;31m)       // 用於破壞性操作警告
YW = 黃色粗體 (\x1b[1;33m)       // 用於警告訊息
```

## 子模組詳解

### runner.js — 程序執行基元

三種執行模式：

| 函式 | stdio | 用途 | 回傳值 |
|------|-------|------|--------|
| `run(cmd, opts)` | ignore/inherit/inherit | 系統命令 | spawnSync result |
| `runInteractive(cmd, opts)` | inherit（保留 TTY） | 使用者互動操作 | spawnSync result |
| `runCapture(cmd, opts)` | pipe/pipe/pipe | 擷取輸出 | UTF-8 字串（trimmed） |

關鍵工具函式：

```javascript
shellQuote(value)
// 安全的 Shell 字串插值：用單引號包裹，轉義內嵌單引號

validateName(name, label = "name")
// RFC 1123 子域名規則驗證（最多 63 字元）
// 格式：^[a-z0-9]([a-z0-9-]*[a-z0-9])?$

exitWithSpawnResult(result)
// 將子程序結果轉換為退出碼（信號 → 128 + 信號編號）
```

機密脫敏（新增於 cb668d7）：

```javascript
// runner.js 新增 redactSecretPatterns() 函式
// 以正則比對 API key、token 等敏感字串
// 從 CLI 日誌與 error 輸出中脫敏
```

### credentials.js — 憑證管理

```
儲存位置：~/.nemoclaw/credentials.json（權限 0o600）
目錄權限：~/.nemoclaw/（權限 0o700）
```

| 函式 | 說明 |
|------|------|
| `loadCredentials()` | 讀取 JSON，失敗回傳空物件 |
| `saveCredential(key, value)` | 原子寫入，合併至現有憑證 |
| `getCredential(key)` | 優先順序：`process.env[key]` > `credentials.json[key]` |
| `prompt(question)` | 透過 stderr 的 readline 介面（不阻塞 stdout） |
| `ensureApiKey()` | 確保 NVIDIA_API_KEY 存在，驗證 `nvapi-` 前綴 |
| `ensureGithubToken()` | 確保 GITHUB_TOKEN 存在，嘗試 `gh auth token` |

安全強化：
- 拒絕不安全的 HOME fallback（bcb046c）：驗證 HOME 目錄的安全性
- 命令注入防護（f58e13a）：`isRepoPrivate()` 修復注入漏洞

管理的憑證：
- `NVIDIA_API_KEY` — 雲端推論必需
- `GITHUB_TOKEN` — 私有倉庫存取
- `BRAVE_API_KEY` — Brave Search 整合（新增）
- `TELEGRAM_BOT_TOKEN`、`DISCORD_BOT_TOKEN`、`SLACK_BOT_TOKEN` — 選用整合

### registry.js — 沙箱註冊表

```
儲存位置：~/.nemoclaw/sandboxes.json（權限 0o600）
結構：{ sandboxes: {name: {...}}, defaultSandbox: string|null }
寫入模式：原子寫入 + advisory file locking（新增於 a1a93c2）
```

沙箱條目結構：

```javascript
{
  name: string,                    // RFC 1123 名稱
  createdAt: string,               // ISO 時間戳
  model: string | null,            // 例如 "nvidia/nemotron-3-super-120b-a12b"
  nimContainer: string | null,     // 例如 "nemoclaw-nim-my-assistant"
  provider: string | null,         // "nvidia-nim" | "ollama-local" | "vllm-local"
  gpuEnabled: boolean,
  policies: string[]               // 已套用的預設集名稱
}
```

| 函式 | 說明 |
|------|------|
| `registerSandbox(entry)` | 註冊新沙箱，自動設為預設（若無） |
| `removeSandbox(name)` | 移除並重新分配預設沙箱 |
| `clearSandboxes()` | 閘道銷毀時清除全部（新增於 c3ee651） |
| `getDefault()` | 回傳預設沙箱名稱，失效時降級至第一個 |
| `listSandboxes()` | 回傳所有沙箱與預設名稱 |

### policies.js — 策略管理

```javascript
listPresets()           // 掃描 nemoclaw-blueprint/policies/presets/*.yaml
loadPreset(name)        // 讀取 YAML（含路徑穿越防護）
applyPreset(sandbox, preset)  // 結構化 YAML 解析合併
getAppliedPresets(sandbox)    // 從 registry 讀取 sandbox.policies
selectByNumber(presets)       // 以數字序號選擇預設集（新增於 494ecde）
```

YAML 合併邏輯（使用 `yaml` 套件結構化解析，取代原本的字串操作）：
1. 透過 `openshell policy get` 取得現有策略
2. 以 YAML 套件解析為結構化物件
3. 合併預設集條目至 `network_policies` 段落
4. 序列化並寫入暫存檔
5. `openshell policy set` 套用

### onboard.js — Onboard 精靈

**前置步驟：第三方軟體接受**
- 互動模式：顯示使用條款，要求輸入 `yes`
- 非互動模式：需 `--yes-i-accept-third-party-software` 或 `NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1`
- 接受狀態持久化至 `~/.nemoclaw/usage-notice.json`

**步驟 1：preflight()**
- Docker 運行檢查
- 容器運行時偵測（Colima / Docker Desktop）
- macOS podman 拒絕
- openshell CLI 檢查（缺少時自動安裝）
- **PATH 引導**：安裝 openshell 後顯示 `export PATH` 指令
- 過期閘道清理（跳過銷毀以保留 metadata）
- 埠可用性（8080 閘道、18789 面板）
- GPU 偵測
- 記憶體檢查與自動 swap（低記憶體 VM）

**步驟 2：startGateway(gpu)**
- 銷毀舊閘道（指數退避重試）
- `openshell gateway start --name nemoclaw`
- 健康檢查迴圈
- Colima CoreDNS 修補（WSL2 跳過）

**步驟 3：createSandbox(gpu)**
- 提示輸入沙箱名稱（無效時重新提示而非退出）
- RFC 1123 名稱驗證
- 分階段建置上下文（mkdtemp）
- `openshell sandbox create --from Dockerfile`
- 等待 Ready 狀態（30 次，每次 2 秒）
- 註冊至 registry

**步驟 4：setupNim(sandboxName, gpu)**
- 偵測可用提供者選項
- 互動式選擇或使用 `NEMOCLAW_PROVIDER` 環境變數
- 提供者選項：
  - **NVIDIA Endpoints**：NVIDIA 雲端推論
  - **OpenAI**：OpenAI API
  - **Anthropic**：Anthropic API
  - **Google Gemini**：Gemini API
  - **Other OpenAI-compatible**：vLLM、TensorRT-LLM 等自訂端點
  - **Other Anthropic-compatible**：自訂 Anthropic 端點
  - **Ollama**：本地推論（偵測到才出現，強制 chat completions API）
  - **NIM**（實驗性）：依 GPU VRAM 過濾模型
  - **vLLM**（實驗性）：自動偵測模型 ID
- Brave Search：若有 `BRAVE_API_KEY` 則設定

**步驟 5：setupInference(sandboxName, model, provider)**
- 建立 openshell provider
- 設定推論路由 `openshell inference set`
- Ollama/vLLM/NIM-local 強制使用 chat completions API
- NVIDIA 提供者新增 skipVerify
- 驗證邏輯分類（`src/lib/validation.ts`）

**步驟 6：setupOpenclaw(sandboxName, model, provider)**
- 產生 config.json
- 透過管線寫入沙箱 `openshell sandbox connect < script`
- Dashboard 轉發設定（等待就緒）

**步驟 7：setupPolicies(sandboxName)**
- 建議預設集：pypi, npm
- 自動偵測：Telegram/Slack/Discord Bot Token、Brave API Key
- 互動式或使用 `NEMOCLAW_POLICY_MODE`
- 未知預設集名稱時重新提示

### 非互動模式環境變數

| 變數 | 用途 |
|------|------|
| `NEMOCLAW_NON_INTERACTIVE=1` | 啟用非互動模式 |
| `NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1` | 接受第三方軟體（非互動必需） |
| `NEMOCLAW_PROVIDER` | 推論提供者 (cloud/ollama/vllm/nim/custom) |
| `NEMOCLAW_MODEL` | 模型 ID |
| `NEMOCLAW_ENDPOINT_URL` | 自訂端點 URL |
| `NEMOCLAW_SANDBOX_NAME` | 沙箱名稱 |
| `NEMOCLAW_RECREATE_SANDBOX=1` | 允許重建已存在的沙箱 |
| `NEMOCLAW_POLICY_MODE` | 策略模式 (suggested/custom/skip) |
| `NEMOCLAW_POLICY_PRESETS` | 逗號分隔的預設集清單 |
| `NEMOCLAW_EXPERIMENTAL=1` | 啟用 NIM + vLLM 選項 |
| `BRAVE_API_KEY` | Brave Search API 金鑰 |
| `COMPATIBLE_API_KEY` | OpenAI 相容端點 API 金鑰 |
| `COMPATIBLE_ANTHROPIC_API_KEY` | Anthropic 相容端點 API 金鑰 |

### 新增 TypeScript 模組（src/lib/）

| 模組 | 說明 |
|------|------|
| `usage-notice.ts` | 第三方軟體接受流程：互動/非互動、版本追蹤、OSC 8 超連結 |
| `web-search.ts` | Brave Search 設定：Docker build arg 編碼、安全警告 |
| `preflight.ts` | 埠檢查（`probePortAvailability`）、記憶體偵測（`getMemoryInfo`）、swap 管理（`ensureSwap`） |
| `validation.ts` | 驗證失敗分類（`classifyValidationFailure`、`classifySandboxCreateFailure`）、`isSafeModelId` |
| `url-utils.ts` | URL 安全解析與驗證 |
| `dashboard.ts` | Dashboard 轉發管理 |
| `build-context.ts` | Docker build 上下文組裝 |
| `gateway-state.ts` | 閘道狀態管理 |
| `debug.ts` | 診斷蒐集（原 `scripts/debug.sh`） |
| `services.ts` | 服務管理（原 `scripts/start-services.sh`） |
| `inference-config.ts` | 推論提供者設定映射 |
| `local-inference.ts` | Ollama/vLLM 工具函式 |
| `nim.ts` | NIM 容器管理 |
| `onboard-session.ts` | Onboard 會話管理 |
| `runtime-recovery.ts` | 閘道生命週期復原 |
| `chat-filter.ts` | ALLOWED_CHAT_IDS 過濾 |
| `resolve-openshell.ts` | OpenShell 路徑解析 |
| `version.ts` | 版本解析（從 git tag 衍生） |

### 版本管理（version.js / version.ts）

**提交 39e9b1f**：CLI 版本從 git tag 衍生而非硬編碼的 `package.json`。

```
安裝時：install.sh 將 release tag 寫入 ~/.nemoclaw/version
執行時：version.ts 讀取 ~/.nemoclaw/version 或 fallback 至 git describe
pre-commit hook：check-version-tag-sync.sh 驗證 tag 與 package.json 一致
```

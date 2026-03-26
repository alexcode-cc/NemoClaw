# CLI 入口點

## 概述

`bin/nemoclaw.js` 是 NemoClaw 的使用者介面入口點，以零外部相依的 Node.js ESM 模組實作。所有子功能模組位於 `bin/lib/`。

## 命令分派系統

### 全域命令

```
nemoclaw onboard          # 七步驟 Onboard 精靈
nemoclaw list             # 列出已註冊沙箱
nemoclaw deploy           # 部署至遠端 GPU
nemoclaw setup            # 執行 Host 端設定腳本
nemoclaw setup-spark      # DGX Spark 專用設定
nemoclaw start            # 啟動服務（Telegram Bridge 等）
nemoclaw stop             # 停止服務
nemoclaw status           # 全域狀態
nemoclaw debug            # 蒐集診斷資訊
nemoclaw uninstall        # 解除安裝
nemoclaw help | --help    # 顯示說明
nemoclaw --version        # 顯示版本
```

### 沙箱範圍命令

```
nemoclaw <sandbox-name> connect       # 連線至沙箱 Shell
nemoclaw <sandbox-name> status        # 沙箱健康狀態 + NIM 狀態
nemoclaw <sandbox-name> logs [--follow] # 串流日誌
nemoclaw <sandbox-name> policy-add    # 互動式策略選擇
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
// shellQuote("it's") → "'it'\\''s'"
// shellQuote("test; rm -rf /") → "'test; rm -rf /'"

validateName(name, label = "name")
// RFC 1123 子域名規則驗證
// 規則：必填、字串型別、最多 63 字元
// 格式：^[a-z0-9]([a-z0-9-]*[a-z0-9])?$
// 禁止 Shell 元字元和路徑穿越

exitWithSpawnResult(result)
// 將子程序結果轉換為退出碼
// 信號 → 128 + 信號編號
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

管理的憑證：
- `NVIDIA_API_KEY` — 雲端推論必需
- `GITHUB_TOKEN` — 私有倉庫存取
- `TELEGRAM_BOT_TOKEN`、`DISCORD_BOT_TOKEN`、`SLACK_BOT_TOKEN` — 選用整合

### registry.js — 沙箱註冊表

```
儲存位置：~/.nemoclaw/sandboxes.json（權限 0o600）
結構：{ sandboxes: {name: {...}}, defaultSandbox: string|null }
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
| `getDefault()` | 回傳預設沙箱名稱，失效時降級至第一個 |
| `listSandboxes()` | 回傳所有沙箱與預設名稱 |

### nim.js — NIM 容器管理

支援的模型（`nim-images.json`）：

| 模型 | 映像 | 最低 GPU 記憶體 |
|------|------|-----------------|
| nvidia/nemotron-3-super-120b-a12b | nvcr.io/nim/nvidia/nemotron-3-super-120b-a12b | 40 GB |
| nvidia/nemotron-3-nano-30b-a3b | nvcr.io/nim/nvidia/nemotron-3-nano（注意：非完整模型名稱） | 8 GB |
| nvidia/llama-3.1-nemotron-70b-instruct | nvcr.io/nim/nvidia/llama-3.1-nemotron-70b-instruct | 80 GB |
| nvidia/llama-3.3-nemotron-super-49b-v1 | nvcr.io/nim/nvidia/llama-3.3-nemotron-super-49b-v1 | 24 GB |
| meta/llama-3.1-8b-instruct | nvcr.io/nim/meta/llama-3.1-8b-instruct | 16 GB |

GPU 偵測邏輯：

| 平台 | 偵測方式 | nimCapable |
|------|----------|------------|
| NVIDIA GPU | `nvidia-smi` 查詢記憶體 | true |
| DGX Spark (GB10) | `nvidia-smi` 名稱 + `free -m` 統一記憶體 | true (spark=true) |
| Apple Silicon | `system_profiler SPDisplaysDataType` | false |

容器生命週期：

```javascript
pullNimImage(model)          // docker pull
startNimContainer(name, model, port=8000)  // docker run -d --gpus all --shm-size 16g
waitForNimHealth(port, timeout=300)        // 輪詢 /v1/models，每 5 秒一次
stopNimContainer(name)       // docker stop + rm
nimStatus(name)              // 回傳 {running, healthy, container, state}
```

### policies.js — 策略管理

```javascript
listPresets()           // 掃描 nemoclaw-blueprint/policies/presets/*.yaml
loadPreset(name)        // 讀取 YAML（含路徑穿越防護）
applyPreset(sandbox, preset)  // 取得現有策略 → 合併預設集 → 寫入暫存檔 → openshell policy set
getAppliedPresets(sandbox)    // 從 registry 讀取 sandbox.policies
```

YAML 合併邏輯：
1. 透過 `openshell policy get` 取得現有策略
2. 移除 openshell 元資料標頭（Version, Hash）
3. 找到 `network_policies:` 段落
4. 在下一個頂層鍵之前插入預設集條目
5. 若段落不存在，附加新段落

### onboard.js — Onboard 精靈

七步驟流程的詳細說明：

**步驟 1：preflight()**
- Docker 運行檢查
- 容器運行時偵測（Colima / Docker Desktop）
- macOS podman 拒絕
- openshell CLI 檢查（缺少時自動安裝）
- **PATH 引導**：安裝 openshell 後，若 binary 目錄不在 PATH 中，顯示 `export PATH` 指令與 shell profile 提示（`getFutureShellPathHint()` 函式）
- 過期閘道清理
- 埠可用性（8080 閘道、18789 面板）
- GPU 偵測

**步驟 2：startGateway(gpu)**
- 銷毀舊閘道
- `openshell gateway start --name nemoclaw`
- 健康檢查迴圈
- Colima CoreDNS 修補

**步驟 3：createSandbox(gpu)**
- 提示輸入沙箱名稱（或使用 `NEMOCLAW_SANDBOX_NAME`）
- RFC 1123 名稱驗證
- 分階段建置上下文（mkdtemp）
- `openshell sandbox create --from Dockerfile`
- 等待 Ready 狀態（30 次，每次 2 秒）
- 註冊至 registry

**步驟 4：setupNim(sandboxName, gpu)**
- 偵測可用提供者選項
- 互動式選擇或使用 `NEMOCLAW_PROVIDER` 環境變數
- NIM：依 GPU VRAM 過濾模型、拉取映像、啟動容器、等待健康
- Ollama：啟動（若未運行）、選擇模型
- vLLM：**自動偵測模型 ID**，查詢 `http://localhost:8000/v1/models` 端點，解析 JSON 回應取得實際模型名稱（透過 `isSafeModelId()` 驗證安全字元），取代原本硬編碼的 "vllm-local" 模型名稱
- Cloud：`ensureApiKey()`、選擇模型

**步驟 5：setupInference(sandboxName, model, provider)**
- 建立 openshell provider
- 設定推論路由 `openshell inference set`
- Ollama 專屬：模型驗證與預熱

**步驟 6：setupOpenclaw(sandboxName, model, provider)**
- 產生 config.json
- 透過管線寫入沙箱 `openshell sandbox connect < script`

**步驟 7：setupPolicies(sandboxName)**
- 建議預設集：pypi, npm
- 自動偵測：Telegram/Slack/Discord Bot Token
- 互動式或使用 `NEMOCLAW_POLICY_MODE`

### 非互動模式環境變數

| 變數 | 用途 |
|------|------|
| `NEMOCLAW_NON_INTERACTIVE=1` | 啟用非互動模式 |
| `NEMOCLAW_PROVIDER` | 推論提供者 (cloud/ollama/vllm/nim) |
| `NEMOCLAW_MODEL` | 模型 ID |
| `NEMOCLAW_SANDBOX_NAME` | 沙箱名稱 |
| `NEMOCLAW_RECREATE_SANDBOX=1` | 允許重建已存在的沙箱 |
| `NEMOCLAW_POLICY_MODE` | 策略模式 (suggested/custom/skip) |
| `NEMOCLAW_POLICY_PRESETS` | 逗號分隔的預設集清單 |
| `NEMOCLAW_EXPERIMENTAL=1` | 啟用 NIM + vLLM 選項 |

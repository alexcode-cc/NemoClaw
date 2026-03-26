# TypeScript 插件

## 概述

`nemoclaw/` 目錄包含 NemoClaw 的 OpenClaw 插件實作，負責三個核心功能：

1. **Slash 指令**：`/nemoclaw status|eject|onboard|help`
2. **推論提供者**：向 OpenClaw 註冊 NVIDIA 推論後端
3. **工作區遷移**：Host ↔ Sandbox 之間的狀態搬移

## 插件註冊（index.ts）

### 匯出型別

```typescript
// 設定容器
interface OpenClawConfig { /* 最小化 stub */ }

// 日誌介面
interface PluginLogger {
  info(msg: string): void;
  warn(msg: string): void;
  error(msg: string): void;
  debug(msg: string): void;
}

// 指令上下文
interface PluginCommandContext {
  senderId: string;
  channel: string;
  isAuthorizedSender: boolean;
  args: string;
  commandBody: string;
  config: OpenClawConfig;
  from: string;
  to: string;
  accountId: string;
}

// 指令定義
interface PluginCommandDefinition {
  name: string;
  description: string;
  acceptsArgs: boolean;
  requireAuth: boolean;
  handler: (ctx: PluginCommandContext, api: OpenClawPluginApi) => Promise<PluginCommandResult>;
}

// 推論提供者
interface ProviderPlugin {
  id: string;
  label: string;
  docsPath: string;
  aliases: string[];
  envVars: string[];
  models: ModelProviderConfig;
  auth: ProviderAuthMethod[];
}

// 模型目錄
interface ModelProviderConfig {
  chat: ModelProviderEntry[];
  completion: ModelProviderEntry[];
}

interface ModelProviderEntry {
  id: string;
  label: string;
  contextWindow: number;   // 131072
  maxOutput: number;        // 4096-8192
}
```

### 註冊流程

```typescript
export default function register(api: OpenClawPluginApi): void {
  // 1. 註冊 Slash 指令
  api.registerCommand("nemoclaw", {
    description: "NemoClaw 沙箱管理指令",
    acceptsArgs: true,
    requireAuth: false,
    handler: handleSlashCommand
  });

  // 2. 載入 Onboard 設定
  const onboardCfg = loadOnboardConfig();
  const credentialEnv = onboardCfg?.credentialEnv ?? "NVIDIA_API_KEY";

  // 3. 註冊推論提供者
  const provider = registeredProviderForConfig(onboardCfg, credentialEnv);
  api.registerProvider(provider);

  // 4. 輸出啟動橫幅
  api.logger.info(formatBanner(onboardCfg));
}
```

### 模型目錄策略

```typescript
function activeModelEntries(onboardCfg): ModelProviderEntry[] {
  if (onboardCfg?.model) {
    // 自訂模型：使用 Onboard 設定中的單一模型
    return [{ id: onboardCfg.model, label: onboardCfg.model, contextWindow: 131072, maxOutput: 4096 }];
  }
  // 預設：硬編碼的 Nemotron 模型清單
  return [
    { id: "nvidia/nemotron-3-super-120b-a12b", label: "Nemotron 3 Super 120B", contextWindow: 131072, maxOutput: 8192 },
    // ...其他 Nemotron 模型
  ];
}
```

### 設定提取

```typescript
interface NemoClawConfig {
  blueprintVersion: string;    // 預設 "latest"
  blueprintRegistry: string;   // 預設 "ghcr.io/nvidia/nemoclaw-blueprint"
  sandboxName: string;         // 預設 "openclaw"
  inferenceProvider: string;   // 預設 "nvidia"
}

function getPluginConfig(api: OpenClawPluginApi): NemoClawConfig {
  // 從 api.pluginConfig 提取，含型別驗證與預設值合併
}
```

## Slash 指令處理器（slash.ts）

### 指令分派

```typescript
async function handleSlashCommand(ctx, _api): Promise<PluginCommandResult> {
  const subcommand = ctx.args?.trim().split(/\s+/)[0];
  switch (subcommand) {
    case "status":  return slashStatus();
    case "eject":   return slashEject();
    case "onboard": return slashOnboard();
    default:        return slashHelp();
  }
}
```

### 子指令

| 子指令 | 說明 | 資料來源 |
|--------|------|----------|
| `status` | 最後動作、Blueprint 版本、Run ID、沙箱名稱、更新時間、遷移快照 | `loadState()` |
| `eject` | 顯示回滾指示（需要 migrationSnapshot 或 hostBackupPath） | `loadState()` |
| `onboard` | 顯示 Onboard 狀態（端點、提供者、模型、憑證、日期）或設定指示 | `loadOnboardConfig()` |
| `help` | 列出所有子指令說明 | 靜態文字 |

## Onboard 設定（onboard/config.ts）

### 資料結構

```typescript
type EndpointType = "build" | "ncp" | "nim-local" | "vllm" | "ollama" | "custom";

interface NemoClawOnboardConfig {
  endpointType: EndpointType;
  endpointUrl: string;
  ncpPartner: string | null;
  model: string;
  profile: string;
  credentialEnv: string;
  provider?: string;
  providerLabel?: string;
  onboardedAt: string;          // ISO 時間戳
}
```

### 儲存

```
目錄：~/.nemoclaw/（延遲建立）
檔案：~/.nemoclaw/config.json
```

### 端點描述對映

| endpointType | 描述 |
|-------------|------|
| `build` | NVIDIA Endpoint API |
| `ncp` | NVIDIA Cloud Partner |
| `nim-local` | Local NVIDIA NIM |
| `vllm` | Local vLLM Server |
| `ollama` | Local Ollama |
| `custom` | Custom Endpoint |
| URL 含 `inference.local` | Managed Inference Route |

## 插件狀態（blueprint/state.ts）

```typescript
interface NemoClawState {
  lastRunId: string | null;
  lastAction: string | null;
  blueprintVersion: string | null;
  sandboxName: string | null;
  migrationSnapshot: string | null;   // 快照路徑
  hostBackupPath: string | null;      // Host 備份路徑
  createdAt: string | null;           // ISO，首次儲存時設定
  updatedAt: string;                  // ISO，每次儲存時更新
}
```

儲存於 `~/.nemoclaw/state/nemoclaw.json`，使用延遲目錄建立（stateDirCreated 旗標）。

## 工作區遷移系統（migration-state.ts）

這是整個插件中最大的模組（約 800 行），實作完整的 Host ↔ Sandbox 遷移流程。

### 核心型別

```typescript
type MigrationRootKind = "workspace" | "agentDir" | "skillsExtraDir";

interface MigrationExternalRoot {
  id: string;                     // slugified 識別碼
  kind: MigrationRootKind;
  label: string;
  sourcePath: string;             // Host 上的原始路徑
  snapshotRelativePath: string;   // 快照內的相對路徑
  sandboxPath: string;            // 沙箱內的目標路徑
  symlinkPaths: string[];         // 目錄內的符號連結列表
  bindings: MigrationRootBinding[];
}

interface HostOpenClawState {
  exists: boolean;
  homeDir: string;
  stateDir: string;
  configDir: string;
  configPath: string;
  workspaceDir: string;
  extensionsDir: string;
  skillsDir: string;
  hooksDir: string;
  externalRoots: MigrationExternalRoot[];
  warnings: string[];
  errors: string[];
  hasExternalConfig: boolean;
}

interface SnapshotManifest {
  version: number;                // SNAPSHOT_VERSION = 2
  createdAt: string;
  homeDir: string;
  stateDir: string;
  configPath: string;
  hasExternalConfig: boolean;
  externalRoots: MigrationExternalRoot[];
  warnings: string[];
}
```

### 遷移流程

#### 1. 偵測 Host 狀態

```typescript
function detectHostOpenClaw(env): HostOpenClawState
```

- 解析環境變數：`OPENCLAW_HOME`（支援 `~/` 展開）、`OPENCLAW_STATE_DIR`、`OPENCLAW_CONFIG_PATH`、`OPENCLAW_PROFILE`
- 檢查 state/config 目錄是否存在
- 蒐集外部根目錄（工作區、Agent 目錄、Skills 搜尋路徑）
- 過濾 stateDir 內的路徑（不需遷移）
- 偵測 extensions/skills/hooks 目錄
- 驗證並產生警告（符號連結、缺少的目錄、無效設定）

#### 2. 蒐集外部根目錄

```typescript
function collectExternalRoots(config, stateDir): { roots, warnings, errors }
```

- 掃描設定中的 agent workspaces、agentDirs、skills extraDirs
- 以正規化路徑去重（`normalizeHostPath`：Windows 上轉小寫）
- 多個 binding 指向同一路徑時合併
- `registerRoot()` 執行去重與合併邏輯

#### 3. 建立快照

```typescript
function createSnapshotBundle(hostState, logger, { persist }): SnapshotBundle | null
```

- 建立快照目錄結構
- 複製 state 目錄內容
- 若 `hasExternalConfig`，複製外部設定檔
- 複製所有外部根目錄
- 寫入 manifest（`snapshot.json`）
- 準備沙箱狀態（`prepareSandboxState`）：修補設定中的路徑為沙箱路徑
- 回傳 `SnapshotBundle` 或 null（發生錯誤時）

#### 4. 還原至 Host

```typescript
function restoreSnapshotToHost(snapshotDir, logger): boolean
```

**安全關鍵函式：**
- 驗證 manifest 路徑在信任根目錄內（`isWithinRoot` + `resolveHostHome()`）
- 尊重 `OPENCLAW_STATE_DIR` / `OPENCLAW_CONFIG_PATH` 覆蓋
- Fail-closed：`hasExternalConfig=true` 要求有效的 configPath
- 還原前封存現有狀態
- 回傳布林成功狀態

#### 5. 建立封存

```typescript
function createArchiveFromDirectory(sourceDir, archivePath): void
```

使用 `tar` 套件建立封存：portable 模式、不含 mtime、不跟隨符號連結。

### 路徑處理與安全

| 函式 | 用途 |
|------|------|
| `resolveHostHome(env)` | 解析 `OPENCLAW_HOME`，支援 `~/` 展開 |
| `resolveUserPath(input, env)` | 解析 `~/` 路徑與絕對路徑 |
| `normalizeHostPath(input)` | Windows 上轉小寫正規化 |
| `isWithinRoot(candidate, root)` | 路徑包含檢查（安全驗證） |
| `slugify(input)` | 轉小寫 kebab-case（用於目錄命名） |

### 常數

```typescript
SANDBOX_MIGRATION_DIR = "/sandbox/.nemoclaw/migration"
SNAPSHOT_VERSION = 2
```

## 編譯設定（tsconfig.json）

| 選項 | 值 | 說明 |
|------|------|------|
| target | ES2022 | 支援 top-level await、class fields |
| module | Node16 | 支援 ESM + CJS 互操作 |
| strict | true | 所有嚴格檢查 |
| declaration + declarationMap | true | 產生 .d.ts 與 source map |
| outDir | dist | 編譯輸出目錄 |
| rootDir | src | 原始碼根目錄 |
| exclude | src/**/*.test.ts | 測試檔案不編譯 |

## ESLint 規則（eslint.config.mjs）

主要規則集：`@typescript-eslint/strict-type-checked`

| 規則 | 等級 |
|------|------|
| `no-explicit-any` | error |
| `no-unused-vars`（`_` 前綴除外） | error |
| `no-floating-promises` | error |
| `no-require-imports` | error |
| `consistent-type-imports` | error |

測試檔案覆蓋：關閉 `unsafe-assignment`、`unsafe-member-access`、`unsafe-return`、`unbound-method`。

## 相依套件

| 套件 | 版本 | 用途 |
|------|------|------|
| `commander` | ^13.1.0 | CLI 引數解析 |
| `json5` | ^2.2.3 | 支援註解的 JSON 解析（openclaw.json） |
| `tar` | ^7.0.0 | 工作區快照封存 |
| `yaml` | ^2.4.0 | Blueprint YAML 解析 |

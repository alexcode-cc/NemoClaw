# TypeScript Blueprint

## 概述

NemoClaw 的 Blueprint 編排邏輯原本以 Python 實作（`nemoclaw-blueprint/orchestrator/`），已於 PR #772 全面遷移至 TypeScript（`nemoclaw/src/blueprint/`）。`nemoclaw-blueprint/` 目錄僅保留靜態資產：`blueprint.yaml`（Blueprint 清單）與 `policies/`（網路策略定義）。

## 編排器（blueprint/runner.ts）

### 進度通訊協定

runner.ts 透過 stdout 訊號行與上層呼叫者通訊：

| 訊號 | 格式 | 說明 |
|------|------|------|
| 進度 | `PROGRESS:<0-100>:<label>` | 即時進度更新 |
| 執行 ID | `RUN_ID:<id>` | 格式：`nc-{YYYYMMDD-HHMMSS}-{8字元UUID}` |
| 完成 | exit code 0 | 成功 |
| 失敗 | exit code ≠ 0 | 錯誤 |

### CLI 介面

```bash
# 透過編譯後的 JS 呼叫
node nemoclaw/dist/blueprint/runner.js <action> [options]

# 動作
plan      # 驗證輸入並產生部署計畫
apply     # 建立沙箱、設定推論、儲存狀態
status    # 查詢執行狀態
rollback  # 停止沙箱、清理狀態

# 選項
--profile <name>       # 推論設定檔（預設：default）
--plan <path>          # 計畫 JSON 路徑（apply 時使用）
--run-id <id>          # 執行 ID（status/rollback 時使用）
--json                 # JSON 輸出
--dry-run              # 僅模擬，不執行
--endpoint-url <url>   # 覆蓋端點 URL（經 SSRF 驗證）
```

### SSRF 防護（blueprint/ssrf.ts）

獨立模組，提供 `validateEndpointUrl(url)` 函式，包含三層驗證：

1. **Scheme 白名單**：僅允許 `https` 和 `http`
2. **私有 IP 範圍封鎖**：
   - IPv4：127.0.0.0/8、10.0.0.0/8、172.16.0.0/12、192.168.0.0/16、169.254.0.0/16
   - IPv6：::1/128、fd00::/8
   - IPv4-mapped IPv6：`::ffff:10.0.0.1` 等格式
3. **DNS 重綁定防護**：解析所有地址並驗證不屬於私有 IP 範圍

整合點：在 `action_plan()` 和 `action_apply()` 中呼叫，同時驗證 CLI `--endpoint-url` 覆蓋和 Blueprint 設定檔中定義的端點。

**測試：** `nemoclaw/src/blueprint/ssrf.test.ts`（178 行）

### 動作函式

#### action_plan()

驗證輸入並產生部署計畫：

```typescript
async function actionPlan(profile: string, blueprint: Blueprint, options: PlanOptions): Promise<Plan>
// 1. 發出 RUN_ID
// 2. 驗證 profile 存在於 blueprint 中
// 3. 檢查 openshell CLI 可用性
// 4. 解析沙箱設定（image, name, forward_ports）
// 5. 解析推論設定（provider_type, provider_name, endpoint, model, credential_env）
// 6. SSRF 驗證端點 URL（包括 blueprint 定義的端點）
// 7. 輸出 JSON 計畫至 stdout
// 8. 持久化時剝離 credential_env 和 credential_default
```

#### action_apply()

依序執行五個階段：

| 進度 | 階段 | 動作 |
|------|------|------|
| 20% | 建立沙箱 | `openshell sandbox create --from <image> --name <name>` |
| 50% | 設定推論提供者 | `openshell provider create --name <name> --type <type>` |
| 70% | 設定推論路由 | `openshell inference set --provider <name> --model <model>` |
| 85% | 儲存執行狀態 | 寫入 `~/.nemoclaw/state/runs/<run_id>/plan.json` |
| 100% | 完成 | 記錄完成訊息 |

重要安全設計：
- 憑證透過環境變數名稱傳遞（`--credential OPENAI_API_KEY`），而非直接傳值
- `credential_env` 和 `credential_default` 在持久化的 `plan.json` 中剝離
- 子程序透過 `execa` 執行，使用 `reject: false` 處理預期的失敗
- Blueprint 定義的端點也經 SSRF 驗證（不僅限於 CLI 覆蓋）

#### action_status() / action_rollback()

與 Python 版本行為相同，查詢/清理執行紀錄。

**測試：** `nemoclaw/src/blueprint/runner.test.ts`（648 行）

## 遷移快照（blueprint/snapshot.ts）

### 常數

```typescript
const SNAPSHOTS_DIR = path.join(homedir(), ".nemoclaw", "snapshots");
const SNAPSHOT_VERSION = 3;  // v3 新增 Blueprint 摘要驗證
```

### 快照版本演進

| 版本 | 變更 |
|------|------|
| v2 | 基礎快照格式 |
| v3 | 新增 `blueprintDigest` 欄位（SHA-256）；還原時驗證摘要一致性 |

### 函式

#### createSnapshotBundle()

捕捉 Host 端 OpenClaw 設定：

1. 建立時間戳目錄
2. 遞迴複製 `~/.openclaw` 目錄樹
3. **過濾敏感檔案**：`auth-profiles.json` 從快照中排除
4. **剝離閘道設定**：sandbox `openclaw.json` 中的 auth token 被移除
5. 計算 Blueprint 檔案的 SHA-256 摘要
6. 產生 manifest（`snapshot.json`）

#### restoreSnapshotToHost()

安全還原流程：

1. 驗證 manifest 路徑在信任根目錄內（`isWithinRoot()`）
2. **v3 摘要驗證**：若 manifest 版本 ≥ 3，驗證 `blueprintDigest` 一致性（fail-closed）
3. 還原前封存現有狀態
4. 大小寫不敏感的 basename 比對（`CREDENTIAL_SENSITIVE_BASENAMES`），防止 Windows 大小寫變體繞過
5. rollback 失敗時還原封存的 `.openclaw` 目錄

#### listSnapshots()

列出所有可用快照（反向時間排序），驗證 manifest 結構有效性。

**測試：** `nemoclaw/src/blueprint/snapshot.test.ts`（288 行）

## Blueprint 清單（blueprint.yaml）

```yaml
version: "0.1.0"
min_openshell_version: "0.1.0"
min_openclaw_version: "2026.3.0"
digest: ""                         # 發佈時計算
```

### 推論設定檔

| 設定檔 | 提供者類型 | 端點 | 預設模型 | 憑證 |
|--------|-----------|------|----------|------|
| `default` | nvidia | integrate.api.nvidia.com/v1 | nemotron-3-super-120b-a12b | — |
| `ncp` | nvidia | 動態指定 | nemotron-3-super-120b-a12b | NVIDIA_API_KEY |
| `nim-local` | openai | nim-service.local:8000/v1 | nemotron-3-super-120b-a12b | NIM_API_KEY |
| `vllm` | openai | localhost:8000/v1 | nemotron-3-nano-30b-a3b | OPENAI_API_KEY |

### 沙箱元件

```yaml
sandbox:
  image: "ghcr.io/nvidia/openshell-community/sandboxes/openclaw:latest"
  name: "openclaw"
  forward_ports:
    - 18789                        # Dashboard 面板
```

## 與 Python 版本的差異

| 項目 | Python 版本 | TypeScript 版本 |
|------|-------------|-----------------|
| 子程序執行 | `subprocess.run(args)` | `execa(cmd, args, { reject: false })` |
| SSRF 驗證 | `ipaddress` 模組 | 自訂 IPv4/IPv6 解析（含 IPv4-mapped IPv6） |
| 快照版本 | v2 | v3（Blueprint 摘要驗證） |
| 憑證處理 | 環境變數名稱傳遞 | 同上 + plan.json 中剝離機密欄位 |
| 型別系統 | Pyright strict | TypeScript strict |
| 測試框架 | pytest（34 案例） | Vitest（1,114 行，三個測試檔案） |
| 套件管理 | uv + PyYAML | npm + execa |

## 已刪除的 Python 檔案

以下檔案已在 PR #772 中刪除：

- `nemoclaw-blueprint/orchestrator/runner.py`
- `nemoclaw-blueprint/orchestrator/test_endpoint_validation.py`
- `nemoclaw-blueprint/orchestrator/__init__.py`
- `nemoclaw-blueprint/migrations/snapshot.py`
- `nemoclaw-blueprint/pyproject.toml`
- `nemoclaw-blueprint/uv.lock`
- `nemoclaw-blueprint/Makefile`
- `scripts/write-auth-profile.py`（改為 `scripts/write-auth-profile.ts`）

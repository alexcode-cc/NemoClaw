# Python Blueprint

## 概述

`nemoclaw-blueprint/` 是 NemoClaw 的 Python 元件，負責沙箱編排、遷移快照管理與安全策略定義。使用 `uv` 管理相依套件，Ruff + Pyright 確保程式碼品質。

## 編排器（orchestrator/runner.py）

### 子程序通訊協定

runner.py 透過 stdout 訊號行與父程序（TypeScript 插件）通訊：

| 訊號 | 格式 | 說明 |
|------|------|------|
| 進度 | `PROGRESS:<0-100>:<label>` | 即時進度更新 |
| 執行 ID | `RUN_ID:<id>` | 格式：`nc-{YYYYMMDD-HHMMSS}-{8字元UUID}` |
| 完成 | exit code 0 | 成功 |
| 失敗 | exit code ≠ 0 | 錯誤 |

### CLI 介面

```bash
python runner.py <action> [options]

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

### 端點 URL 驗證（SSRF 防護）

`validate_endpoint_url(url)` 函式在 `action_plan()` 和 `action_apply()` 中呼叫，防止 SSRF 攻擊：

```python
def validate_endpoint_url(url: str) -> str:
    """驗證三層防護：
    1. Scheme 白名單：僅 https/http
    2. 私有 IP 範圍封鎖：127/8, 10/8, 172.16/12, 192.168/16, 169.254/16, ::1, fd00::/8
    3. DNS 重綁定防護：socket.getaddrinfo() 解析所有地址並驗證
    """
```

私有網路定義於 `_PRIVATE_NETWORKS` 常數，使用 `ipaddress` 模組進行範圍比對。

測試：`orchestrator/test_endpoint_validation.py`（34 個 pytest 案例，使用 mock DNS 避免真實網路呼叫）。

### 動作函式

#### action_plan()

驗證輸入並產生部署計畫：

```python
def action_plan(profile, blueprint, *, dry_run=False, endpoint_url=None) -> dict:
    # 1. 發出 RUN_ID
    # 2. 驗證 profile 存在於 blueprint 中
    # 3. 檢查 openshell CLI 可用性
    # 4. 解析沙箱設定（image, name, forward_ports）
    # 5. 解析推論設定（provider_type, provider_name, endpoint, model, credential_env）
    # 6. 允許 endpoint_url 覆蓋
    # 7. 輸出 JSON 計畫至 stdout
```

計畫結構：

```python
{
    "run_id": str,
    "profile": str,
    "sandbox": {
        "image": str,
        "name": str,
        "forward_ports": [int]
    },
    "inference": {
        "provider_type": str,      # "nvidia" | "openai"
        "provider_name": str,      # "nvidia-inference" | "nim-local" | "vllm-local"
        "endpoint": str,           # API 端點 URL
        "model": str,              # 模型 ID
        "credential_env": str      # 憑證環境變數名稱
    },
    "policy_additions": dict,
    "dry_run": bool
}
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
- 避免憑證出現在 `ps aux` 的命令列引數中
- 支援 `credential_default` 回退值（例如 vLLM 測試用的 "dummy"）

#### action_status()

```python
def action_status(rid=None):
    # 若指定 rid，載入特定執行紀錄
    # 否則，找到最新的執行紀錄（反向時間排序）
    # 輸出 plan.json 內容
```

#### action_rollback()

```python
def action_rollback(rid):
    # 30%：openshell sandbox stop <name>
    # 60%：openshell sandbox remove <name>
    # 90%：寫入 rolled_back 時間戳標記
    # 100%：完成
```

### 工具函式

```python
run_cmd(args, *, check=True, capture=False)
# 安全子程序執行：永遠使用 argv list（不用 shell=True）

openshell_available() -> bool
# 檢查 openshell 是否在 PATH 上
```

## 遷移快照（migrations/snapshot.py）

### 常數

```python
HOME = Path.home()
OPENCLAW_DIR = HOME / ".openclaw"
NEMOCLAW_DIR = HOME / ".nemoclaw"
SNAPSHOTS_DIR = NEMOCLAW_DIR / "snapshots"
```

### 函式

#### create_snapshot() → Path | None

捕捉 Host 端 OpenClaw 設定：

1. 若 `~/.openclaw` 不存在，回傳 None
2. 建立時間戳目錄：`~/.nemoclaw/snapshots/{YYYYMMDDTHHMMSSZ}/`
3. 遞迴複製整個 `~/.openclaw` 目錄樹
4. 產生 manifest（`snapshot.json`）：

```python
{
    "timestamp": str,
    "source": str,           # ~/.openclaw 的絕對路徑
    "file_count": int,
    "contents": [str]        # 所有檔案的相對路徑
}
```

#### restore_into_sandbox(snapshot_dir, sandbox_name="openclaw") → bool

使用 `openshell sandbox cp` 將快照推送至沙箱內的 `/sandbox/.openclaw`。

#### cutover_host(snapshot_dir) → bool

遷移完成後封存 Host 設定：
- 將 `~/.openclaw` 移至 `~/.openclaw.pre-nemoclaw.{timestamp}`
- 標記遷移完成，防止衝突

#### rollback_from_snapshot(snapshot_dir) → bool

從快照還原 Host 設定：
- 若存在當前設定，先封存至 `~/.openclaw.nemoclaw-archived.{timestamp}`
- 將快照複製回 `~/.openclaw`

#### list_snapshots() → list[dict]

列出所有可用快照，回傳 manifest dict 列表（反向時間排序），每個 dict 額外包含 `path` 欄位。

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

NCP 設定檔的 `dynamic_endpoint: true` 表示端點 URL 在執行時動態提供。
vLLM 設定檔的 `credential_default: "dummy"` 表示開發/測試環境不需真實憑證。

### 沙箱元件

```yaml
sandbox:
  image: "ghcr.io/nvidia/openshell-community/sandboxes/openclaw:latest"
  name: "openclaw"
  forward_ports:
    - 18789                        # Dashboard 面板
```

### 策略新增

```yaml
policy:
  base: "sandboxes/openclaw/policy.yaml"
  additions:
    nim_service:
      name: nim_service
      endpoints:
        - host: "nim-service.local"
          port: 8000
          protocol: rest
```

## 相依套件與工具設定

### pyproject.toml

```toml
[project]
requires-python = ">=3.11"
dependencies = ["pyyaml>=6.0"]     # 唯一執行期相依

[tool.ruff]
target-version = "py311"
line-length = 100
```

### Ruff 規則

| 規則集 | 說明 | 備註 |
|--------|------|------|
| E, W | pycodestyle 錯誤與警告 | |
| F | pyflakes | |
| I | isort（import 排序） | |
| N | PEP 8 命名 | |
| UP | pyupgrade（Python 3.11+ 語法） | |
| B | flake8-bugbear（邏輯錯誤） | |
| S | flake8-bandit（安全問題） | |
| T20 | flake8-print（偵測 print） | 忽略 T201（允許刻意的 print） |
| SIM | flake8-simplify | |
| RUF | Ruff 專屬規則 | |

忽略規則：
- `T201`：允許 `print()`（CLI stdout 通訊需要）
- `S603`：`shell=False` 的 subprocess（已明確處理）
- `S607`：部分可執行路徑（openshell 預期在 PATH 上）

### Pyright

```toml
[tool.pyright]
pythonVersion = "3.11"
typeCheckingMode = "strict"
include = ["orchestrator", "migrations"]
```

### Makefile

```makefile
lint:    ruff check .
format:  ruff format . && ruff check --fix .
check:   ruff check . && ruff format --check . && uv run --with pyright pyright .
```

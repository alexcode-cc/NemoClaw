# NemoClaw 安裝指南：Ubuntu 24.04 + Ollama（含模型備援機制）

本文件提供在 Ubuntu 24.04（16 GB RAM）環境下，以 Ollama 作為模型服務提供者、`glm-5:cloud` 作為主要模型並配置多層備援鏈，從零開始安裝與設定 NemoClaw 的完整流程。

> **注意：** Ollama 對 NemoClaw 的支援目前仍為**實驗性質**。

## 目標環境

| 項目 | 規格 |
|------|------|
| 作業系統 | Ubuntu 24.04 LTS |
| RAM | 16 GB |
| 模型服務提供者 | Ollama |
| 主要模型 | `glm-5:cloud`（雲端路由模型，不需本地 VRAM） |
| 備援模型鏈 | minimax-m2.7:cloud → kimi-k2.5:cloud → qwen3.5:cloud → deepseek-v3.2:cloud → nemotron-3-super-120b-a12b |
| 容器運行時 | Docker |

### 模型備援機制

本安裝設定使用多層模型備援鏈，當主要模型不可用時自動切換至下一個備援模型，確保 Agent 持續可用：

```text
主要模型 → 備援 1 → 備援 2 → 備援 3 → 備援 4 → 備援 5（NVIDIA API）
glm-5      minimax    kimi      qwen3.5    deepseek    nemotron-3-super
:cloud     -m2.7      -k2.5     :cloud     -v3.2       -120b-a12b
           :cloud     :cloud               :cloud      (NVIDIA Endpoint)
```

| 順序 | 模型 | 提供者 | 類型 | 說明 |
|------|------|--------|------|------|
| 主要 | `glm-5:cloud` | Ollama | 雲端 | 推理與程式碼生成 |
| 備援 1 | `minimax-m2.7:cloud` | Ollama | 雲端 | 備選推理模型 |
| 備援 2 | `kimi-k2.5:cloud` | Ollama | 雲端 | 推理與程式碼生成 |
| 備援 3 | `qwen3.5:cloud` | Ollama | 雲端 | 397B 推理模型 |
| 備援 4 | `deepseek-v3.2:cloud` | Ollama | 雲端 | 推理模型 |
| 備援 5 | `nvidia/nemotron-3-super-120b-a12b` | NVIDIA API | 雲端 | 最終備援（需 NVIDIA_API_KEY） |

所有 `:cloud` 模型透過 Ollama 雲端路由執行，不需本地 GPU 或大量 VRAM，適合 16 GB RAM 環境。最終備援 `nemotron-3-super-120b-a12b` 透過 NVIDIA Endpoint API 執行，需要設定 `NVIDIA_API_KEY`。

## 前置條件檢查

在開始安裝前，請確認以下條件：

```bash
# 確認 Ubuntu 版本
lsb_release -a
# 預期輸出包含：Ubuntu 24.04

# 確認可用記憶體
free -h
# 預期：至少 16 GB 總記憶體

# 確認磁碟空間（至少 20 GB，建議 40 GB）
df -h /
```

## 第一步：安裝 Docker

NemoClaw 需要 Docker 作為容器運行時。

```bash
# 更新套件索引
sudo apt update

# 安裝必要套件
sudo apt install -y ca-certificates curl gnupg

# 新增 Docker 官方 GPG 金鑰
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# 新增 Docker 套件庫
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 安裝 Docker Engine
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 將當前使用者加入 docker 群組（避免每次都需要 sudo）
sudo usermod -aG docker $USER

# 套用群組變更（或登出再登入）
newgrp docker

# 驗證 Docker 安裝
docker info
```

確認 Docker 正在運行：

```bash
docker run --rm hello-world
```

## 第二步：安裝 Ollama

Ollama 必須在 NemoClaw 安裝程式執行之前已安裝且運行。

```bash
# 安裝 Ollama
curl -fsSL https://ollama.com/install.sh | sh

# 驗證安裝
ollama --version

# 安裝 Json 格式化工具
sudo apt update
sudo apt install -y jq
```

### 設定 Ollama 監聽位址

**這是關鍵步驟。** NemoClaw 的沙箱容器需要透過 `host.openshell.internal:11434` 存取 Ollama。預設情況下 Ollama 僅監聽 `127.0.0.1`，Docker 容器無法存取。必須設定為監聽 `0.0.0.0`。

```bash
# 建立 systemd override 檔案（比 systemctl edit 更可靠）
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
EOF

# 重新載入並重啟
sudo systemctl daemon-reload
sudo systemctl restart ollama

# 等待啟動
sleep 3
```

驗證 Ollama 正在監聽 `0.0.0.0:11434`：

```bash
# 確認監聽位址（應顯示 0.0.0.0:11434，而非 127.0.0.1:11434）
sudo ss -tlnp | grep 11434

# 確認 API 可回應
curl -sf http://localhost:11434/api/tags | jq
# 應回傳 JSON（即使 models 為空列表）
```

### 設定 UFW 防火牆（允許 Docker 容器存取 Ollama）

Ubuntu 24.04 預設啟用 UFW 防火牆，會阻擋 Docker 容器對 Host 埠的存取。即使 Ollama 已監聽 `0.0.0.0`，若未開放防火牆規則，容器仍無法連線。

```bash
# 檢查 UFW 狀態
sudo ufw status

# 若 UFW 啟用（Status: active），允許 Docker 網段存取 Ollama
sudo ufw allow from 172.16.0.0/12 to any port 11434 comment "Allow Docker containers to reach Ollama"
sudo ufw allow from 192.168.0.0/16 to any port 11434 comment "Allow Docker containers to reach Ollama"
```

### 驗證容器可達性

在繼續安裝之前，務必驗證 Docker 容器能存取 Host 端的 Ollama：

```bash
docker run --rm --add-host host.openshell.internal:host-gateway \
  curlimages/curl:8.10.1 -sf http://host.openshell.internal:11434/api/tags | jq
```

- **成功**：回傳 JSON（如 `{"models":[...]}`）→ 繼續下一步
- **失敗**：回頭檢查監聽位址與防火牆設定

### 拉取模型

拉取主要模型與所有備援模型：

```bash
# 主要模型
ollama pull glm-5:cloud

# 備援模型
ollama pull minimax-m2.7:cloud
ollama pull kimi-k2.5:cloud
ollama pull qwen3.5:cloud
ollama pull deepseek-v3.2:cloud
```

> **說明：** `:cloud` 模型為雲端路由，`ollama pull` 僅註冊模型定義，不會下載大型權重檔案。最終備援 `nemotron-3-super-120b-a12b` 透過 NVIDIA API 存取，無需 Ollama 拉取。

驗證模型已註冊：

```bash
ollama list
# 預期輸出包含 glm-5:cloud, minimax-m2.7:cloud, kimi-k2.5:cloud, qwen3.5:cloud, deepseek-v3.2:cloud
```

## 第三步：安裝 Node.js

NemoClaw 需要 Node.js 20+（建議 22）和 npm 10+。

```bash
# 方法一：使用 nvm（推薦）
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash

# 載入 nvm（或開新終端）
source ~/.bashrc

# 安裝 Node.js 22
nvm install 22

# 驗證版本
node --version    # 預期：v22.x.x
npm --version     # 預期：10.x.x 或更高
```

```bash
# 方法二：使用 apt（Ubuntu 24.04 可能版本較舊，建議用 nvm）
sudo apt install -y nodejs npm
node --version
npm --version
```

> **重要：** 若使用 nvm 安裝 Node.js，安裝後可能需要執行 `source ~/.bashrc` 或開啟新終端，使 PATH 生效。

## 第四步：安裝 NemoClaw

### 方法一：使用安裝腳本（推薦）

安裝腳本會自動處理所有步驟：安裝 Node.js（若缺少）、安裝 OpenShell CLI、安裝 NemoClaw CLI，然後啟動 Onboard 精靈。

使用非互動模式，指定 Ollama 作為提供者（主要模型為 `glm-5:cloud`）：

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
  NEMOCLAW_NON_INTERACTIVE=1 \
  NEMOCLAW_PROVIDER=ollama \
  NEMOCLAW_MODEL=glm-5:cloud \
  bash
```

如果偏好互動式安裝（有引導提示）：

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

互動模式中，在提供者選擇步驟選擇 "Ollama"，然後選擇 `glm-5:cloud` 模型。

> **注意：** Onboard 僅設定主要模型。備援模型鏈需在安裝完成後手動設定至 `openclaw.json`，詳見「第七步：設定模型備援鏈」。

### 方法二：從原始碼安裝

```bash
# 複製倉庫
git clone --depth 1 https://github.com/NVIDIA/NemoClaw.git
cd NemoClaw

# 套用客製化 Dockerfile（ollama 備援鏈 + Discord + .openclaw-data）
cp Dockerfile.default Dockerfile
cp Dockerfile.base-default Dockerfile.base
mkdir -p .openclaw-data

# 重建基底映像（升級 OpenClaw CLI 至 2026.3.24）
docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .

# 安裝根層級相依
npm install

# 建置 TypeScript 插件
cd nemoclaw && npm install && npm run build && cd ..

# 全域連結 CLI
npm link

# 驗證安裝
nemoclaw --version
```

> **注意：** 若 `nemoclaw` 命令找不到，嘗試：
>
> ```bash
> source ~/.bashrc
> # 或
> export PATH="$(npm config get prefix)/bin:$PATH"
> ```

## 第五步：執行 Onboard（若使用方法二安裝）

從原始碼安裝後，需要手動執行 Onboard：

### 非互動模式（推薦用於自動化）

非互動模式安裝完成後無模型備援機制

```bash
NEMOCLAW_NON_INTERACTIVE=1 \
NEMOCLAW_SANDBOX_NAME=my-assistant \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=glm-5:cloud \
NEMOCLAW_POLICY_MODE=suggested \
NEMOCLAW_RECREATE_SANDBOX=1 \
nemoclaw onboard --non-interactive
```

or

```bash
cd nemoclaw
NEMOCLAW_NON_INTERACTIVE=1 \
NEMOCLAW_SANDBOX_NAME=my-assistant \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=glm-5:cloud \
NEMOCLAW_POLICY_MODE=suggested \
NEMOCLAW_RECREATE_SANDBOX=1 \
./install.sh
```

> **說明：** `NEMOCLAW_RECREATE_SANDBOX=1` 允許在同名沙箱已存在時自動覆蓋重建，避免非互動模式因沙箱名稱衝突而失敗。Onboard 僅設定主要模型，備援鏈需在安裝完成後另行設定。

### 互動模式

```bash
nemoclaw onboard
```

互動模式會逐步引導你完成以下七個步驟。
非互動模式安裝完成後可以再用以下七個步驟來客製化(模型備援機制)。

## Onboard 七步驟詳解

### 步驟 1：環境檢查（Preflight）

自動檢查項目：

| 檢查項目 | 說明 | 失敗處理 |
|----------|------|----------|
| Docker 運行狀態 | `docker info` | 提示啟動 Docker |
| OpenShell CLI | `command -v openshell` | 自動安裝至 `~/.local/bin/` |
| 埠 8080 可用 | OpenShell 閘道 HTTP 埠 | 顯示佔用埠的程序與 PID |
| 埠 18789 可用 | NemoClaw Dashboard 埠 | 顯示佔用埠的程序與 PID |
| GPU 偵測 | `nvidia-smi` | 非必要，Ollama 雲端模型不需 GPU |

若 OpenShell 安裝至 `~/.local/bin/` 且該路徑不在 PATH 中，系統會顯示：

```text
ⓘ  openshell installed to ~/.local/bin
    Add it to your shell profile:  export PATH="$HOME/.local/bin:$PATH"
```

### 步驟 2：啟動 OpenShell 閘道

```bash
# 自動執行的命令：
openshell gateway start --name nemoclaw
```

- 銷毀舊閘道（若存在）
- 啟動新閘道
- 等待連線就緒（輪詢 `openshell status`，最多 5 次，每次間隔 2 秒）

### 步驟 3：建立沙箱

- **沙箱名稱**：預設 `my-assistant`（可透過 `NEMOCLAW_SANDBOX_NAME` 指定）
- **名稱規則**：小寫英數字 + 連字號，最長 63 字元，符合 RFC 1123
- 使用 Dockerfile 建置沙箱映像
- 等待沙箱狀態變為 "Ready"（最多 30 次輪詢，每次 2 秒）
- 設定 Dashboard 埠轉發（18789）
- 註冊至本地 registry

### 步驟 4：設定推論提供者

選擇 Ollama 時的處理流程：

1. **偵測 Ollama**：
   - 檢查 `ollama` 命令是否存在
   - 檢查 `http://localhost:11434/api/tags` 是否回應
2. **選擇模型**：使用指定的 `glm-5:cloud`
3. **啟動 Ollama**：若未運行，自動以背景模式啟動

   ```bash
   OLLAMA_HOST=0.0.0.0:11434 ollama serve > /dev/null 2>&1 &
   ```

### 步驟 5：設定推論路由

NemoClaw 建立 OpenShell 推論提供者並設定路由：

```bash
# 建立 Ollama 提供者（自動執行）
OPENAI_API_KEY=ollama \
openshell provider create --name ollama-local --type openai \
  --credential "OPENAI_API_KEY" \
  --config "OPENAI_BASE_URL=http://host.openshell.internal:11434/v1"

# 設定推論路由（自動執行）
openshell inference set --no-verify --provider ollama-local --model glm-5:cloud
```

關鍵設定說明：

| 項目 | 值 | 說明 |
|------|------|------|
| Provider 名稱 | `ollama-local` | OpenShell 內部識別名稱 |
| Provider 類型 | `openai` | Ollama 相容 OpenAI API 格式 |
| Base URL | `http://host.openshell.internal:11434/v1` | 容器內存取 Host 端 Ollama 的特殊 DNS |
| 憑證 | `OPENAI_API_KEY=ollama` | 虛擬值（Ollama 不需 API key） |
| 模型 | `glm-5:cloud` | 主要模型（備援鏈在步驟 8 設定） |

#### 容器網路路由

```text
沙箱容器 → host.openshell.internal:11434 → Host 的 Ollama (0.0.0.0:11434) → 雲端 API
```

`host.openshell.internal` 是 OpenShell 提供的特殊 DNS 名稱，透過 Docker 的 `--add-host host.openshell.internal:host-gateway` 機制將容器內的請求路由至 Host。

### 步驟 6：寫入沙箱設定

將以下設定寫入沙箱內的 `~/.nemoclaw/config.json`：

```json
{
  "endpointType": "custom",
  "endpointUrl": "https://inference.local/v1",
  "ncpPartner": null,
  "model": "glm-5:cloud",
  "profile": "inference-local",
  "credentialEnv": "OPENAI_API_KEY",
  "provider": "ollama-local",
  "providerLabel": "Local Ollama",
  "onboardedAt": "2026-03-25T..."
}
```

### 步驟 7：套用網路策略

預設建議套用的策略預設集：`pypi`、`npm`

```bash
# 非互動模式可透過環境變數指定：
NEMOCLAW_POLICY_MODE=suggested
# 或自訂：
NEMOCLAW_POLICY_PRESETS=pypi,npm,docker,huggingface,telegram,telegram,outlook
```

可用的策略預設集：

| 預設集 | 說明 | 允許的端點 |
|--------|------|------------|
| `pypi` | Python 套件安裝 | pypi.org, files.pythonhosted.org |
| `npm` | npm/Yarn 套件安裝 | registry.npmjs.org, registry.yarnpkg.com |
| `docker` | Docker 映像拉取 | registry-1.docker.io, nvcr.io |
| `huggingface` | Hugging Face Hub | huggingface.co, cdn-lfs.huggingface.co |
| `slack` | Slack API | slack.com, api.slack.com, hooks.slack.com |
| `telegram` | Telegram Bot API | api.telegram.org |
| `discord` | Discord API | discord.com, gateway.discord.gg |
| `jira` | Jira API | *.atlassian.net, api.atlassian.com |
| `outlook` | Microsoft Graph/Outlook | graph.microsoft.com, outlook.office365.com |

## 第六步：設定模型備援鏈

沙箱內的 `openclaw.json` 為唯讀（root:root, chmod 444），且沙箱內沒有 `sudo`，無法在運行時修改。正確做法是**在 Onboard 之前修改 Dockerfile**，讓備援鏈與 `ollama` 提供者定義在建置時直接寫入。

> **重要：** 僅修改 `agents.defaults.model` 的備援鏈是不夠的。OpenClaw 根據模型 ID 前綴（如 `ollama/`）查找 `models.providers` 中對應的提供者。若 `ollama` 提供者不存在，所有 `ollama/*` 模型都無法使用，會回退到預設的 `inference/nvidia/nemotron-3-super-120b-a12b`。

### 快捷方式：使用預建的客製化 Dockerfile

專案目錄下提供了已包含所有客製化設定的預建檔案，可直接覆蓋使用：

```bash
cd ~/NemoClaw  # 或你的 NemoClaw 原始碼目錄

# 覆蓋 Dockerfile（已含 ollama 提供者、備援鏈、Discord 插件、.openclaw-data 同步）
cp Dockerfile.default Dockerfile

# 覆蓋 Dockerfile.base（已升級 OpenClaw CLI 至 2026.3.24）
cp Dockerfile.base-default Dockerfile.base
```

> **說明：** 原始的 `Dockerfile` 和 `Dockerfile.base` 已從 Git 移除（列入 `.gitignore`），覆蓋後不會與遠端衝突。以下為手動修改的詳細說明，若使用預建檔案可跳至「重新建置基底映像並 Onboard」。

### 手動修改 Dockerfile.base 與 Dockerfile

NemoClaw 採用雙層 Dockerfile 架構：

- **`Dockerfile.base`** — 基底映像，包含 OpenClaw CLI 版本釘選、系統套件等較少變動的層。
- **`Dockerfile`** — 生產映像，包含插件、藍圖、設定產生腳本等隨部署變化的層。

設定 Ollama 備援鏈需要修改這兩個檔案。

#### 1. 升級 OpenClaw CLI 版本（Dockerfile.base）

開啟 `Dockerfile.base`，找到 `openclaw@` 版本行，將版本號改為 `2026.3.24`（或更新版本）：

```dockerfile
# 修改前
RUN npm install -g openclaw@2026.3.11 \
    && pip3 install --no-cache-dir --break-system-packages "pyyaml==6.0.3"

# 修改後
RUN npm install -g openclaw@2026.3.24 \
    && pip3 install --no-cache-dir --break-system-packages "pyyaml==6.0.3"
```

> **為何修改 Dockerfile.base？** OpenClaw CLI 版本釘選在基底映像中。過低的版本（如 2026.3.11）會導致 `node-llama-cpp` 預建二進位不相容，回退至從原始碼編譯而失敗。

#### 2. 加入 ollama 提供者與備援鏈（Dockerfile）

開啟 `Dockerfile`，找到 `RUN python3 -c` 設定產生區塊（約在檔案尾端）。這段 Python 腳本會在建置時產生 `openclaw.json`。需要修改其中三處：

**a. 在 `providers = {` 之前加入 `ollama_models` 列表定義：**

```python
ollama_models = [ \
    {'id': 'glm-5:cloud', 'name': 'GLM-5 Cloud', 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}, \
    {'id': 'minimax-m2.7:cloud', 'name': 'MiniMax M2.7 Cloud', 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}, \
    {'id': 'kimi-k2.5:cloud', 'name': 'Kimi K2.5 Cloud', 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}, \
    {'id': 'qwen3.5:cloud', 'name': 'Qwen3.5 Cloud', 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}, \
    {'id': 'deepseek-v3.2:cloud', 'name': 'DeepSeek V3.2 Cloud', 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}, \
]; \
```

**b. 將 `agents.defaults.model` 的 `primary` 改為 Ollama 模型，並加入 `fallbacks`：**

```python
# 修改前
'agents': {'defaults': {'model': {'primary': primary_model_ref}}}, \

# 修改後
'agents': {'defaults': {'model': {'primary': 'ollama/glm-5:cloud', 'fallbacks': ['ollama/minimax-m2.7:cloud', 'ollama/kimi-k2.5:cloud', 'ollama/qwen3.5:cloud', 'ollama/deepseek-v3.2:cloud', 'inference/nvidia/nemotron-3-super-120b-a12b']}}}, \
```

**c. 在 `providers` 字典中，於現有提供者之前加入 `ollama` 提供者：**

```python
# 修改前
providers = { \
    provider_key: { \

# 修改後
providers = { \
    'ollama': { \
        'baseUrl': inference_base_url, \
        'apiKey': 'ollama', \
        'api': 'openai-completions', \
        'models': ollama_models \
    }, \
    provider_key: { \
```

#### 3. 修改後的完整 Python 設定區塊

修改完成後，`Dockerfile` 中的 `RUN python3 -c` 區塊最終內容如下：

```dockerfile
RUN python3 -c "\
import base64, json, os, secrets; \
from urllib.parse import urlparse; \
model = os.environ['NEMOCLAW_MODEL']; \
chat_ui_url = os.environ['CHAT_UI_URL']; \
provider_key = os.environ['NEMOCLAW_PROVIDER_KEY']; \
primary_model_ref = os.environ['NEMOCLAW_PRIMARY_MODEL_REF']; \
inference_base_url = os.environ['NEMOCLAW_INFERENCE_BASE_URL']; \
inference_api = os.environ['NEMOCLAW_INFERENCE_API']; \
inference_compat = json.loads(base64.b64decode(os.environ['NEMOCLAW_INFERENCE_COMPAT_B64']).decode('utf-8')); \
parsed = urlparse(chat_ui_url); \
chat_origin = f'{parsed.scheme}://{parsed.netloc}' if parsed.scheme and parsed.netloc else 'http://127.0.0.1:18789'; \
origins = ['http://127.0.0.1:18789']; \
origins = list(dict.fromkeys(origins + [chat_origin])); \
ollama_models = [ \
    {'id': 'glm-5:cloud', 'name': 'GLM-5 Cloud', 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}, \
    {'id': 'minimax-m2.7:cloud', 'name': 'MiniMax M2.7 Cloud', 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}, \
    {'id': 'kimi-k2.5:cloud', 'name': 'Kimi K2.5 Cloud', 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}, \
    {'id': 'qwen3.5:cloud', 'name': 'Qwen3.5 Cloud', 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}, \
    {'id': 'deepseek-v3.2:cloud', 'name': 'DeepSeek V3.2 Cloud', 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}, \
]; \
providers = { \
    'ollama': { \
        'baseUrl': inference_base_url, \
        'apiKey': 'ollama', \
        'api': 'openai-completions', \
        'models': ollama_models \
    }, \
    provider_key: { \
        'baseUrl': inference_base_url, \
        'apiKey': 'unused', \
        'api': inference_api, \
        'models': [{**({'compat': inference_compat} if inference_compat else {}), 'id': model, 'name': primary_model_ref, 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}] \
    } \
}; \
config = { \
    'agents': {'defaults': {'model': {'primary': 'ollama/glm-5:cloud', 'fallbacks': ['ollama/minimax-m2.7:cloud', 'ollama/kimi-k2.5:cloud', 'ollama/qwen3.5:cloud', 'ollama/deepseek-v3.2:cloud', 'inference/nvidia/nemotron-3-super-120b-a12b']}}}, \
    'models': {'mode': 'merge', 'providers': providers}, \
    'channels': {'defaults': {'configWrites': False}}, \
    'gateway': { \
        'mode': 'local', \
        'controlUi': { \
            'allowInsecureAuth': True, \
            'dangerouslyDisableDeviceAuth': True, \
            'allowedOrigins': origins, \
        }, \
        'trustedProxies': ['127.0.0.1', '::1'], \
        'auth': {'token': secrets.token_hex(32)} \
    } \
}; \
path = os.path.expanduser('~/.openclaw/openclaw.json'); \
json.dump(config, open(path, 'w'), indent=2); \
os.chmod(path, 0o600)"
```

### .openclaw-data 自訂檔案注入

專案根目錄下的 `.openclaw-data/` 目錄用於存放需要注入沙箱的自訂檔案（skills、hooks、identity 等）。此目錄已排除在 Git 之外。

```bash
# 建立目錄結構（依需求選擇）
mkdir -p .openclaw-data/skills/my-skill
mkdir -p .openclaw-data/hooks
mkdir -p .openclaw-data/identity

# 範例：放入自訂 Skill
echo "Your skill content..." > .openclaw-data/skills/my-skill/SKILL.md

# 範例：放入 identity 檔案
echo "Your identity..." > .openclaw-data/identity/IDENTITY.md
```

**建置時注入**：Onboard 時 `.openclaw-data/` 的內容會透過 `Dockerfile` 的 `COPY` 指令自動複製至沙箱的 `/sandbox/.openclaw-data/`（可寫區域），在安全鎖定前完成。

**執行時同步（雙向）**：沙箱運行中可隨時在 Host 與沙箱之間雙向同步檔案，無需重建映像：

```bash
# Host → 沙箱：將 Host 端修改推送至運行中的沙箱
./scripts/sync-openclaw-data.sh my-assistant

# 沙箱 → Host：將沙箱內新建/修改的檔案拉回 Host 端
./scripts/pull-openclaw-data.sh my-assistant
```

> **重要：** 沙箱內建立的檔案（如新 Skill、修改的 Identity）**不會自動同步回 Host**。重建沙箱前務必先執行 `pull-openclaw-data.sh` 備份，否則沙箱內的變更會遺失。

> **為何不用 Docker bind mount？** OpenShell 管理容器生命週期，`openshell sandbox create` 不暴露 `-v` 參數。bind mount 也會繞過 Landlock 檔案系統安全策略，與 NemoClaw 的隔離設計衝突。

> **路徑長度限制：** OpenShell 使用 tar 打包 build context，路徑長度上限約 100 字元。`.openclaw-data/` 內**不要放置深層目錄結構**（如完整的 Git 倉庫、`node_modules`），否則建置時會出現 `provided value is too long when setting path` 錯誤。以下目錄會在建置時自動排除：`repositories/`、`node_modules/`、`.git/`、`__pycache__/`。
>
> **解決方法：先壓縮再進沙箱解壓。** 將深層子目錄壓縮成 `.tgz` 檔案後放入 `.openclaw-data/`，建置時只複製壓縮檔（路徑短），進入沙箱後再解壓：
>
> ```bash
> # 建置前：在 Host 端壓縮深層目錄
> cd .openclaw-data
> tar czf workspace.tgz workspace/
> rm -rf workspace/
>
> # 建置成功後：進入沙箱解壓
> nemoclaw my-assistant connect
> cd /sandbox/.openclaw-data
> tar xzf workspace.tgz && rm workspace.tgz
> ```
>
> 此方法安全可行，因為路徑長度限制**僅存在於建置階段**（tar 打包 build context），不影響沙箱運行：
>
> | 階段 | 機制 | 路徑限制 |
> |------|------|:--------:|
> | 建置時（`openshell sandbox create`） | tar 打包 → Docker build | 有（~100 字元） |
> | 運行時（沙箱內部） | 標準 Linux ext4 檔案系統 | 無（上限 4096 字元） |
> | 離開沙箱 / 重啟沙箱 | 從已建置的映像啟動，不重新 build | 無 |
>
> 只有**重新執行 `nemoclaw onboard` 重建沙箱映像**時才會再走一次 tar 打包流程。日常的沙箱啟動、停止、重新連線都不會觸發重新打包。

### 重新建置基底映像並 Onboard（套用變更）

由於修改了 `Dockerfile.base`，需先重建基底映像，再執行 Onboard：

```bash
# 重建基底映像（僅在修改 Dockerfile.base 後需要）
docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .

# 重新執行 Onboard 以重建沙箱映像
NEMOCLAW_NON_INTERACTIVE=1 \
NEMOCLAW_SANDBOX_NAME=my-assistant \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=glm-5:cloud \
NEMOCLAW_POLICY_MODE=suggested \
NEMOCLAW_RECREATE_SANDBOX=1 \
nemoclaw onboard --non-interactive
```

驗證設定已生效（需先連線至沙箱）：

```bash
nemoclaw my-assistant connect

# 在沙箱內執行
python3 -c "import json; c=json.load(open('/sandbox/.openclaw/openclaw.json')); print(json.dumps(c['agents']['defaults']['model'], indent=2))"
```

預期輸出：

```json
{
  "primary": "ollama/glm-5:cloud",
  "fallbacks": [
    "ollama/minimax-m2.7:cloud",
    "ollama/kimi-k2.5:cloud",
    "ollama/qwen3.5:cloud",
    "ollama/deepseek-v3.2:cloud",
    "inference/nvidia/nemotron-3-super-120b-a12b"
  ]
}
```

## 第七步：驗證安裝

安裝完成後，應看到以下摘要：

```text
──────────────────────────────────────────────────
Sandbox      my-assistant (Landlock + seccomp + netns)
Model        glm-5:cloud (Local Ollama)
──────────────────────────────────────────────────
Run:         nemoclaw my-assistant connect
Status:      nemoclaw my-assistant status
Logs:        nemoclaw my-assistant logs --follow
──────────────────────────────────────────────────

[INFO]  === Installation complete ===
```

### 驗證指令

```bash
# 檢查沙箱狀態
nemoclaw my-assistant status

# 列出已註冊沙箱
nemoclaw list
```

### 連線至沙箱

```bash
nemoclaw my-assistant connect
```

成功連線後，命令提示符變為 `sandbox@my-assistant:~$`。

### 測試推論

在沙箱內測試 Agent 回應：

```bash
# 修復設定：檢查openclaw設定是否正確
openclaw doctor
openclaw doctor --fix

# 方法一：開啟互動式 TUI
openclaw tui

# 方法二：單次訊息（適合驗證）
openclaw agent --agent main --local -m "hello" --session-id test
```

### 查看日誌

```bash
# 在 Host 端執行（非沙箱內）
nemoclaw my-assistant logs --follow
```

## 變更設定：增量更新 vs 完整重建

NemoClaw 的架構分為**閘道（Gateway）**和**沙箱（Sandbox）**兩層。並非所有設定變更都需要完整重建。以下矩陣幫助你判斷「改了什麼 → 最少需要做什麼」，節省測試時間。

### 架構理解：什麼在建置時固定、什麼可以執行時變更

| 層級 | 建置時固定（baked） | 執行時可變（runtime） |
|------|---------------------|----------------------|
| **閘道** | OpenShell 版本、K3s 叢集 | 推論提供者、憑證、推論路由 |
| **沙箱映像** | 插件程式碼、Blueprint、`openclaw.json`、Chat UI URL、`.openclaw-data` | 網路策略 |
| **沙箱容器** | 名稱 | `.openclaw-data/` 內的檔案（透過 upload） |

### 變更對照表

| 變更項目 | 最少操作 | 預估時間 | 需重建沙箱？ | 需重建閘道？ |
|----------|----------|----------|:------------:|:------------:|
| 切換推論模型或提供者 | `openshell inference set` | ~1 分鐘 | 否 | 否 |
| 更新 API 金鑰 | `openshell provider update` | ~1 分鐘 | 否 | 否 |
| 修改提供者端點 URL | `openshell provider update` | ~1 分鐘 | 否 | 否 |
| 新增/修改網路策略 | `openshell policy set` | ~1 分鐘 | 否 | 否 |
| 同步 `.openclaw-data/` 檔案 | `sync-openclaw-data.sh` | ~1 分鐘 | 否 | 否 |
| 修改插件程式碼或 Blueprint | 重建沙箱 | ~5-10 分鐘 | **是** | 否 |
| 修改 Dockerfile 的 Python 設定 | 重建沙箱 | ~5-10 分鐘 | **是** | 否 |
| 變更 Chat UI URL | 重建沙箱 | ~5-10 分鐘 | **是** | 否 |
| 變更沙箱名稱 | 重建沙箱 | ~5-10 分鐘 | **是** | 否 |
| 變更 Bot Token（Discord/Slack） | 重建沙箱 | ~5-10 分鐘 | **是** | 否 |
| 升級 OpenClaw CLI 版本 | 重建基底映像 + 沙箱 | ~10-15 分鐘 | **是** | 否 |
| 升級 OpenShell 版本 | 完整重建 | ~15-20 分鐘 | **是** | **是** |

### 操作等級詳解

#### 等級 0：執行時更新（無需重建，~1 分鐘）

適用於：切換模型、更新金鑰、調整網路策略、同步自訂檔案。

```bash
# ── 切換推論模型（不需重建沙箱）──
openshell inference set --no-verify \
  --provider ollama-local \
  --model "qwen3.5:cloud"

# 驗證
nemoclaw my-assistant status

# ── 更新 API 金鑰 ──
export NVIDIA_API_KEY=nvapi-new-key-here
openshell provider update nvidia-prod --credential "NVIDIA_API_KEY"

# ── 動態套用網路策略 ──
openshell policy set nemoclaw-blueprint/policies/presets/pypi.yaml

# ── 同步自訂檔案到運行中的沙箱 ──
./scripts/sync-openclaw-data.sh my-assistant
```

> **注意：** 網路策略和 TUI 核准的變更僅限當前會話，沙箱重啟後恢復為基礎策略。若需永久生效，請修改基礎策略後重建沙箱。

#### 等級 1：僅重建沙箱（保留閘道，~5-10 分鐘）

適用於：修改 Dockerfile 設定（模型備援鏈、Chat UI URL、Discord 插件）、更新插件程式碼、變更 Bot Token。

**這是最常用的重建操作。** 閘道保持運行，只需銷毀並重建沙箱。

```bash
cd ~/NemoClaw

# 若修改了 TypeScript 插件程式碼，先重新編譯
# cd nemoclaw && npm run build && cd ..

# 重建沙箱（閘道不受影響）
NEMOCLAW_NON_INTERACTIVE=1 \
NEMOCLAW_SANDBOX_NAME=my-assistant \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=glm-5:cloud \
NEMOCLAW_POLICY_MODE=suggested \
NEMOCLAW_RECREATE_SANDBOX=1 \
nemoclaw onboard --non-interactive
```

> **關鍵：** `NEMOCLAW_RECREATE_SANDBOX=1` 會自動銷毀同名舊沙箱並重建，無需手動 `nemoclaw my-assistant destroy`。閘道偵測到已存在時會跳過建立步驟。

#### 等級 2：重建基底映像 + 沙箱（~10-15 分鐘）

適用於：升級 OpenClaw CLI 版本、修改 `Dockerfile.base` 中的系統套件。

```bash
cd ~/NemoClaw

# 1. 重建基底映像
docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .

# 2. 重建沙箱（同等級 1）
NEMOCLAW_NON_INTERACTIVE=1 \
NEMOCLAW_SANDBOX_NAME=my-assistant \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=glm-5:cloud \
NEMOCLAW_POLICY_MODE=suggested \
NEMOCLAW_RECREATE_SANDBOX=1 \
nemoclaw onboard --non-interactive
```

#### 等級 3：完整重建閘道 + 沙箱（~15-20 分鐘）

**僅在以下情況需要：**
- 升級 OpenShell 版本
- 閘道損壞或 Docker volume 異常
- `openshell gateway start` 卡住或逾時

```bash
cd ~/NemoClaw

# 1. 銷毀閘道（會同時銷毀所有沙箱）
openshell gateway destroy -g nemoclaw
docker volume ls -q --filter "name=openshell-cluster-nemoclaw" | xargs -r docker volume rm

# 2. 完整重新 Onboard
NEMOCLAW_NON_INTERACTIVE=1 \
NEMOCLAW_SANDBOX_NAME=my-assistant \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=glm-5:cloud \
NEMOCLAW_POLICY_MODE=suggested \
nemoclaw onboard --non-interactive
```

> **警告：** 銷毀閘道會**刪除所有沙箱**。沙箱內未備份的檔案將遺失。建議先執行 `./scripts/backup-workspace.sh my-assistant` 備份工作區。

#### 等級 4：完整反安裝後重新安裝（最後手段）

**僅在以下極端情況需要：**
- 版本嚴重不相容，需要乾淨安裝
- Node.js / npm 環境損壞
- 要完全切換安裝方式（安裝腳本 ↔ 原始碼）

```bash
# 反安裝（保留 Docker 和 Ollama）
nemoclaw uninstall --yes

# 若需同時刪除 Ollama 模型
# nemoclaw uninstall --yes --delete-models
```

> **注意：** `nemoclaw uninstall` 會移除全域 npm 套件和 OpenShell CLI，導致 `nemoclaw` 指令不存在。重新安裝時請選擇以下任一方式。

**方式 A：從原始碼目錄重新安裝（推薦，最快）**

```bash
cd ~/NemoClaw  # 進入原始碼目錄（uninstall 不會刪除原始碼）

# 重新安裝全域 CLI 連結
npm install
npm link

# 套用客製化 Dockerfile（若尚未套用）
cp Dockerfile.default Dockerfile
cp Dockerfile.base-default Dockerfile.base

# 重建基底映像
docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .

# 重新 Onboard
NEMOCLAW_NON_INTERACTIVE=1 \
NEMOCLAW_SANDBOX_NAME=my-assistant \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=glm-5:cloud \
NEMOCLAW_POLICY_MODE=suggested \
nemoclaw onboard --non-interactive
```

**方式 B：使用原始碼目錄的 install.sh**

```bash
cd ~/NemoClaw

NEMOCLAW_NON_INTERACTIVE=1 \
NEMOCLAW_SANDBOX_NAME=my-assistant \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=glm-5:cloud \
NEMOCLAW_POLICY_MODE=suggested \
./install.sh
```

**方式 C：使用線上安裝腳本（完全乾淨安裝）**

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
  NEMOCLAW_NON_INTERACTIVE=1 \
  NEMOCLAW_PROVIDER=ollama \
  NEMOCLAW_MODEL=glm-5:cloud \
  bash
```

> **提示：** 方式 C 會重新 `git clone` 倉庫，若你有本地客製化（Dockerfile.default、.openclaw-data），需在 clone 完成後重新套用。

### 常見場景快速指南

| 場景 | 操作 | 等級 |
|------|------|:----:|
| 「我想試試不同的 Ollama 模型」 | `openshell inference set --provider ollama-local --model <model>` | 0 |
| 「pip install 被擋了」 | `openshell policy set nemoclaw-blueprint/policies/presets/pypi.yaml` | 0 |
| 「我改了 .openclaw-data/ 裡的 Skill」 | `./scripts/sync-openclaw-data.sh my-assistant` | 0 |
| 「我改了 Dockerfile 的備援模型鏈」 | `nemoclaw onboard` + `NEMOCLAW_RECREATE_SANDBOX=1` | 1 |
| 「我換了 DISCORD_BOT_TOKEN」 | 重新 `nemoclaw onboard` + `NEMOCLAW_RECREATE_SANDBOX=1` | 1 |
| 「我升級了 Dockerfile.base 的 OpenClaw 版本」 | `docker build -f Dockerfile.base` 然後 onboard | 2 |
| 「閘道壞了，重啟也沒用」 | `openshell gateway destroy` 然後 onboard | 3 |
| 「什麼都試過了，環境徹底壞掉」 | `nemoclaw uninstall --yes` 然後重新安裝 | 4 |

## 重新開機後恢復

OpenShell 閘道與沙箱埠轉發在系統重新開機後不會自動啟動，需要手動恢復或設定自動啟動。

> **重要：** 請勿使用 `openshell gateway start --name nemoclaw` 恢復，該指令會偵測到已停止的閘道並提示「Destroy and recreate?」，選擇 yes 會**銷毀所有已建立的沙箱**。正確做法是使用 `docker start` 重啟已停止的容器。

### 手動恢復

```bash
# 1. 確認 Docker 已啟動
sudo systemctl start docker

# 2. 確認 Ollama 已啟動（若使用本地推論）
sudo systemctl start ollama

# 3. 重啟已停止的閘道容器（不會銷毀沙箱）
docker start openshell-cluster-nemoclaw

# 4. 等待閘道內的 k3s 叢集完全就緒（關鍵步驟！）
#    docker start 只是啟動容器，k3s 需要額外 15-30 秒初始化。
#    直接執行 openshell 指令會出現 "tls handshake eof" 錯誤。
echo "等待閘道就緒..."
for i in $(seq 1 30); do
  openshell status 2>&1 | grep -q "Connected" && echo "✓ 閘道已就緒" && break
  sleep 2
  echo "  等待中... (${i}/30)"
done

# 5. 確認沙箱狀態
openshell sandbox list
# 若顯示 Ready，繼續下一步

# 6. 連線至沙箱
nemoclaw my-assistant connect
```

> **常見錯誤：`tls handshake eof`** — 這表示閘道容器已啟動但內部 k3s 叢集尚未就緒。**不要**在此時執行 `openshell forward start` 或其他 openshell 指令，等待 `openshell status` 顯示 `Connected` 後再繼續。通常需要 15-30 秒。

> **閘道容器命名規則：** OpenShell 閘道的 Docker 容器名稱為 `openshell-cluster-<gateway-name>`，本指南中為 `openshell-cluster-nemoclaw`。

> **若等待 60 秒仍未就緒：** 檢查容器日誌 `docker logs openshell-cluster-nemoclaw --tail 50`。若出現持續錯誤，可能需要等級 3 重建（見「變更設定：增量更新 vs 完整重建」）。

### 自動啟動（systemd 服務）

建立 systemd 服務，讓 OpenShell 閘道與埠轉發在開機時自動啟動。

#### 步驟 1：建立恢復腳本

```bash
sudo tee /usr/local/bin/nemoclaw-gateway-start.sh > /dev/null <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-openshell-cluster-nemoclaw}"
OPENSHELL_BIN="${OPENSHELL_BIN:-/home/${SUDO_USER:-$USER}/.local/bin/openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"
FORWARD_PORT="${FORWARD_PORT:-18789}"

# 等待 Docker 就緒
for i in $(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done

# 重啟已停止的閘道容器（保留沙箱）
docker start "$GATEWAY_CONTAINER" 2>&1 || true

# 等待閘道就緒
for i in $(seq 1 15); do
  "$OPENSHELL_BIN" status 2>&1 | grep -q "Connected" && break
  sleep 2
done

# 恢復埠轉發
"$OPENSHELL_BIN" forward start --background "$FORWARD_PORT" "$SANDBOX_NAME" 2>&1 || true

echo "NemoClaw gateway started, sandbox '$SANDBOX_NAME' port-forward on $FORWARD_PORT"
SCRIPT

sudo chmod +x /usr/local/bin/nemoclaw-gateway-start.sh
```

#### 步驟 2：建立 systemd 服務

將 `<your-username>` 替換為你的實際使用者名稱：

```bash
sudo tee /etc/systemd/system/nemoclaw-gateway.service > /dev/null <<'EOF'
[Unit]
Description=NemoClaw OpenShell Gateway
After=network-online.target docker.service ollama.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=GATEWAY_CONTAINER=openshell-cluster-nemoclaw
Environment=OPENSHELL_BIN=/home/<your-username>/.local/bin/openshell
Environment=SANDBOX_NAME=my-assistant
Environment=FORWARD_PORT=18789
ExecStart=/usr/local/bin/nemoclaw-gateway-start.sh
User=<your-username>
Group=docker

[Install]
WantedBy=multi-user.target
EOF
```

#### 步驟 3：啟用服務

```bash
sudo systemctl daemon-reload
sudo systemctl enable nemoclaw-gateway.service

# 立即測試（不需重新開機）
sudo systemctl start nemoclaw-gateway.service
sudo systemctl status nemoclaw-gateway.service

# 驗證
nemoclaw my-assistant connect
```

### 一鍵建立自動啟動（快速版）

將以上步驟合併為單一指令（替換 `alex` 為你的使用者名稱）：

```bash
# 建立恢復腳本
sudo tee /usr/local/bin/nemoclaw-gateway-start.sh > /dev/null <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-openshell-cluster-nemoclaw}"
OPENSHELL_BIN="${OPENSHELL_BIN:-/home/${SUDO_USER:-$USER}/.local/bin/openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"
FORWARD_PORT="${FORWARD_PORT:-18789}"
for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker start "$GATEWAY_CONTAINER" 2>&1 || true
for i in $(seq 1 15); do "$OPENSHELL_BIN" status 2>&1 | grep -q "Connected" && break; sleep 2; done
"$OPENSHELL_BIN" forward start --background "$FORWARD_PORT" "$SANDBOX_NAME" 2>&1 || true
SCRIPT
sudo chmod +x /usr/local/bin/nemoclaw-gateway-start.sh

# 建立 systemd 服務（替換 alex 為你的使用者名稱）
USERNAME="alex"
sudo tee /etc/systemd/system/nemoclaw-gateway.service > /dev/null <<EOF
[Unit]
Description=NemoClaw OpenShell Gateway
After=network-online.target docker.service ollama.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=GATEWAY_CONTAINER=openshell-cluster-nemoclaw
Environment=OPENSHELL_BIN=/home/${USERNAME}/.local/bin/openshell
Environment=SANDBOX_NAME=my-assistant
Environment=FORWARD_PORT=18789
ExecStart=/usr/local/bin/nemoclaw-gateway-start.sh
User=${USERNAME}
Group=docker

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now nemoclaw-gateway.service
```

## 埠使用說明

| 埠 | 服務 | 說明 |
|------|------|------|
| 8080 | OpenShell Gateway | 閘道 HTTP 服務 |
| 11434 | Ollama | 模型推論服務（Host 端） |
| 18789 | NemoClaw Dashboard | 沙箱 Dashboard 埠轉發 |

## 疑難排解

### 重新開機後無法連線沙箱

**症狀：**
- `nemoclaw my-assistant connect` 出現 `transport error` → `Connection refused (os error 111)`
- `openshell forward start` 出現 `tls handshake eof`

**原因：** OpenShell 閘道的 Docker 容器在重新開機後處於停止狀態，或容器已啟動但內部 k3s 叢集尚未完成初始化（需 15-30 秒）。

**解決：** 參閱上方「重新開機後恢復」章節的完整手動恢復流程。關鍵是 `docker start` 後**必須等待 `openshell status` 顯示 `Connected`** 才能執行後續指令。

```bash
docker start openshell-cluster-nemoclaw
# 等待 k3s 就緒（15-30 秒），不要立即執行 openshell 指令！
for i in $(seq 1 30); do
  openshell status 2>&1 | grep -q "Connected" && break
  sleep 2
done
nemoclaw my-assistant connect
```

> **警告：** 請勿使用 `openshell gateway start --name nemoclaw` 恢復，該指令會提示銷毀並重建閘道，導致所有沙箱遺失。若不慎已銷毀，需加上 `NEMOCLAW_RECREATE_SANDBOX=1` 重新執行 onboard。

### Ollama 連線問題：容器無法存取

**症狀：** "Local Ollama is responding on localhost, but containers cannot reach `http://host.openshell.internal:11434`"

**原因：** Ollama 僅監聽 `127.0.0.1`，Docker 容器透過 `host.openshell.internal`（映射至 Host IP）存取時被拒絕。

**排查步驟：**

#### 第一步：確認 Ollama 監聽位址

```bash
sudo ss -tlnp | grep 11434
```

- 若顯示 `127.0.0.1:11434` → 問題確認，Ollama 僅監聽 localhost
- 應顯示 `0.0.0.0:11434` 或 `*:11434`

#### 第二步：修正 Ollama 監聽設定

```bash
# 建立 systemd override 檔案
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
EOF

# 重新載入並重啟
sudo systemctl daemon-reload
sudo systemctl restart ollama

# 等待啟動後驗證監聽位址
sleep 3
sudo ss -tlnp | grep 11434
# 預期：0.0.0.0:11434
```

> **注意：** `sudo systemctl edit ollama.service` 也可達成相同效果，但上述方式更明確。

#### 第三步：手動測試容器可達性

```bash
docker run --rm --add-host host.openshell.internal:host-gateway \
  curlimages/curl:8.10.1 -sf http://host.openshell.internal:11434/api/tags
```

- 成功：回傳 JSON（如 `{"models":[...]}`）
- 失敗：繼續下一步

#### 第四步：檢查防火牆（若容器仍無法存取）

Ubuntu 24.04 預設啟用 UFW，可能阻擋 Docker 網段的流量：

```bash
# 檢查 UFW 狀態
sudo ufw status

# 若 UFW 啟用且阻擋，允許 Docker 網段存取 Ollama 埠
sudo ufw allow from 172.16.0.0/12 to any port 11434
sudo ufw allow from 192.168.0.0/16 to any port 11434

# 重新測試容器可達性
docker run --rm --add-host host.openshell.internal:host-gateway \
  curlimages/curl:8.10.1 -sf http://host.openshell.internal:11434/api/tags
```

#### 第五步：修復後重新執行 Onboard

```bash
NEMOCLAW_NON_INTERACTIVE=1 \
NEMOCLAW_SANDBOX_NAME=my-assistant \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=glm-5:cloud \
NEMOCLAW_POLICY_MODE=suggested \
NEMOCLAW_RECREATE_SANDBOX=1 \
nemoclaw onboard --non-interactive
```

> **提示：** 加入 `NEMOCLAW_RECREATE_SANDBOX=1` 允許覆蓋先前失敗時建立的同名沙箱。

### Ollama 未回應

**症狀：** "Local Ollama was selected, but nothing is responding on `http://localhost:11434`"

**解決：**

```bash
# 檢查 Ollama 服務狀態
sudo systemctl status ollama

# 若未運行，啟動服務
sudo systemctl start ollama

# 手動驗證
curl -sf http://localhost:11434/api/tags
```

### nemoclaw 命令找不到

**解決：**

```bash
# 若使用 nvm
source ~/.bashrc

# 或手動加入 PATH
export PATH="$(npm config get prefix)/bin:$HOME/.local/bin:$PATH"
```

### 埠被佔用

**症狀：** "Port 8080 is already in use"

**解決：**

```bash
# 找出佔用埠的程序
sudo lsof -i :8080
# 或
sudo ss -tlnp | grep 8080

# 終止佔用的程序（替換 <PID>）
kill <PID>
```

### Docker 權限問題

**症狀：** "permission denied while trying to connect to the Docker daemon socket"

**解決：**

```bash
sudo usermod -aG docker $USER
newgrp docker
# 或登出再登入
```

### 沙箱建置失敗：node-llama-cpp 編譯錯誤

**症狀：** Step 11 出現 `npm error [node-llama-cpp] Failed to build llama.cpp`、`cmake` 或 `make` 找不到。

**原因：** `openclaw` 版本過低（如 2026.3.11），其相依的 `node-llama-cpp` 預建二進位檔不相容當前平台，回退至從原始碼編譯，但 Docker 容器內缺少 `cmake` 和 `make` 等建置工具。

**解決：** 升級 `openclaw` 至最新版本。最快的方式是使用預建檔案：

```bash
cd NemoClaw

# 快捷方式：使用已升級至 2026.3.24 的預建檔案
cp Dockerfile.base-default Dockerfile.base
docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .
```

或手動修改：

```bash
# 更新 Dockerfile.base 中的 openclaw 版本（版本釘選在基底映像中）
# 將 openclaw@2026.3.11 改為 openclaw@2026.3.24
nano Dockerfile.base

# 更新 package.json 中的 openclaw 版本
nano package.json

# 重新安裝
npm install
```

若使用安裝腳本（`https://www.nvidia.com/nemoclaw.sh`），請確認拉取的是最新版倉庫。

### 沙箱建立逾時

**症狀：** 沙箱一直未達到 "Ready" 狀態

**解決：**

```bash
# 檢查 Docker 建置日誌
docker logs $(docker ps -q --filter name=nemoclaw) 2>&1 | tail -50

# 確認磁碟空間充足
df -h /

# 確認 Docker 映像拉取正常
docker images | grep openshell
```

### 從舊版 Husky 遷移

若倉庫之前使用 Husky 管理 Git Hooks，prek 可能無法正確安裝鉤子：

```bash
git config --unset core.hooksPath
npm install
```

### 沙箱內無法存取 Internet

**症狀：** 沙箱內的 Agent（如 Claude）嘗試存取外部網站時失敗，出現連線逾時、Connection refused 或 403 Forbidden 等錯誤。`curl`、`wget` 等工具也無法連線。

**原因：** 這是 NemoClaw 的**預設拒絕（deny-by-default）安全設計**，而非故障。沙箱的網路策略僅允許存取明確列入白名單的端點，所有未列入的連線都會被 OpenShell 攔截並封鎖。

#### 預設允許的端點

基礎策略（`nemoclaw-blueprint/policies/openclaw-sandbox.yaml`）僅允許以下端點：

| 策略 | 允許的端點 | 允許的二進位檔 |
|------|-----------|----------------|
| `claude_code` | api.anthropic.com, statsig.anthropic.com, sentry.io | claude |
| `nvidia` | integrate.api.nvidia.com, inference-api.nvidia.com | claude, openclaw |
| `github` | github.com, api.github.com | gh, git |
| `npm_registry` | registry.npmjs.org | openclaw, npm |
| `telegram` | api.telegram.org | node |
| `discord` | discord.com, gateway.discord.gg | node |

**未列入的端點（如 Google、Stack Overflow、任何自訂 API）一律被封鎖。**

此外，即使端點已列入白名單，**只有指定的二進位檔**才能存取。例如 `curl` 和 `wget` 不在任何策略的 binaries 清單中，因此即使目標端點已允許，這些工具也無法連線。

#### 解決方法一：即時核准（臨時，僅限當前會話）

透過 OpenShell TUI 即時核准被封鎖的請求：

```bash
# 開啟 TUI 監控面板
openshell term
```

TUI 會顯示被封鎖的請求（包含目標 host、port、發起的二進位檔），操作者可即時核准或拒絕。核准後的端點在沙箱重啟前有效。

#### 解決方法二：動態套用策略（臨時，僅限當前會話）

使用 OpenShell CLI 動態套用策略預設集或自訂策略：

```bash
# 套用預設集（例如允許 PyPI 套件安裝）
openshell policy set nemoclaw-blueprint/policies/presets/pypi.yaml

# 套用 npm 預設集
openshell policy set nemoclaw-blueprint/policies/presets/npm.yaml
```

可用的策略預設集：

| 預設集 | 允許的端點 | 用途 |
|--------|-----------|------|
| `pypi` | pypi.org, files.pythonhosted.org | Python 套件安裝 |
| `npm` | registry.npmjs.org, registry.yarnpkg.com | Node.js 套件安裝 |
| `docker` | registry-1.docker.io, nvcr.io | 容器映像拉取 |
| `huggingface` | huggingface.co, cdn-lfs.huggingface.co | ML 模型下載 |
| `slack` | slack.com, api.slack.com | Slack 整合 |
| `jira` | *.atlassian.net | Jira 整合 |
| `outlook` | graph.microsoft.com, outlook.office365.com | Outlook 整合 |

**注意：** 動態變更僅在當前會話有效，沙箱重啟後恢復為基礎策略。

#### 解決方法三：修改基礎策略（永久）

若需永久允許特定端點，編輯基礎策略檔案後重新 onboard：

```bash
# 編輯策略檔案
nano nemoclaw-blueprint/policies/openclaw-sandbox.yaml
```

在 `network_policies:` 區段新增端點，例如允許 `curl` 存取自訂 API：

```yaml
  my_custom_api:
    name: my_custom_api
    endpoints:
      - host: "api.example.com"
        port: 443
        protocol: rest
        enforcement: enforce
        tls: terminate
        rules:
          - allow:
              method: "*"
              path: "/**"
    binaries:
      - { path: /usr/bin/curl }
      - { path: /usr/local/bin/node }
```

然後重新執行 onboard 套用新策略：

```bash
nemoclaw onboard
```

#### 解決方法四：建立自訂策略預設集

將自訂端點寫成獨立的預設集 YAML 檔案，方便重複使用：

```bash
# 建立自訂預設集
cat > nemoclaw-blueprint/policies/presets/my-api.yaml << 'EOF'
my_custom_api:
  name: my_custom_api
  endpoints:
    - host: "api.example.com"
      port: 443
      protocol: rest
      enforcement: enforce
      tls: terminate
      access: full
  binaries:
    - { path: /usr/bin/curl }
    - { path: /usr/local/bin/node }
    - { path: /usr/local/bin/claude }
EOF

# 動態套用（臨時）
openshell policy set nemoclaw-blueprint/policies/presets/my-api.yaml

# 或合併至基礎策略後重新 onboard（永久）
```

#### 常見誤解

| 誤解 | 事實 |
|------|------|
| 「沙箱壞了，無法上網」 | 這是安全設計，非故障 |
| 「安裝 pypi/npm preset 就能自由上網」 | 預設集僅開放特定套件管理器的端點，不是通用 Internet 存取 |
| 「核准一次就永久生效」 | TUI 核准僅限當前會話，重啟後需重新核准或修改基礎策略 |
| 「任何程式都能存取白名單端點」 | 僅策略中列出的 binaries 可以存取，curl/wget 通常不在清單中 |

#### 相關指令速查

```bash
# 查看沙箱狀態與推論提供者
nemoclaw my-assistant status

# 開啟 TUI 監控
openshell term

# 查看當前策略
openshell policy get

# 動態套用策略
openshell policy set <policy-file>

# 列出已套用的策略預設集
nemoclaw my-assistant policy-list

# 互動式新增策略預設集
nemoclaw my-assistant policy-add
```

## 完整非互動安裝腳本（從零開始）

將以下內容儲存為 `setup-nemoclaw.sh`，可在全新的 Ubuntu 24.04 環境上一鍵完成所有安裝與設定。
腳本會自動處理 Docker、Ollama、UFW 防火牆、監聽位址、模型拉取、容器可達性驗證，以及 NemoClaw 安裝。

```bash
#!/usr/bin/env bash
set -euo pipefail

OLLAMA_MODEL="glm-5:cloud"
OLLAMA_FALLBACKS=("minimax-m2.7:cloud" "kimi-k2.5:cloud" "qwen3.5:cloud" "deepseek-v3.2:cloud")
SANDBOX_NAME="my-assistant"

echo "=== NemoClaw 從零安裝（Ubuntu 24.04 + Ollama + ${OLLAMA_MODEL} + 備援鏈）==="

# ─── 1. Docker ────────────────────────────────────────────────
echo "[1/7] 檢查 Docker..."
if ! command -v docker &>/dev/null; then
  echo "  安裝 Docker Engine..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  echo "  Docker 安裝完成。若當前 Shell 無法執行 docker，請執行 'newgrp docker' 或重新登入。"
fi
docker info >/dev/null 2>&1 || { echo "錯誤：Docker 未運行，請執行 'sudo systemctl start docker'"; exit 1; }
echo "  ✓ Docker 已就緒"

# ─── 2. Ollama ────────────────────────────────────────────────
echo "[2/7] 檢查 Ollama..."
if ! command -v ollama &>/dev/null; then
  echo "  安裝 Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
fi
echo "  ✓ Ollama 已安裝"

# ─── 3. 設定 Ollama 監聽 0.0.0.0 ──────────────────────────────
echo "[3/7] 設定 Ollama 監聽位址..."
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
EOF
sudo systemctl daemon-reload
sudo systemctl restart ollama
sleep 3

# 驗證監聽位址
if sudo ss -tlnp | grep -q '0.0.0.0:11434'; then
  echo "  ✓ Ollama 已監聽 0.0.0.0:11434"
else
  echo "  ⚠ Ollama 可能未正確監聽 0.0.0.0:11434，請檢查 'sudo ss -tlnp | grep 11434'"
fi

# ─── 4. UFW 防火牆 ────────────────────────────────────────────
echo "[4/7] 設定 UFW 防火牆..."
if sudo ufw status | grep -q "Status: active"; then
  sudo ufw allow from 172.16.0.0/12 to any port 11434 comment "Docker→Ollama" >/dev/null 2>&1 || true
  sudo ufw allow from 192.168.0.0/16 to any port 11434 comment "Docker→Ollama" >/dev/null 2>&1 || true
  echo "  ✓ UFW 已開放 Docker 網段存取 Ollama 埠"
else
  echo "  ✓ UFW 未啟用，跳過防火牆設定"
fi

# ─── 5. 拉取模型並驗證容器可達性 ───────────────────────────────
echo "[5/7] 拉取模型並驗證..."
ollama pull "${OLLAMA_MODEL}"
for fb in "${OLLAMA_FALLBACKS[@]}"; do
  ollama pull "$fb"
done
echo "  ✓ 主要模型與備援模型已就緒"

echo "  驗證 Docker 容器可存取 Ollama..."
if docker run --rm --add-host host.openshell.internal:host-gateway \
  curlimages/curl:8.10.1 -sf http://host.openshell.internal:11434/api/tags &>/dev/null; then
  echo "  ✓ 容器可達性驗證通過"
else
  echo "  ✖ 容器無法存取 Ollama！請檢查："
  echo "    1. sudo ss -tlnp | grep 11434  → 應顯示 0.0.0.0:11434"
  echo "    2. sudo ufw status             → 若啟用，需允許 172.16.0.0/12 存取 11434"
  exit 1
fi

# ─── 6. 套用客製化 Dockerfile（ollama 提供者 + 備援鏈 + Discord）─
echo "[6/7] 套用客製化 Dockerfile..."
NEMOCLAW_DIR=""
for candidate in "$HOME/NemoClaw" "$HOME/nemo-claw" "/opt/NemoClaw"; do
  if [ -f "$candidate/Dockerfile.default" ]; then
    NEMOCLAW_DIR="$candidate"
    break
  fi
done
if [ -n "$NEMOCLAW_DIR" ] && [ -f "$NEMOCLAW_DIR/Dockerfile.default" ]; then
  cp "$NEMOCLAW_DIR/Dockerfile.default" "$NEMOCLAW_DIR/Dockerfile"
  cp "$NEMOCLAW_DIR/Dockerfile.base-default" "$NEMOCLAW_DIR/Dockerfile.base"
  # 建立 .openclaw-data 目錄（若不存在）
  mkdir -p "$NEMOCLAW_DIR/.openclaw-data"
  # 重建基底映像
  cd "$NEMOCLAW_DIR"
  docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .
  echo "  ✓ 已套用客製化 Dockerfile（ollama + 備援鏈 + Discord + .openclaw-data）"
else
  echo "  ⚠ 找不到 Dockerfile.default，請手動參照安裝指南「第六步」修改"
fi

# ─── 7. 安裝 NemoClaw（使用修改後的 Dockerfile）───────────────
echo "[7/7] 安裝 NemoClaw..."
curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
  NEMOCLAW_NON_INTERACTIVE=1 \
  NEMOCLAW_SANDBOX_NAME="${SANDBOX_NAME}" \
  NEMOCLAW_PROVIDER=ollama \
  NEMOCLAW_MODEL="${OLLAMA_MODEL}" \
  NEMOCLAW_POLICY_MODE=suggested \
  NEMOCLAW_POLICY_PRESETS=pypi,npm \
  NEMOCLAW_RECREATE_SANDBOX=1 \
  bash

echo ""
echo "=== 安裝完成 ==="
echo "主要模型：${OLLAMA_MODEL}"
echo "備援模型：minimax-m2.7:cloud → kimi-k2.5:cloud → qwen3.5:cloud → deepseek-v3.2:cloud → nemotron-3-super-120b-a12b"
echo "連線沙箱：nemoclaw ${SANDBOX_NAME} connect"
echo "檢查狀態：nemoclaw ${SANDBOX_NAME} status"
echo "串流日誌：nemoclaw ${SANDBOX_NAME} logs --follow"
```

## Discord 頻道設定

NemoClaw 沙箱已預設允許 Discord 網路端點（discord.com、gateway.discord.gg、cdn.discordapp.com）。但 Discord 插件設定需寫入 `openclaw.json`，而此檔案在沙箱內為唯讀，因此必須在**建置 Dockerfile 時一併寫入**。

### 步驟 1：建立 Discord Bot

1. 前往 [Discord Developer Portal](https://discord.com/developers/applications)
2. 點擊 **New Application**，輸入名稱（例如 `MyOpenClaw`）
3. 左側選單點 **Bot** → **Add Bot**
4. 複製 **Token**（僅顯示一次，請妥善保存）
5. 啟用 **MESSAGE CONTENT INTENT**（Bot → Privileged Gateway Intents）

### 步驟 2：邀請 Bot 到伺服器

1. 在 Developer Portal 左側選 **OAuth2** → **URL Generator**
2. Scopes 勾選 `bot` 和 `applications.commands`
3. Bot Permissions 勾選：
   - Send Messages
   - Read Messages/View Channels
   - Embed Links
   - Add Reactions
4. 複製生成的 URL，用瀏覽器開啟並選擇目標伺服器

### 步驟 3：確認 Dockerfile 已啟用 Discord 插件

若已使用預建的 `Dockerfile.default`（見「第六步：快捷方式」），Discord 插件**已預設啟用**，可跳過此步驟。

若手動修改 Dockerfile，開啟 `Dockerfile`，找到 `RUN python3 -c` 設定產生區塊中的 `config = {` 字典。在 `'channels'` 鍵之前加入 `'plugins'` 設定：

```python
# 修改前
    'channels': {'defaults': {'configWrites': False}}, \

# 修改後
    'plugins': {'entries': {'discord': {'enabled': True}}}, \
    'channels': {'defaults': {'configWrites': False}}, \
```

> **說明：**
>
> - Discord Bot Token **不寫入** `openclaw.json`，而是透過 `DISCORD_BOT_TOKEN` 環境變數在沙箱建立時傳入
> - 修改位置在 `Dockerfile` 的 `config` 字典定義中，`'channels'` 行之前

### 步驟 4：設定 Token 並重新 Onboard

> **重要：** `DISCORD_BOT_TOKEN` 必須在執行 onboard **之前**設定。onboard 過程中會讀取此環境變數並傳入沙箱。若未設定，沙箱內將無法存取 Token。

```bash
# 設定 Discord Bot Token 環境變數（必須在 onboard 之前）
export DISCORD_BOT_TOKEN="你的_BOT_TOKEN"

# 驗證環境變數已設定
echo $DISCORD_BOT_TOKEN

# 重新 Onboard（Token 作為環境變數傳入沙箱）
NEMOCLAW_NON_INTERACTIVE=1 \
NEMOCLAW_SANDBOX_NAME=my-assistant \
NEMOCLAW_PROVIDER=ollama \
NEMOCLAW_MODEL=glm-5:cloud \
NEMOCLAW_POLICY_MODE=suggested \
NEMOCLAW_RECREATE_SANDBOX=1 \
nemoclaw onboard --non-interactive
```

### 步驟 5：驗證 Discord 設定

```bash
nemoclaw my-assistant connect

# 在沙箱內確認 Discord 插件已啟用
python3 -c "
import json
c = json.load(open('/sandbox/.openclaw/openclaw.json'))
plugins = c.get('plugins', {})
print(json.dumps(plugins, indent=2, default=str))
"

# 確認環境變數存在
echo $DISCORD_BOT_TOKEN
```

### Discord 網路策略

Discord 端點在基礎策略中已**預設允許**（無需額外套用 preset）：

| 端點 | 埠 | 允許方法 | 用途 |
|------|------|----------|------|
| discord.com | 443 | GET, POST | Discord API |
| gateway.discord.gg | 443 | GET, POST | WebSocket 閘道（Bot 連線） |
| cdn.discordapp.com | 443 | GET, POST | 圖片/媒體 CDN |

> **注意：** 若需額外確認 Discord 策略已套用，可執行 `nemoclaw my-assistant policy-add` 並選擇 `discord`。

### 限制與注意事項

- NemoClaw 目前**沒有** Discord Bridge 服務（不像 Telegram 有 `scripts/telegram-bridge.js`）
- Discord 整合依賴 OpenClaw 內建的 Discord 插件功能
- `DISCORD_BOT_TOKEN` 會在 `openshell sandbox create` 時作為環境變數傳入沙箱
- 若需變更 Token，必須重新 Onboard（因為 `openclaw.json` 在沙箱內不可修改）

## 常用操作指令

### 日常使用

```bash
# 連線至沙箱
nemoclaw my-assistant connect

# 在沙箱內開啟 TUI
openclaw tui

# 檢查狀態
nemoclaw my-assistant status

# 串流日誌
nemoclaw my-assistant logs --follow

# 新增網路策略
nemoclaw my-assistant policy-add

# 列出已套用策略
nemoclaw my-assistant policy-list
```

### 檔案同步

```bash
# Host → 沙箱：推送本地修改（無需重建映像）
./scripts/sync-openclaw-data.sh my-assistant

# 沙箱 → Host：拉回沙箱內新建/修改的檔案
./scripts/pull-openclaw-data.sh my-assistant

# 手動上傳單一檔案
openshell sandbox upload my-assistant ./my-file.md /sandbox/.openclaw-data/

# 手動下載單一檔案
openshell sandbox download my-assistant /sandbox/.openclaw-data/skills/ /tmp/skills-backup/
```

> **建議流程：** 重建沙箱前先 `pull`，重建後再 `sync`。

### 管理操作

```bash
# 列出所有沙箱
nemoclaw list

# 銷毀沙箱
nemoclaw my-assistant destroy

# 重新 Onboard
nemoclaw onboard

# 蒐集診斷資訊
nemoclaw debug

# 解除安裝
curl -fsSL https://raw.githubusercontent.com/NVIDIA/NemoClaw/refs/heads/main/uninstall.sh | bash
```

## 沙箱內檔案編輯

沙箱以非 root 的 `sandbox` 使用者運行，且網路策略限制無法使用 `apt install` 安裝額外套件（如 vim）。以下是編輯沙箱內設定檔的替代方案。

### 方案一：使用沙箱內建的編輯器

```bash
nemoclaw my-assistant connect

# 沙箱內通常有 nano 或 vi（busybox 版本）
nano ~/.nemoclaw/config.json
# 或
vi ~/.nemoclaw/config.json
```

### 方案二：從 Host 端編輯後推送至沙箱（推薦）

在 Host 端使用你習慣的編輯器修改，再透過 `openshell sandbox download` / `upload` 傳輸，不受沙箱限制：

```bash
# 1. 從沙箱下載至 Host
openshell sandbox download my-assistant /sandbox/.nemoclaw/config.json /tmp/

# 2. 在 Host 端編輯
vim /tmp/config.json

# 3. 上傳回沙箱（DEST 指定目標目錄，非完整檔案路徑）
openshell sandbox upload my-assistant /tmp/config.json /sandbox/.nemoclaw/
```

> **注意：** `upload` 的目標路徑（DEST）必須是**目錄**而非檔案路徑，檔案會以原始檔名放入該目錄並覆蓋同名檔案。

### 方案三：在沙箱內用 heredoc 覆寫

適合小幅度的設定變更：

```bash
nemoclaw my-assistant connect

# 在沙箱內直接覆寫
cat > ~/.nemoclaw/config.json <<'EOF'
{
  "endpointType": "custom",
  "endpointUrl": "https://inference.local/v1",
  "model": "glm-5:cloud",
  "provider": "ollama-local"
}
EOF
```

## 檔案與目錄參考

安裝完成後，NemoClaw 建立的檔案與目錄：

| 路徑 | 用途 |
|------|------|
| `~/.nemoclaw/config.json` | Onboard 設定（提供者、模型、端點） |
| `~/.nemoclaw/state/nemoclaw.json` | 插件狀態 |
| `~/.nemoclaw/sandboxes.json` | 沙箱註冊表 |
| `~/.nemoclaw/credentials.json` | 憑證儲存（權限 0o600） |
| `~/.nemoclaw/snapshots/` | 遷移快照 |
| `~/.local/bin/openshell` | OpenShell CLI |
| `~/.local/bin/nemoclaw` | NemoClaw CLI（或 npm global bin） |

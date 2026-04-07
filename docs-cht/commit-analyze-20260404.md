# NemoClaw 提交分析報告（2026-04-04）

涵蓋範圍：7347440（`fix: 策略套用指令改用 nemoclaw policy-add 取代 openshell policy set`）至 0b28192（`Merge branch 'main' into claude`），共 154 個提交。

## 統計摘要

| 分類 | 數量 | 佔比 |
|------|------|------|
| 功能錯誤修復（fix） | 98 | 64% |
| 文件（docs） | 17 | 11% |
| 重構（refactor） | 14 | 9% |
| 新功能（feat） | 7 | 5% |
| 雜務（chore） | 7 | 5% |
| CI/CD（ci） | 5 | 3% |
| 測試（test） | 4 | 3% |
| 還原（revert） | 1 | <1% |
| 合併（merge） | 1 | <1% |

**檔案變動：** 219 個檔案，+28,859 行，-5,990 行

## 一、重大架構變更

### 1.1 CJS → TypeScript 大規模遷移

本批最重大的架構變更是將 `bin/lib/` 下的 CommonJS 模組系統性遷移至 `src/lib/` 的 TypeScript 實作。

**已遷移模組：**

| 提交 | 原始 CJS 模組 | 新 TypeScript 模組 | 說明 |
|------|--------------|-------------------|------|
| 347568e | `bin/lib/runtime-recovery.js` | `src/lib/runtime-recovery.ts` | 閘道生命週期復原 |
| 2b76320 | `bin/lib/local-inference.js` | `src/lib/local-inference.ts` | Ollama/vLLM 工具函式 |
| 6ee8b68 | `bin/lib/nim.js` | `src/lib/nim.ts` | NIM 容器管理 |
| 4f9e9ce | `bin/lib/onboard-session.js` | `src/lib/onboard-session.ts` | Onboard 會話管理 |
| baaa277 | `bin/lib/inference-config.js` | `src/lib/inference-config.ts` | 推論設定映射 |
| 82ce32c | `bin/lib/chat-filter.js` 等 | `src/lib/chat-filter.ts`、`resolve-openshell.ts`、`version.ts` | 多個小模組批量遷移 |
| 22ac8b9 | `scripts/debug.sh` | `src/lib/debug.ts` | 診斷蒐集工具 |
| 7040236 | `scripts/start-services.sh` | `src/lib/services.ts` | 服務管理（Telegram Bridge 等） |

**新建立的 TypeScript 模組（非遷移，為新萃取）：**

| 提交 | 模組 | 說明 |
|------|------|------|
| 3f923a4 | `src/lib/preflight.ts` | 從 `bin/lib/preflight.js` 萃取埠檢查、記憶體偵測、swap 管理 |
| 3f923a4 | `src/lib/validation.ts` | 從 `bin/lib/onboard.js` 萃取驗證失敗分類（transport/credential/model/endpoint） |
| 3f923a4 | `src/lib/url-utils.ts` | URL 解析與安全驗證函式 |
| 3f923a4 | `src/lib/dashboard.ts` | Dashboard 轉發管理 |
| 3f923a4 | `src/lib/build-context.ts` | Docker build 上下文組裝 |
| 3f923a4 | `src/lib/gateway-state.ts` | 閘道狀態管理 |

**遷移策略：**
- CJS 模組保留為薄 shim（僅 `require` TypeScript 編譯產出並 re-export）
- 新增 `tsconfig.src.json` 管理 `src/lib/` 編譯
- `package.json` 新增 `build:cli` 腳本（`tsc -p tsconfig.src.json`）
- 所有遷移模組均附帶共存測試（`*.test.ts`）

**影響：**
- `src/lib/` 目錄從 0 個檔案成長至 33 個 TypeScript 檔案
- 語言政策正式確立：所有新原始碼必須使用 TypeScript（CONTRIBUTING.md）
- 覆蓋率門檻拆分為 `ci/coverage-threshold-cli.json`（22%）與 `ci/coverage-threshold-plugin.json`（95%）

### 1.2 安裝器架構重構（#1395）

**提交：** aae3ccd `refactor(installer): thin bootstrap and versioned payload`

將安裝器拆分為兩層：

- **`install.sh`**（瘦引導層）：最小化的 Shell 腳本，僅負責環境偵測、版本檢查、下載 payload
- **`scripts/install.sh`**（版本化 payload）：完整安裝邏輯，隨倉庫版本化

**效益：** 安裝器可獨立更新而不影響引導邏輯，支援 `NEMOCLAW_INSTALL_TAG` 環境變數釘選版本。

### 1.3 刪除 setup.sh，統一至 onboard（#1235）

**提交：** 7c3687e `refactor(cli): delete setup.sh, route all setup through nemoclaw onboard`

- 刪除 `scripts/setup.sh`（324 行）
- `nemoclaw setup` 指令改為轉交 `nemoclaw onboard`
- `brev-setup.sh` 與 `walkthrough.sh` 更新為直接呼叫 onboard

### 1.4 Kubernetes 測試基礎設施（#227）

**提交：** 3c7bd93 `feat: add Kubernetes testing infrastructure`

新增實驗性 Kubernetes 部署支援：

- `k8s/nemoclaw-k8s.yaml`：Pod 定義，使用 privileged DinD + 巢狀 k3s
- `k8s/README.md`：架構說明、快速入門、環境變數參考
- 架構：privileged pod → DinD → k3s → OpenShell 沙箱，socat 橋接推論服務

## 二、新功能

### 2.1 Brave Search 整合（#1464）

**提交：** 3f4d6fe `feat(onboard): add Brave Search onboarding via BRAVE_API_KEY`

- Onboard 精靈新增 Brave Search API 金鑰提示
- 新增 `src/lib/web-search.ts`：建置時將 Brave API 設定編碼為 Docker build arg
- 新增 `nemoclaw-blueprint/policies/presets/brave.yaml`：允許 `api.search.brave.com:443`
- 包含安全警告：金鑰會寫入沙箱設定，Agent 可讀取

### 2.2 沙箱跨閘道重啟存活（#1466）

**提交：** 2d29a02 `feat: sandbox survival across gateway restarts`

- 沙箱在閘道重啟後可自動恢復
- 新增 `test/e2e/test-sandbox-survival.sh`（482 行 E2E 測試）
- 確保閘道升級或意外重啟不會中斷沙箱作業

### 2.3 第三方軟體接受確認（#1290）

**提交：** 2070c2c `feat: require explicit third-party software acceptance before onboarding`

- Onboard 前要求使用者明確接受第三方軟體使用條款
- 新增 `src/lib/usage-notice.ts`：互動式確認流程
- 非互動模式需 `--yes-i-accept-third-party-software` 旗標或 `NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1` 環境變數
- 接受狀態持久化至 `~/.nemoclaw/usage-notice.json`（權限 0o600）

### 2.4 策略預設集數字選擇（#1195）

**提交：** 494ecde `feat(policy): allow selecting policy presets by number`

- `nemoclaw <name> policy-add` 支援以數字序號選擇預設集，改善 UX
- 新增 178 行測試

### 2.5 Security Code Review Agent Skill（#1366）

**提交：** c7aab27 `feat(skills): add security-code-review agent skill`

- 新增 `.agents/skills/security-code-review/SKILL.md`（175 行）
- 提供 9 類安全檢查清單（注入、驗證、憑證、設定等）
- 產出 PASS/WARNING/FAIL 裁定

### 2.6 Amazon Bedrock 新增與移除

- a373e93 `feat: add Amazon Bedrock as inference provider (#963)` — 新增 Bedrock 推論支援
- 182ad1c `refactor: remove Amazon Bedrock as first-class provider (#1212)` — 隨後移除為第一級提供者

## 三、安全強化

### 3.1 憑證與機密保護

| 提交 | 變更 | 說明 |
|------|------|------|
| cb668d7 | CLI 日誌機密脫敏 | 以正則比對 redact secret patterns（API key、token 等）從 log 與 error output |
| bcb046c | 不安全 HOME 回退拒絕 | 憑證儲存時驗證 HOME 目錄安全性，拒絕可疑的 fallback 路徑 |
| 6f9d530 | 遷移快照憑證剝離 + Blueprint 摘要驗證 | 增強版憑證過濾，強制 Blueprint digest 一致性檢查 |
| e06c147 | 不可預測暫存檔名 | 以 `mkdtempSync` 取代固定 `/tmp` 路徑，消除 TOCTOU 競態 |
| d8d8b7c | Onboard 暫存檔安全化 | 同上，針對 Onboard 流程中的暫存檔案 |

### 3.2 閘道認證強化

| 提交 | 變更 | 說明 |
|------|------|------|
| 2804b74 | 閘道認證預設強化 | 限制 auto-pair、強化 auth defaults |
| 5326e37 | .openclaw symlink 不可變 | 驗證後設為 immutable，防止 Agent 替換 |
| 5825739 | 非 root 模式設定完整性 | 啟動時強制檢查設定雜湊 |

### 3.3 網路安全

| 提交 | 變更 | 說明 |
|------|------|------|
| 65693a9 | 封鎖 CGNAT IP | SSRF 驗證新增 100.64.0.0/10（Carrier-Grade NAT）封鎖 |
| 266bbee | 明確 HTTP 方法 | 基線策略中以明確的 GET+POST 取代 `method: *` 萬用字元 |
| 86a573e | Telegram Bridge 限速 | 新增速率限制，防止 API 濫用 |

### 3.4 安裝器安全

| 提交 | 變更 | 說明 |
|------|------|------|
| 3630013 | 下載後再執行 | 安裝器先下載至檔案再執行，不直接 pipe curl 至 bash |
| c8a82f6 | OpenShell SHA-256 校驗 | 下載 OpenShell binary 時驗證 SHA-256 checksum |
| 9b26ac9 | 停止 curl pipe 至 sudo bash | `brev-setup.sh` 不再將 curl 輸出直接 pipe 給 sudo bash |
| 4192d56 | Ollama 安裝器驗證 | 下載 Ollama 安裝程式後驗證完整性 |

### 3.5 沙箱策略強化

| 提交 | 變更 | 說明 |
|------|------|------|
| 36f4456 / b34c4f4 | Tailscale 封鎖（新增後還原） | 封鎖 Tailscale socket/binary 存取，後因相容性問題還原 |
| e073f59 | Telegram 檔案下載 | 預設策略允許 Telegram 檔案下載 |
| e231d32 | Statsig/Sentry 端點強化 | 新增 protocol/enforcement/tls 至遙測端點 |
| 0086886 | clawhub.ai + node egress | OpenShell 策略新增 clawhub.ai 與 node egress 規則 |
| bd1973a | Discord WebSocket | `gateway.discord.gg` 改用 `access: full` 支援 WebSocket |
| 6d44def | WebSocket CONNECT 隧道 | Discord/Slack 預設集改用 CONNECT tunnel 支援 WebSocket |

### 3.6 防注入與輸入驗證

| 提交 | 變更 | 說明 |
|------|------|------|
| f58e13a | 命令注入防護 | `isRepoPrivate()` 修復命令注入漏洞 |
| 85cba13 | 沙箱名稱重新提示 | 無效名稱時重新提示而非直接退出 |

## 四、CI/CD 改善

### 4.1 工作流程重組

| 提交 | 變更 | 說明 |
|------|------|------|
| e9d3120 | 整合檢查 + main 工作流程 | 新增 `main.yaml`、`sandbox-images-and-e2e.yaml`；將 `pr.yaml` 中的共用邏輯抽為 `basic-checks` 與 `resolve-sandbox-base-image` action |
| 88bb222 | DCO 簽署檢查 | 新增 `dco-check.yaml`，要求 Developer Certificate of Origin |
| 4c633a2 | CI-Ready Brev Launchable | 新增 `brev-launchable-ci-cpu.sh`，支援 CI 專用的 CPU Brev 實例 |
| 648ab5f | Brev E2E 從 Nebius 遷至 GCP | 提高 E2E 測試可靠性 |

### 4.2 覆蓋率與測試基礎設施

| 提交 | 變更 | 說明 |
|------|------|------|
| bbdc3cb | tsconfig.cli.json + TS 覆蓋率 | 新增根層級 TypeScript 型別檢查與覆蓋率 ratchet |
| e9d3120 | 覆蓋率門檻拆分 | 拆為 `coverage-threshold-cli.json`（22%）與 `coverage-threshold-plugin.json`（95%） |
| f59f58e | 根層級 Vitest pre-push | 將 CLI Vitest 加入 pre-push hooks |
| 909a803 | 文件修改跳過測試 | docs-only 變更時跳過 Vitest pre-push hooks |

### 4.3 程式碼品質工具

| 提交 | 變更 | 說明 |
|------|------|------|
| 82789a6 | Prettier 格式化 | 根層級 JS 檔案新增 Prettier 格式化（`.prettierrc`、`.prettierignore`） |
| 7596dab | 循環複雜度限制 | ESLint 新增 cyclomatic complexity 規則（上限 20，目標 15） |
| 08cccd4 | pre-commit 設定統一 | 統一 Vitest hooks 與 pre-commit 設定 |

## 五、安裝與 Onboard 改善

### 5.1 安裝流程

| 提交 | 說明 |
|------|------|
| b72ac6a | 預設安裝 `latest` tag 而非 `main` 分支 |
| b81927d | 安裝後寫入 shell profile alias |
| d9d5ba8 | Node.js 版本低於最低需求時透過 nvm 自動升級 |
| bdd61da | Linux 上設定 npm user-local install 避免 EACCES |
| a146385 | `spin()` 新增 Ctrl+C trap handler，確保乾淨中斷 |
| 5c269c1 | Node.js 最低版本統一為 22.16 |
| dfa1d5d | 從基礎映像解析 OpenClaw 版本 |
| 3328359 | 安裝後確保 nemoclaw 指令可用 |

### 5.2 Onboard 流程

| 提交 | 說明 |
|------|------|
| e893e9d | 推論 Onboard 認證與驗證復原強化（1,962 行差異） |
| a03eda0 | 安裝器與 Onboard 韌性強化（3,339 行差異）：新增 `onboard-session.js`、`runtime-recovery.js`、`debug.sh` |
| 97c889c | 閘道啟動失敗時指數退避重試 |
| fa2aa63 | 還原 Dashboard 轉發與 macOS 埠引導 |
| e650174 | 健康檢查強化，等待 Dashboard 就緒 |
| bb66c5c | 未知策略預設集時重新提示而非退出 |
| 1120c2b | Ollama 強制使用 chat completions API |
| 6d83889 | 過期閘道偵測時跳過銷毀以保留 metadata |
| 07589f8 | WSL2 上跳過 OLLAMA_HOST=0.0.0.0 以修復 Docker 路由 |
| 91f9c08 | WSL2 上跳過 CoreDNS 修補以修復沙箱 DNS |

### 5.3 DGX Spark 支援

| 提交 | 說明 |
|------|------|
| 02e5bb6 | 簡化 DGX Spark 設定，移除 cgroup v2 解決方案 |
| b8fab8c | 強化 Spark 啟動與銷毀處理 |
| f6649f3 | setup-spark.sh 與 spark-install.md 對齊 |

## 六、沙箱運行改善

### 6.1 閘道與生命週期

| 提交 | 說明 |
|------|------|
| 6ae809a | 閘道生命週期復原改善 |
| a308420 | 核心生命週期迴歸修復 |
| 1b8e6b9 | 還原日誌串流與重開機復原 UX |
| eb4ba8c | 還原路由推論與連線 UX |
| 5454419 | Dashboard 轉發防止 stdio pipe 繼承導致掛起 |
| b1bb01c | 僅解析閘道推論段落，避免錯誤解析其他配置 |

### 6.2 沙箱基礎設施

| 提交 | 說明 |
|------|------|
| cae0f87 | 還原沙箱 DNS 解析（web 工具可用） |
| c051cbb | 匯出完整 NO_PROXY 並跨重連持久化 |
| c269f38 | 基礎映像新增 `.openclaw/memory` 目錄與 symlink |
| a1a93c2 | `sandboxes.json` 原子寫入與檔案鎖定 |
| 742a0ce | Docker build context 排除 .venv 與開發產物 |
| f0f53e4 | 修正 ulimit hard/soft 設定順序 |
| 88e0398 | nemoclaw-start 權限設為 755 |

### 6.3 推論設定

| 提交 | 說明 |
|------|------|
| 1a45d28 | list/status 指令顯示即時閘道模型/提供者 |
| 4487598 | vLLM 與 NIM-local 強制使用 chat completions API |
| 052c86c | NIM 狀態檢查使用已發佈的 Docker port |
| 805a958 | 設定 nimCapable 前檢查 GPU VRAM 是否滿足模型需求 |
| c3fd887 | 移除失效的 Qwen 端點選項 |
| 72e0d4e | NVIDIA 提供者設定新增 skipVerify |

### 6.4 平台相容性

| 提交 | 說明 |
|------|------|
| 6a7f438 | WSL2 強制 IPv4 DNS 防止 bridge ETIMEDOUT |
| f974a94 | 低記憶體 VM 自動建立 swap 防止 OOM |
| 743b288 | `checkPortAvailable` 正確處理 port 0 |
| ce88542 | lsof retry 使用 `sudo -n` 避免密碼提示 |
| 711b98e | lsof 埠衝突建議加上 sudo 前綴 |

## 七、文件變更

### 7.1 新增文件

| 提交 | 文件 | 說明 |
|------|------|------|
| 79a3115 | `docs/security/best-practices.md` | 安全最佳實踐（457 行），含風險框架與 9 類控制項 |
| 1c50618 | `docs/inference/inference-options.md` | 推論選項總覽（取代 `inference-profiles.md`） |
| 1c50618 | `docs/inference/use-local-inference.md` | 本地推論完整設定指南（231 行） |
| dae494f | `CLAUDE.md` + `AGENTS.md` | AI Agent 開發指引 |
| c01bd83 | README 架構圖 | 架構概覽圖與說明 |
| 3c7bd93 | `k8s/README.md` | Kubernetes 部署說明 |

### 7.2 文件更新

| 提交 | 說明 |
|------|------|
| 2cb6ed8 | README 與 docs 重新平衡（精簡 README，充實 docs） |
| f4a01cf | 貢獻指南更新 |
| 54a4faa | 要求新原始碼使用 TypeScript |
| 50d9810 | CLI 指令參考與實際 CLI 介面同步 |
| 64fd127 | 指令參考新增 debug 與 uninstall |
| fb8a103 | 閘道認證控制與舊版設定說明 |
| 3974352 | skills 描述拆分 main/agent，清理 docs-to-skills |
| c63d37b | Alpha 聲明改為橫幅 + 免責聲明 |
| ce03233 | 漏洞通報指南改善 |
| 0ff3d13 | 日誌範例修正 `-f` → `--follow` |
| 75b8bb9 | 文件與當前 CLI 對齊，onboard 為推薦流程 |
| 7970b7a | README 新增 host-side 設定檔位置 |
| b427496 | Brev 首次執行快速入門 |

## 八、測試改善

### 8.1 新增測試檔案

| 檔案 | 行數 | 說明 |
|------|------|------|
| `src/lib/preflight.test.ts` | 340 | 埠檢查、記憶體偵測、swap 管理 |
| `src/lib/validation.test.ts` | 155 | 驗證失敗分類 |
| `src/lib/url-utils.test.ts` | 121 | URL 安全解析 |
| `src/lib/dashboard.test.ts` | 106 | Dashboard 轉發 |
| `src/lib/debug.test.ts` | 52 | 診斷蒐集 |
| `src/lib/services.test.ts` | 162 | 服務管理 |
| `src/lib/chat-filter.test.ts` | 43 | 聊天過濾 |
| `src/lib/resolve-openshell.test.ts` | 85 | OpenShell 路徑解析 |
| `src/lib/version.test.ts` | 36 | 版本解析 |
| `src/lib/web-search.test.ts` | 41 | Brave Search 設定 |
| `test/service-env.test.js` | 166 | ALLOWED_CHAT_IDS 傳播 |
| `test/usage-notice.test.js` | 154 | 第三方軟體接受 |
| `test/security-c2-dockerfile-injection.test.js` | 68 | Dockerfile 注入安全檢查 |
| `test/e2e/test-sandbox-survival.sh` | 482 | 沙箱存活 E2E |
| `test/e2e/test-credential-sanitization.sh` | 805 | 憑證淨化 E2E |
| `test/e2e/test-telegram-injection.sh` | 471 | Telegram 注入 E2E |
| `test/uninstall.test.js` | 56 | 解除安裝（新增） |

### 8.2 覆蓋率門檻拆分

| 門檻檔案 | lines | functions | branches | statements |
|----------|-------|-----------|----------|------------|
| `coverage-threshold-cli.json`（新） | 22% | 32% | 22% | 22% |
| `coverage-threshold-plugin.json`（原 threshold） | 95% | 98% | 86% | 95% |

CLI 覆蓋率門檻較低，反映 CJS → TypeScript 遷移進行中的過渡狀態；隨遷移完成將逐步提高。

### 8.3 測試品質改善

| 提交 | 說明 |
|------|------|
| 71b4141 | 改善 CLI 測試確定性，移除冗餘邏輯 |
| 2c2b7b0 | 加速閘道復原測試 |
| bc509b9 | 穩定 debug 與 credential prompt 測試 |
| 0658728 | 新增 WSL2 CoreDNS 修補單元測試 |

## 九、貢獻者統計

本批提交涉及 45 位貢獻者（依提交數排序前 15 名）：

| 貢獻者 | 提交數 | 主要領域 |
|--------|--------|----------|
| Carlos Villela | 21 | CJS→TS 遷移、CI 重組、安裝器 |
| Aaron Erickson | 18 | 安全強化、閘道認證、容器安全 |
| KJ | 16 | Onboard 改善、推論設定、沙箱修復 |
| LateNightHackathon | 12 | 安裝器、平台相容性 |
| Miyoung Choi | 8 | 文件、指令參考 |
| Benedikt Schackenberg | 7 | E2E 測試、Brev 基礎設施 |
| J. Yaunches | 7 | E2E 測試、沙箱基礎設施 |
| Facundo Fernandez | 6 | 策略管理、網路安全 |
| Peter | 4 | 閘道生命週期 |
| Prekshi Vyas | 4 | 安全測試 |
| Se7en | 4 | 平台相容性 |
| AlanP | 3 | 推論設定 |
| Brandon Pelfrey | 3 | Docker 建置 |
| Deepak Jain | 3 | 安裝器 |
| jieunl24 | 3 | 策略預設集 |
| 其他 30 位貢獻者 | 各 1-2 | 各領域 |

## 十、重點關注項目

### Breaking Changes

1. **安裝器架構拆分**：`install.sh` 現為瘦引導層，實際邏輯在 `scripts/install.sh`
2. **setup.sh 已刪除**：`nemoclaw setup` 轉交至 `nemoclaw onboard`
3. **第三方軟體接受**：非互動安裝需新增 `--yes-i-accept-third-party-software` 旗標
4. **Node.js 最低版本**：統一至 22.16（原為 22+）
5. **覆蓋率門檻拆分**：`ci/coverage-threshold.json` 拆為 CLI 與 plugin 兩份
6. **Amazon Bedrock**：新增後又移除為第一級提供者
7. **TypeScript 語言政策**：所有新原始碼必須使用 TypeScript

### 重要趨勢

1. **語言統一化**：CJS → TypeScript 遷移持續進行，`src/lib/` 成為核心邏輯的新家
2. **安全縱深**：從安裝器到沙箱的全鏈路安全強化（SHA-256 校驗、憑證脫敏、SSRF 封鎖 CGNAT）
3. **韌性改善**：指數退避重試、重新提示取代退出、Dashboard 就緒等待
4. **推論生態擴展**：Brave Search、多家 OpenAI/Anthropic 相容端點、實驗性 NIM/vLLM
5. **CI 現代化**：工作流程整合、覆蓋率拆分、DCO 簽署、CI-Ready Brev 實例

### 後續待處理

- CJS → TypeScript 遷移尚未完成（`bin/lib/onboard.js` 仍為最大的 CJS 模組）
- CLI 覆蓋率門檻（22%）需隨遷移逐步提高
- DNS 重綁定仍需 IP pinning（依賴 OpenShell 功能）
- `/proc/pid/environ` 憑證暴露（核心限制，需檔案式憑證載入）
- Kubernetes 部署為實驗性（需 privileged pod + DinD）

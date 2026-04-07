# NemoClaw 提交分析報告（2026-03-26）

涵蓋範圍：76809bb（`fix: use nvcr.io/nim/nvidia/nemotron-3-nano`）至 d60b4a6（`docs: 修正並補充 CLAUDE.md 開發指引`），共 74 個提交。

## 統計摘要

| 分類 | 數量 | 佔比 |
|------|------|------|
| 安全修復（security） | 15 | 20% |
| 功能錯誤修復（fix） | 22 | 30% |
| CI/CD 改善（ci/fix(ci)） | 16 | 22% |
| 新功能（feat） | 5 | 7% |
| 重構（refactor） | 3 | 4% |
| 文件（docs） | 8 | 11% |
| 雜務（chore） | 3 | 4% |
| 測試（test） | 2 | 3% |

**檔案變動：** 160 個檔案，+16,915 行，-2,349 行

## 一、重大架構變更

### 1.1 Python Blueprint 模組遷移至 TypeScript（#772）

**提交：** 385d6b0 `refactor: convert blueprint Python modules to TypeScript`

這是本批最大的單一變更，將 Blueprint 編排層從 Python 完全移植至 TypeScript：

**刪除的 Python 檔案：**
- `nemoclaw-blueprint/orchestrator/runner.py` — 主編排邏輯
- `nemoclaw-blueprint/migrations/snapshot.py` — 遷移快照
- `nemoclaw-blueprint/orchestrator/test_endpoint_validation.py` — SSRF 測試
- `nemoclaw-blueprint/pyproject.toml`、`uv.lock`、`Makefile`、`__init__.py`

**新增的 TypeScript 模組：**
- `nemoclaw/src/blueprint/runner.ts` — 編排器（plan/apply/status/rollback）
- `nemoclaw/src/blueprint/snapshot.ts` — 快照管理
- `nemoclaw/src/blueprint/ssrf.ts` — SSRF 端點驗證（獨立模組）
- 對應測試檔案：`runner.test.ts`（648 行）、`snapshot.test.ts`（288 行）、`ssrf.test.ts`（178 行）

**關鍵改動：**
- 新增 `execa` 相依套件取代 Python `subprocess`
- `SnapshotManifest` 更名為 `BlueprintSnapshotManifest`（避免型別衝突）
- SSRF 驗證新增 IPv4-mapped IPv6 處理（`::ffff:10.0.0.1`）
- 計畫 JSON 中的 `credential_env` 和 `credential_default` 欄位在持久化時剝離
- Blueprint 驗證從獨立 CI Job 轉為 Vitest 測試
- nemoclaw/package.json 新增 `"type": "module"`（ESM 輸出）
- ESLint 新增 `switch-exhaustiveness-check`、`prefer-nullish-coalescing`、`prefer-optional-chain`

**影響：**
- Python 工具鏈（Ruff、Pyright、uv）從開發流程中移除
- `nemoclaw-blueprint/` 僅保留靜態資產（`blueprint.yaml` 和 `policies/`）
- 覆蓋率門檻調整：lines 93→95%、statements 94→95%、branches 87→86%

### 1.2 Dockerfile 分層架構（#914）

**提交：** 46a33f1 `feat(ci): split sandbox base image to GHCR for faster builds`

將 Dockerfile 拆分為兩層：

- **Dockerfile.base** — 昂貴且少變動的層：apt 套件、gosu、使用者/群組、OpenClaw CLI、PyYAML。推送至 `ghcr.io/nvidia/nemoclaw/sandbox-base`
- **Dockerfile** — 輕量 PR 特定層：TypeScript 編譯、Blueprint 複製、安全鎖定

**效益：** 沙箱映像建置時間從約 15-20 分鐘降至約 1-2 分鐘。

### 1.3 閘道程序隔離（#721）

**提交：** bb8ba78 `fix(security): isolate gateway process from sandbox agent`

重大安全架構變更：

- 閘道以專屬 `gateway` 使用者運行（透過 gosu 權限分離）
- 代理程式以 `sandbox` 使用者運行，無法 kill 不同 UID 的閘道程序
- 建置時釘選設定雜湊，啟動時驗證完整性
- 入口點鎖定 PATH、解析 OpenClaw 為絕對路徑、驗證 symlink
- 閘道日誌受保護（chown gateway, chmod 600）
- `.openclaw` 目錄權限從 1777 改為 755

**配套測試：** `test/e2e-gateway-isolation.sh`（10 項檢查），新增為 PR CI 平行 Job。

## 二、安全強化

### 2.1 容器安全

| 提交 | 變更 | 說明 |
|------|------|------|
| 2e0066f | 移除 gcc/g++/make/netcat | 減少攻擊面 |
| 2e0066f | ulimit -u 512 | 防止 fork bomb |
| f4a68bf | capsh 權限降級 | 啟動時丟棄 CAP_NET_RAW、CAP_DAC_OVERRIDE 等 |
| 4f59c57 | 保留 cap_setpcap | 修復 capsh 無法降級的迴歸 |
| 4cfc3b3 | gosu no-new-privileges 降級 | OpenShell 阻擋 setuid 時降級為非 root 模式 |
| 5748a32 | 安裝 iptables | 修復網路策略框架完全失效的問題 |
| c55a309 | 基礎映像 SHA256 釘選 | 防止映像替換攻擊 |
| c01c6ee | npm ci 取代 npm install | 確定性、可重現建置 |

### 2.2 憑證與資料保護

| 提交 | 變更 | 說明 |
|------|------|------|
| a461606 | 移除沙箱內 NVIDIA_API_KEY | 停止在 env args、setup.sh、命令列傳遞金鑰 |
| 34296b8 | 快照剝離憑證 | 過濾 auth-profiles.json、剝離閘道 token；新增 Blueprint 摘要驗證（v2→v3） |
| 0fcb7e4 | openclaw.json 權限 0o600 | 遷移期間強制安全權限 |
| ce1ad09 | .env 權限 600 | 啟動時強制安全權限 |
| 9788244 | 遠端 .env 權限 600 | 部署時強制安全權限 |
| a09cfa9 | mktemp 取代 /tmp | cloudflared 下載的 TOCTOU 防護 |

### 2.3 網路策略強化

| 提交 | 變更 | 說明 |
|------|------|------|
| de2554f | binaries 限制 | 所有訊息和預設策略新增二進位檔限制，防止 curl/wget 存取訊息 API |
| e1097a6 | PyPI/npm 策略修復 | `tls: terminate` 改為 `access: full`，修復 CONNECT 隧道；新增 binaries |
| da3f1de | SSRF URL 驗證 | 三層防護：scheme 白名單 + 私有 IP 封鎖 + DNS 重綁定 |

### 2.4 供應鏈安全

| 提交 | 變更 | 說明 |
|------|------|------|
| 66b9f55 | GitHub Actions 釘選至 SHA | 防止標籤篡改攻擊；新增 dependabot |
| ed12055 | 從 release tag 安裝 | install.sh 查詢 GitHub API 取得最新 tag，不再從 main 克隆 |

## 三、CI/CD 改善

### 3.1 工具鏈遷移

| 提交 | 變更 |
|------|------|
| 8e3c980 | Husky → prek：移除 `.husky/` 和 `lint-staged`，所有鉤子統一至 `.pre-commit-config.yaml` |
| 6964d78 | 根層級 JS ESLint + tsc：新增 `eslint.config.mjs`（flat config）和 `jsconfig.json`，修復 68 個 ESLint 違規和 11 個 tsc 錯誤 |
| fdd4aca | markdownlint-cli2 整合至 prek |
| fd4aafc | SPDX --fix、shellcheck 嚴格模式 |

### 3.2 新工作流程

| 提交 | 工作流程 | 說明 |
|------|----------|------|
| a354c5a | e2e-brev.yaml | 短期 Brev CPU 實例 E2E 測試基礎設施 |
| b789cc2 | nightly-e2e.yaml GPU 工作 | Ollama 本地推論 GPU 測試 |
| 0ef5dd2 | nightly-e2e.yaml 通知 | 失敗時自動建立 GitHub Issue |
| 46a33f1 | base-image.yaml | 基礎映像建置推送至 GHCR |
| bb8ba78 | pr.yaml 閘道隔離 Job | 平行執行 10 項閘道安全檢查 |

### 3.3 CI 修復

| 提交 | 說明 |
|------|------|
| e5e5d5a | Squash merge 僅驗證 PR 標題（不再逐 commit lint） |
| 9dbbb5f | 文件預覽拆分為 build + deploy 兩步 |
| c31a1ee | 基礎映像支援 amd64 + arm64 |
| 606a54c / 2afe10b | buildx GHA 快取支援 |
| da973d7 | 文件預覽留言修復（顯式 PR 號碼） |

## 四、新功能

| 提交 | 功能 | 說明 |
|------|------|------|
| aaf4d44 | 擴展提供者 Onboard | 新增 OpenAI、Anthropic、Google Gemini、自訂端點支援；onboard 驗證增強 |
| ce7f1ea | Control UI URL 輸出 | Onboard 完成後印出含閘道 token 的聊天 URL |
| fd4aafc | SPDX --fix 自動修復 | 自動加入遺漏的 SPDX 標頭 |
| a354c5a | Brev E2E 基礎設施 | 短期 GPU 實例自動化測試 |
| 46a33f1 | GHCR 基礎映像快取 | 大幅縮短建置時間 |

## 五、重要修復

### 5.1 安裝與 Onboard

| 提交 | 說明 |
|------|------|
| ed12055 | 從 release tag 安裝，新增 27 個測試 |
| 2804eae | install.sh 檢查 git 是否存在 |
| faad085 | prek 在 prepare 腳本中設為可選 |
| b6f45a6 | 修復 nvm/login shell 重設 PATH |
| 231dd05 | Onboard 顯示 openshell PATH 引導 |
| 5ac3575 | 自動偵測 vLLM 模型 ID |
| 0acb2e4 | ulimit best-effort、修復 PATH 測試 |

### 5.2 沙箱運行

| 提交 | 說明 |
|------|------|
| 1e1243d | 失敗時清理 Docker volumes |
| ba824a6 | 修復卡住的沙箱建立串流 |
| 280227f | 分離非 root 閘道日誌 |
| dd794f0 | 套用策略前驗證 Pod 就緒 |
| b42f291 | status 指令查詢閘道即時推論狀態 |
| 289a4b7 | gosu 依目標架構選擇二進位檔 |

## 六、文件變更

| 提交 | 說明 |
|------|------|
| eb2fb7c | macOS 首次運行前置需求 |
| a1b86a5 | Spark 安裝已知問題、硬體規格、NIM 警告 |
| 1e2c826 | spark-install.md 重構為清晰的 onboard 流程 |
| b79b7e8 | 本地 Ollama 推論設定章節 |
| 4ce7024 | 疑難排解：主機重啟後重連 |
| 93a475a | 各項文件更新 |
| de4fcc5 | docs-as-skills 複製給 Claude |
| d60b4a6 + ca56f6d | CLAUDE.md 修正與繁體中文技術文件 |

## 七、測試改善

### 7.1 新增測試檔案

| 檔案 | 行數 | 說明 |
|------|------|------|
| `nemoclaw/src/blueprint/runner.test.ts` | 648 | Blueprint 編排器完整測試 |
| `nemoclaw/src/blueprint/snapshot.test.ts` | 288 | 快照管理測試 |
| `nemoclaw/src/blueprint/ssrf.test.ts` | 178 | SSRF 驗證測試（含 IPv4-mapped IPv6） |
| `test/e2e-gateway-isolation.sh` | 233 | 閘道隔離 E2E（10 項安全檢查） |
| `test/e2e/brev-e2e.test.js` | 178 | Brev 短期實例 E2E 套件 |
| `test/e2e/test-gpu-e2e.sh` | 444 | GPU Ollama E2E |
| `test/e2e/test-e2e-cloud-experimental.sh` | 886 | 雲端實驗 E2E（拆分 checks/features） |
| `test/install-preflight.test.js` | 772 | 安裝前置檢查（27 個新測試） |
| `test/gateway-cleanup.test.js` | 52 | Docker volume 清理迴歸 |
| `test/security-binaries-restriction.test.js` | 64 | 二進位檔限制策略檢查 |
| `test/validate-blueprint.test.ts` | 86 | Blueprint/策略配置驗證 |

### 7.2 覆蓋率門檻變更

| 指標 | 舊值 | 新值 |
|------|------|------|
| lines | 93% | 95% |
| functions | 98% | 98% |
| branches | 87% | 86% |
| statements | 94% | 95% |

## 八、貢獻者統計

本批提交涉及以下貢獻者（依提交數排序）：

| 貢獻者 | 提交數 | 主要領域 |
|--------|--------|----------|
| Aaron Erickson | 12 | 安全、容器強化、閘道隔離 |
| Carlos Villela | 11 | CI/CD、工具鏈、Python→TS 遷移 |
| Alex | 2 | 繁體中文文件、CLAUDE.md |
| KJ | 3 | 提供者 Onboard、沙箱修復 |
| J. Yaunches | 3 | GHCR 基礎映像、Brev E2E |
| Jaya Venkatesh | 2 | GPU E2E、nightly 通知 |
| cjagwani | 2 | 安全測試、npm ci |
| Hagege Ruben | 2 | SPDX、prek 整合 |
| 其他 15 位貢獻者 | 各 1 | 各領域 |

## 九、重點關注項目

### 需注意的 Breaking Changes

1. **Python Blueprint 已移除**：`runner.py`、`snapshot.py`、`pyproject.toml` 等全部刪除，改用 TypeScript 實作
2. **快照版本 v2→v3**：新增 Blueprint 摘要驗證，舊版快照還原時不驗證摘要
3. **Dockerfile 基礎映像**：`FROM node:22-slim` 改為 `FROM ${BASE_IMAGE}`，預設拉取 GHCR
4. **commitlint 新增 `merge` 類型**：合併提交需使用 `merge:` 前綴
5. **安裝器從 main 改為 release tag**：影響 CI 中使用 `install.sh` 的流程

### 後續待處理

- DNS 重綁定需 IP pinning（依賴 OpenShell 功能）
- `/proc/pid/environ` 憑證暴露（核心限制，需檔案式憑證載入）
- 訊息 token 仍在沙箱 env 中（待 #617 合併）

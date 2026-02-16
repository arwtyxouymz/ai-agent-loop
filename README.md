# AI Agent Loop

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) を複数並列で自律的に動作させ、Git で協調させるドロップインオーケストレーター。
[Anthropic が16並列エージェントで C コンパイラを構築した事例](https://www.anthropic.com/engineering/building-c-compiler) のアーキテクチャを汎用テンプレート化したもの。

**ホストリポジトリが Single Source of Truth** — `.ai-agent-loop/` を既存プロジェクトにコピーするだけで、
エージェントがホストのコードベース上で作業を開始し、結果を `sync-back.sh` でホストに取り込める。

## アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────┐
│  ホストマシン（ユーザーのプロジェクトリポジトリ）              │
│                                                             │
│  .ai-agent-loop/orchestrator.sh                             │
│       │         シグナル監視 → エージェント数を制御            │
│       │                                                     │
│  docker compose -f .ai-agent-loop/docker-compose.yml        │
│       │                                                     │
│  ┌────┴──────────────────────────────────────────────┐      │
│  │  Docker                                           │      │
│  │                                                   │      │
│  │  ┌──────────┐   ┌─────────────────────────────┐   │      │
│  │  │ upstream  │   │  upstream-repo (volume)     │   │      │
│  │  │ git clone ├──▶│  ベア Git リポジトリ          │   │      │
│  │  │ --bare   │   │  (ホストリポからクローン)     │   │      │
│  │  └──────────┘   └──────┬──────────────────────┘   │      │
│  │                         │                          │      │
│  │            ┌────────────┼────────────┐             │      │
│  │            │            │            │             │      │
│  │       ┌────┴───┐  ┌────┴───┐  ┌────┴───┐         │      │
│  │       │Agent 1 │  │Agent 2 │  │Agent N │  ...     │      │
│  │       │(agent) │  │(agent) │  │(agent) │ (最大 8) │      │
│  │       │ loop   │  │ loop   │  │ loop   │          │      │
│  │       │ push   │  │ push   │  │ push   │          │      │
│  │       └────────┘  └────────┘  └────────┘          │      │
│  │                                                   │      │
│  │  ┌────────────────────────────────────────────┐   │      │
│  │  │  viewer (claude-code-viewer)               │   │      │
│  │  │  セッションログ可視化 (port 3400)            │   │      │
│  │  └────────────────────────────────────────────┘   │      │
│  └───────────────────────────────────────────────────┘      │
│                                                             │
│  .ai-agent-loop/sync-back.sh ← エージェントの成果を取り込み   │
└─────────────────────────────────────────────────────────────┘
```

システムは3つのプリミティブに依存している：

| プリミティブ | 役割 |
|------------|------|
| **Docker コンテナ** | 隔離と並列化 — 各エージェントが独立したコンテナで動作 |
| **無限 `while true` ループ** | 各エージェントの自律的・継続的な動作 |
| **Git push/pull（ローカルベアリポ）** | エージェント間の同期とコンフリクト解決 |

## クイックスタート

### A. 既存プロジェクトへの導入

```bash
# 1. .ai-agent-loop/ をプロジェクトにコピー
cp -r path/to/ai-agent-loop/.ai-agent-loop/ my-project/.ai-agent-loop/
cd my-project

# 2. 環境変数を設定
cp .ai-agent-loop/.env.example .ai-agent-loop/.env
# .ai-agent-loop/.env を編集 — 最低限 ANTHROPIC_API_KEY を設定

# 3. プロジェクト固有の設定をカスタマイズ
#    CLAUDE.md                       — 技術スタック、ビルドコマンド、アーキテクチャ
#    .ai-agent-loop/AGENT_PROMPT.md  — [PROJECT-SPECIFIC] セクション

# 4. 起動（エージェント1台で開始、ホストリポを自動クローン）
docker compose -f .ai-agent-loop/docker-compose.yml up -d

# 5.（任意）別ターミナルでオートスケーラーを起動
.ai-agent-loop/orchestrator.sh

# 6. エージェントの成果を確認・取り込み
.ai-agent-loop/sync-back.sh              # ログのみ（デフォルト）
.ai-agent-loop/sync-back.sh --merge      # マージ
```

### B. このリポ自体で試す（デモ）

```bash
# 1. クローン
git clone https://github.com/arwtyxouymz/ai-agent-loop.git
cd ai-agent-loop

# 2. 環境変数を設定
cp .ai-agent-loop/.env.example .ai-agent-loop/.env
# .ai-agent-loop/.env を編集 — 最低限 ANTHROPIC_API_KEY を設定

# 3. エージェントに最初の仕事を与える
mkdir -p ideas
cat > ideas/IMPORTANT_hello_world.txt << 'EOF'
Priority: high
Impact: 動作確認
Description: hello world を出力する Python スクリプト hello.py を作成せよ。
Proposed by: human
EOF
git add ideas/ && git commit -m "chore: add first task for agents"

# 4. 起動
docker compose -f .ai-agent-loop/docker-compose.yml up -d

# 5. エージェントのログをフォロー（作業の様子を観察）
docker compose -f .ai-agent-loop/docker-compose.yml logs -f agent

# 6. 成果を確認・取り込み
.ai-agent-loop/sync-back.sh              # 何をしたか確認
.ai-agent-loop/sync-back.sh --merge      # ホストにマージ

# 7. 停止
.ai-agent-loop/orchestrator.sh stop
# または: docker compose -f .ai-agent-loop/docker-compose.yml down
```

## ファイル構成

```
my-project/                           # ユーザーの既存 Git リポジトリ
├── .git/
├── CLAUDE.md                         # プロジェクト設定（ルートに配置）
├── src/                              # 既存のプロジェクトコード
├── current_tasks/                    # エージェントが必要に応じて作成
├── ideas/                            # エージェントが必要に応じて作成
├── knowledge/                        # エージェントが学びを蓄積（共有ナレッジベース）
└── .ai-agent-loop/                   # オーケストレーション（ドロップイン）
    ├── docker-compose.yml            # サービス定義: upstream + agent + viewer
    ├── orchestrator.sh               # オートスケーリング（ホスト上で実行）
    ├── init-upstream.sh              # ホストリポからベアリポをクローン
    ├── sync-back.sh                  # エージェント成果をホストに取り込み
    ├── AGENT_PROMPT.md               # 毎セッション Claude に渡すプロンプト
    ├── .env.example                  # 環境変数テンプレート
    ├── .gitignore                    # .env, orchestrator.log を除外
    ├── agent/
    │   ├── Dockerfile                # node:24-slim + git + Claude Code CLI（非rootユーザー）
    │   └── entrypoint.sh             # 無限ループ（心臓部）
    ├── agent-sessions/               # Claude セッションデータ（永続化・viewer で閲覧）
    ├── docs/                         # 参考ドキュメント
    └── examples/                     # タスク/アイデアファイルの例
```

## 仕組みの詳解

### エージェントループ

各エージェントコンテナは `.ai-agent-loop/agent/entrypoint.sh` で定義された無限ループを実行する：

```
┌─────────────────────────────────────────┐
│            エージェント起動              │
│  1. 非rootユーザー(agent)で実行          │
│  2. 一意の Git ID を設定（ホスト名）     │
│  3. ベアリポからクローン                 │
│  4. 前回の残留ロックファイルをクリア      │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│          メインループ (∞)               │◀─────────┐
│                                         │          │
│  0. ★ シャットダウン/ポーズチェック      │          │
│  1. git pull --rebase                   │          │
│  2. AGENT_PROMPT.md を envsubst で展開   │          │
│  3. claude -p <プロンプト> を実行         │          │
│     --dangerously-skip-permissions      │          │
│  4. 変更があれば → push_with_retry      │          │
│  5. 5秒スリープ（割り込み可能）          │          │
│                                         │          │
│  失敗時:                                 │          │
│    指数バックオフ（最大300秒）            │          │
└─────────────────────────────────────────┘──────────┘
```

> **ログ管理:** エージェントのログは Docker の `json-file` ログドライバで管理される（コンテナあたり 10MB × 3ファイル）。
> `docker compose logs -f agent` で確認可能。

#### 起動時の stale lock クリア

エージェントが起動すると、`current_tasks/` 内で **自分の AGENT_ID を含むロックファイルだけ** を削除する。
他のエージェントが保持する有効なロックには一切触れない。
これにより、クラッシュしたエージェントが残したロックによるデッドロックを防ぎつつ、
並行して稼働中の他エージェントの作業を妨害しない。

#### エラーリカバリ

`consecutive_failures` カウンタで連続失敗を追跡し、指数バックオフを適用する：

```
失敗1回目〜4回目: 即座にリトライ（通常の5秒スリープのみ）
失敗5回目:       60秒待機
失敗6回目:       120秒待機
...
失敗N回目:       min(N * 60, 300) 秒待機
```

成功すればカウンタはリセットされる。

### タスク協調（楽観的ロック）

エージェント間の協調は Git ベースの楽観的ロックで行われる。
中央スケジューラも、メッセージキューも、データベースも不要 — ファイルと push だけで完結する。

**タスクの確保:**

```
Agent A                     ベアリポ                      Agent B
   │                           │                            │
   │  current_tasks/           │                            │
   │  my-task.txt を作成       │                            │
   │  commit "Lock: my-task"   │                            │
   │  git push ─────────────▶  │                            │
   │           (成功) ◀──────  │                            │
   │                           │  ◀──── git push (REJECTED) │
   │                           │        (同じタスク)         │
   │                           │  ────▶ pull して既にロック  │
   │                           │        済みと判明、         │
   │                           │        別タスクを選択       │
   │                           │                            │
```

**タスクの完了:**

```bash
# ロック削除 + 実装コミットをアトミックに実行
git rm current_tasks/my-task.txt
git add -A
git commit -m "feat: implement my-task"
git push origin main
```

ロックファイルの形式：

```
Claimed by: agent-abc123
Started: 2025-01-15T10:30:00Z
Description: JWT認証ミドルウェアの実装
```

### アイデアシステム

エージェント（または人間）は `ideas/` にファイルを作成して作業を提案できる：

```
ideas/
├── IMPORTANT_implement_auth.txt    ← 人間からの指示（最高優先度）
├── add_caching_layer.txt           ← エージェントからの提案
└── refactor_error_handling.txt     ← エージェントからの提案
```

アイデアファイルの形式：

```
Priority: high | medium | low
Impact: <達成される効果>
Description: <詳細な説明>
Proposed by: <agent-id or "human">
```

`IMPORTANT_` プレフィックス付きのファイルは人間からの高優先指示として最初に処理される。

**優先順位:**
1. `ideas/` 内の `IMPORTANT_*` ファイル
2. ビルド/テストの修復
3. 優先度順のアイデア
4. テストカバレッジの改善
5. リファクタリング

### ナレッジシステム

エージェントが作業中に得た知見を `knowledge/` に蓄積し、Git を通じて全エージェントで共有する仕組み。
セッションをまたいで学びが引き継がれるため、同じ問題に複数エージェントがハマることを防ぐ。

```
knowledge/
├── build-issues.md          ← ビルド関連の知見
├── api-patterns.md          ← API の使い方・パターン
├── testing-gotchas.md       ← テストで注意すべき点
└── architecture-notes.md    ← アーキテクチャ上の制約・依存関係
```

**ライフサイクル:**

```
エージェント起動
    │
    ├─ Orientation で knowledge/ を読む（自分のタスクに関連するファイル）
    │
    ├─ タスク実行中に非自明な知見を発見
    │
    ├─ knowledge/<topic>.md に追記（既存エントリは変更しない）
    │
    └─ 実装コミットと一緒に push → 他エージェントが次の pull で取得
```

**エントリの形式:**

```markdown
## APIレート制限の回避策
- **Agent**: agent-abc123
- **Date**: 2025-01-15

外部APIは1分あたり60リクエストの制限がある。
`src/api/client.ts` の `rateLimiter` ミドルウェアを通すこと。
直接 `fetch()` を呼ぶとレート制限に引っかかる。
```

**設計上のポイント:**
- **追記のみ（Append-only）** — 他エージェントのエントリを編集・削除しない。マージコンフリクトを最小化
- **1トピック1ファイル** — 関心の分離。エージェントは関連するファイルだけ読めばよい
- **Git で自然に共有** — 追加インフラ不要。push/pull で全エージェントに伝播する

### マージコンフリクトの解決

複数エージェントが同じブランチに push するため、コンフリクトは不可避。
システムは2つのレベルで対処する：

**`entrypoint.sh` レベル** — 自動リトライとフォールバック:

```bash
# まず rebase を試行（履歴がクリーン）
git pull --rebase origin main

# rebase が失敗したらマージにフォールバック
git rebase --abort
git pull --no-rebase origin main
```

**`push_with_retry()`** — 最大5回リトライ（1秒間隔）:

```
試行1: push → rejected → pull --rebase → リトライ
試行2: push → rejected → pull --rebase → リトライ
...
試行5: push → rejected → 諦めて次のループへ
```

**Claude レベル** — `AGENT_PROMPT.md` がエージェントに以下を指示：
- コンフリクト時は可能な限り両方の変更を保持する
- 変更が本当に矛盾する場合は upstream（pull 側）を優先する
- 他のエージェントの作業を暗黙的に捨てない

## オートスケーリング・オーケストレータ

`orchestrator.sh` はホスト上で動作し、4つのシグナルを監視してスケーリングを判断する：

```
                        ┌──────────────────┐
                        │  チェックサイクル  │
                        │  （60秒ごと）      │
                        └────────┬─────────┘
                                 │
                    ┌────────────▼────────────┐
              No    │  シグナル1: 成熟度       │
          ┌─────────│  コミット数 >= 閾値?     │
          │         └────────────┬────────────┘
          │                     │ Yes
          │         ┌───────────▼─────────────┐
          │    No   │  シグナル2: ビルド健全性  │
          ├─────────│  BUILD_CHECK_CMD 成功?   │
          │         └───────────┬─────────────┘
          │                     │ Yes
          │         ┌───────────▼─────────────┐
          │    No   │  シグナル3: コンフリクト率│
          ├─────────│  マージ率 < 40%?         │
          │         └───────────┬─────────────┘
          │                     │ Yes
          │         ┌───────────▼─────────────┐
          │         │  シグナル4: タスク供給量  │
          │         │  desired = tasks / ratio │
          │         └───────────┬─────────────┘
          │                     │
          ▼                     ▼
       ┌──────┐          ┌──────────┐
       │ HOLD │          │ SCALE UP │
       │ 保留 │          │（最大+2）│
       └──────┘          └──────────┘
```

| シグナル | チェック内容 | HOLD 条件 |
|---------|-------------|-----------|
| **成熟度** | リポジトリの総コミット数 | `MATURITY_COMMIT_THRESHOLD`（デフォルト: 10）未満 |
| **ビルド健全性** | `BUILD_CHECK_CMD` の終了コード | 非ゼロ（ビルド失敗） |
| **コンフリクト率** | マージコミット / 総コミット（直近1時間） | `CONFLICT_THRESHOLD_HIGH`（デフォルト: 40%）超過 |
| **タスク供給量** | `ideas/` + `current_tasks/` のファイル数 | `MIN_IDEAS_PER_AGENT` の比率で必要エージェント数を算出 |

オーケストレータは Docker volume からベアリポを一時ディレクトリにクローンし、読み取り専用で検査する。

### オーケストレータのサブコマンド

```bash
.ai-agent-loop/orchestrator.sh          # オートスケーリングループを開始（デフォルト）
.ai-agent-loop/orchestrator.sh run      # 同上
.ai-agent-loop/orchestrator.sh stop     # 全エージェントをグレースフルに停止
.ai-agent-loop/orchestrator.sh pause    # 全エージェントを一時停止（新タスク取得を停止）
.ai-agent-loop/orchestrator.sh resume   # 一時停止を解除
```

オーケストレータ自身が SIGTERM を受信した場合も、まず全エージェントの graceful stop を実行してから終了する。

## サービス構成

### `upstream`（init コンテナ）

`init-upstream.sh` を1回実行して終了する。**ホストリポジトリを `git clone --bare` でベアリポにクローン**し、
`current_tasks/` と `ideas/` ディレクトリが存在しなければ追加する。

**初回起動時:** ホストリポ → ベアリポへの bare clone
**再起動時（レジューム）:** ホストの最新 HEAD をベアリポに force push（未マージのエージェントコミットがあれば警告）

### `agent`（スケーラブルワーカー）

各レプリカの動作：
- **非rootユーザー**（`agent`, UID は `AGENT_UID` で設定可能）で実行
- 共有ベアリポからクローン
- 無限 Claude Code ループを実行
- コンテナのホスト名に基づく一意の Git ID を取得
- クラッシュ時は自動再起動（`restart: unless-stopped`）
- メモリ制限: コンテナあたり 4GB
- ログは Docker `json-file` ドライバで管理（10MB × 3ファイル）
- セッションデータは `agent-sessions/` に永続化

### `viewer`（セッションログビューア）

[claude-code-viewer](https://www.npmjs.com/package/@kimuson/claude-code-viewer) を使って、エージェントの Claude Code セッションをブラウザで可視化するサービス。

- デフォルトポート: `3400`（`VIEWER_PORT` で変更可能）
- `agent-sessions/` を読み取り専用でマウント
- `http://localhost:3400` でアクセス

## 設定リファレンス

### 認証（いずれか一つ）

| 変数 | 説明 |
|------|------|
| `ANTHROPIC_API_KEY` | Anthropic API キー（従量課金） |
| `CLAUDE_CODE_OAUTH_TOKEN` | OAuth トークン（Claude Pro/Max 定額サブスクリプション） |

**API キー方式:**
[Anthropic Console](https://console.anthropic.com/) でキーを発行し、`.env` に設定するだけ。

**OAuth トークン方式:**

```bash
# 1. ローカルで Claude Code にログイン（ブラウザが開く）
claude login

# 2. トークンを取得
claude setup-token
# 出力されたトークンをコピー

# 3. .env に設定
echo 'CLAUDE_CODE_OAUTH_TOKEN=<取得したトークン>' >> .ai-agent-loop/.env
```

> **注意:** OAuth トークンは約8時間で期限切れになります。長時間運用する場合は API キー方式が安定します。
> コンテナ内の onboarding スキップは `entrypoint.sh` が自動で行うため、追加設定は不要です。

### エージェント設定

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `CLAUDE_MODEL` | `claude-opus-4-6` | 使用する Claude モデル |
| `AGENT_SLEEP` | `5` | ループ間のスリープ秒数 |
| `MAX_CONSECUTIVE_FAILURES` | `5` | 延長バックオフまでの連続失敗回数 |
| `AGENT_UID` | `1001` | エージェントコンテナ内の非rootユーザーの UID |
| `AGENT_GID` | `1001` | エージェントコンテナ内の非rootユーザーの GID |

### オーケストレータ設定

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `MAX_AGENTS` | `8` | エージェントコンテナの最大数 |
| `CHECK_INTERVAL` | `60` | スケーリングチェック間隔（秒） |
| `SCALE_INCREMENT` | `2` | 1サイクルあたりの最大追加数 |
| `MATURITY_COMMIT_THRESHOLD` | `10` | スケーリング開始に必要な最小コミット数 |
| `MIN_IDEAS_PER_AGENT` | `2` | タスク対エージェント比率 |
| `CONFLICT_THRESHOLD_HIGH` | `40` | スケーリングを一時停止するコンフリクト率（%） |
| `CONFLICT_THRESHOLD_LOW` | `20` | 健全とみなすコンフリクト率（%） |

### セッションビューア設定

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `VIEWER_PORT` | `3400` | claude-code-viewer の公開ポート |

### プロジェクト固有設定

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `BUILD_CHECK_CMD` | _(空)_ | ビルド健全性チェックコマンド（例: `cargo check`, `npm run build`） |
| `SRC_GLOB` | _(空)_ | ソースファイルパターン（成熟度検出用） |

## プロジェクトへのカスタマイズ

### 1. `CLAUDE.md` の編集

このファイルはベアリポにシードされ、Claude Code が自動的に読み取る。
`[PROJECT-SPECIFIC]` セクションを埋める：

```markdown
## [PROJECT-SPECIFIC] Tech Stack
- Language: Rust
- Framework: なし（スタンドアロンバイナリ）
- Build tool: Cargo

## [PROJECT-SPECIFIC] Build & Test Commands
\```bash
cargo build
cargo test
cargo clippy
\```

## [PROJECT-SPECIFIC] Architecture
コンパイラはパイプライン構造:
  lexer -> parser -> type checker -> codegen
```

### 2. `.ai-agent-loop/AGENT_PROMPT.md` の編集

末尾の `[PROJECT-SPECIFIC]` セクションを埋める。
このプロンプトはセッションごとに `envsubst` でレンダリングされ、
`${AGENT_ID}` と `${AGENT_MODEL}` が実際の値に置換される。

### 3. `.env` で `BUILD_CHECK_CMD` を設定

```bash
# Rust
BUILD_CHECK_CMD="cargo check"

# TypeScript
BUILD_CHECK_CMD="npm run build"

# Python
BUILD_CHECK_CMD="python -m pytest --quick"

# Go
BUILD_CHECK_CMD="go build ./..."
```

### 4. Dockerfile の拡張（必要に応じて）

プロジェクト固有のツールチェーンが必要な場合、`.ai-agent-loop/agent/Dockerfile` を拡張する：

```dockerfile
FROM node:24-slim

# ... 既存のセットアップ ...

# 例: Rust ツールチェーンを追加（非rootユーザーのためHOME変更に注意）
USER root
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"
USER agent
```

## 運用ガイド

### 手動スケーリング

```bash
# 4エージェントにスケール（既存コンテナを再作成しない）
docker compose -f .ai-agent-loop/docker-compose.yml up -d --scale agent=4 --no-recreate

# 1エージェントに戻す
docker compose -f .ai-agent-loop/docker-compose.yml up -d --scale agent=1 --no-recreate
```

### モニタリング

```bash
# 稼働中のエージェントを確認
docker compose -f .ai-agent-loop/docker-compose.yml ps

# 全エージェントのログをフォロー
docker compose -f .ai-agent-loop/docker-compose.yml logs -f agent

# セッションビューアでブラウザから確認
#   http://localhost:3400 にアクセス（ポートは VIEWER_PORT で変更可能）

# オーケストレータの判断ログを確認
tail -f .ai-agent-loop/orchestrator.log
```

### エージェントへのタスク投入

ホストリポに直接アイデアファイルを作成してエージェントの作業を指示する：

```bash
# 高優先度の指示を作成
mkdir -p ideas
cat > ideas/IMPORTANT_implement_auth.txt << 'EOF'
Priority: high
Impact: コア機能 — 他の全API作業をブロック
Description:
  JWT ベースの認証ミドルウェアを実装する。
  - POST /auth/login で署名済み JWT を返す
  - ミドルウェアで保護ルートの JWT を検証
  - 認証エンドポイントにレート制限を追加
Proposed by: human
EOF

git add ideas/IMPORTANT_implement_auth.txt
git commit -m "Add idea: implement authentication"
# 次回のエージェント起動時（またはレジューム時）に反映される
```

### エージェント成果の取り込み

```bash
# エージェントのコミットを確認（読み取り専用）
.ai-agent-loop/sync-back.sh

# マージで取り込み
.ai-agent-loop/sync-back.sh --merge

# リベースで取り込み（クリーンな履歴）
.ai-agent-loop/sync-back.sh --rebase
```

### エージェントの停止・一時停止・再開

推奨は `orchestrator.sh` のサブコマンドを使う方法。
エージェントは SIGTERM を受信すると、実行中の `claude -p` セッションが完了するのを待ち、
未 push の変更を push し、自分のロックファイルを解放してから終了する（最大 5 分間の猶予）。

```bash
# ★ 推奨: 全エージェントをグレースフルに停止
#   → 作業完了 → push → ロック解放 → 終了
.ai-agent-loop/orchestrator.sh stop

# 一時停止（現在の作業は完了するが、次のタスクを取らない）
.ai-agent-loop/orchestrator.sh pause

# 一時停止を解除
.ai-agent-loop/orchestrator.sh resume
```

`docker compose down` も利用可能。SIGTERM ハンドリングが組み込まれているため、
内部的には同じ graceful shutdown が走る。
ただし `orchestrator.sh stop` は明示的に 300 秒のタイムアウトを指定する点が異なる。

```bash
# docker compose 経由で停止（ボリュームデータは保持）
docker compose -f .ai-agent-loop/docker-compose.yml down

# 停止してボリュームも削除（リポジトリデータが全て消える）
docker compose -f .ai-agent-loop/docker-compose.yml down -v
```

### レジュームフロー

```
セッション1: orchestrator.sh run → init がホストリポをクローン → エージェント作業 → orchestrator.sh stop
            ↓
同期:       sync-back.sh              → エージェントの成果を確認
            sync-back.sh --merge      → ホストにマージ
            ↓
手動作業:   ユーザーがレビュー、編集、コミット
            ↓
セッション2: orchestrator.sh run → init がホスト最新状態をベアリポに反映
            → エージェントが pull → ホストの最新状態から継続
```

## エラーリカバリ一覧

| シナリオ | 動作 |
|---------|------|
| Claude CLI クラッシュ | `consecutive_failures` カウンタ増加、指数バックオフ（最大300秒） |
| push 拒否（コンフリクト） | `push_with_retry()`: pull --rebase → 最大5回リトライ |
| rebase 失敗 | `--no-rebase` マージにフォールバック |
| コンテナクラッシュ | Docker の `restart: unless-stopped` で自動再起動 |
| 残留タスクロック | エージェント起動時に自身のロックのみクリア |
| 認証トークン期限切れ | Claude CLI が非ゼロで終了、バックオフ後に次ループでリトライ |
| SIGTERM 受信 | 現在のイテレーション完了 → WIP push → ロック解放 → 正常終了 |
| 一時停止（`.pause`） | 新タスクを取得せずスリープし続ける。`.pause` 削除で再開 |

## 設計判断の根拠

このボイラープレートは意図的にシンプルに保っている。
オーケストレーション全体がシェルスクリプトで完結し、Docker 以外の外部依存がない。

| 判断 | 選択 | 根拠 |
|------|------|------|
| ベースイメージ | `node:24-slim` | Claude Code CLI は npm パッケージ。slim で約400MB削減 |
| ベアリポ同期 | `git pull --rebase` + `--no-rebase` フォールバック | rebase で履歴がクリーン、複雑なコンフリクト時のフォールバック確保 |
| スケール増分 | 1サイクルあたり最大+2 | 段階的スケーリングがコンフリクト率の急増を防ぐ（C コンパイラプロジェクトからの知見） |
| テンプレート展開 | `envsubst` + 明示的変数リスト | プロンプト内の `$()` の誤展開を防止 |
| オーケストレータ位置 | ホスト上（コンテナ外） | `docker compose --scale` へのアクセスが必要 |
| 中央スケジューラなし | Git ベースの楽観的ロックのみ | C コンパイラプロジェクトで実証済みのアプローチ。インフラオーバーヘッドゼロ |
| `stop_grace_period` | 5 分 | claude セッションは通常数分。超過時は Docker が SIGKILL（許容範囲のトレードオフ） |
| `sleep & wait` パターン | `sleep N & wait $!` | SIGTERM 受信時に sleep を即座に中断し、次ループ先頭の終了チェックに到達させる |
| 非rootユーザー | `agent` (UID=1001) | Claude Code が root 実行を拒否するため。`AGENT_UID` でホストとの UID マッピングも可能 |
| ログ管理 | Docker `json-file` ドライバ | ファイルベースのログローテーションより運用がシンプル。`docker compose logs` で一元確認 |
| セッションビューア | `claude-code-viewer` | エージェントの作業内容をブラウザでリアルタイム確認。デバッグと監視を容易にする |
| ロック削除範囲 | 自 AGENT_ID のみ | 他エージェントの有効なロックを誤削除しない。並列稼働時の安全性を優先 |

## 参考資料

このプロジェクトは [Anthropic が16並列 Claude Code エージェントで C コンパイラを構築した方法](https://www.anthropic.com/engineering/building-c-compiler) の詳細分析に基づいている。分析ドキュメントは [`.ai-agent-loop/docs/`](./.ai-agent-loop/docs/README.md) に体系的にまとめている：

| カテゴリ | ドキュメント | 内容 |
|---|---|---|
| アーキテクチャ | [`.ai-agent-loop/docs/architecture.md`](./.ai-agent-loop/docs/architecture.md) | コア・コンポーネント、構成図、ワークフロー、楽観的ロック |
| 実証分析 | [`.ai-agent-loop/docs/analysis/`](./.ai-agent-loop/docs/analysis/) | コミット粒度、並列化タイムライン、スケーリング証拠、統計 |
| 設計アプローチ | [`.ai-agent-loop/docs/design/`](./.ai-agent-loop/docs/design/) | 自動スケーリング設計案、docker-compose、ベアリポジトリ |

分析からこのボイラープレートに反映された主要な知見：
- **Git による楽観的ロック**はタスク協調に十分 — データベースもメッセージキューも不要
- **段階的スケーリング**（一斉投入ではなく）がコンフリクト率を管理可能に保つ
- **起動時の自己ロッククリア**がクラッシュしたエージェントによるデッドロックを防ぐ（他エージェントのロックは保持）
- **エージェントプロンプト**が最も重要なコンポーネント — エージェントの協調品質を決定する

## ライセンス

MIT

# 並列エージェント・アーキテクチャ解析

本ドキュメントは、Anthropic 社の記事内で言及されている「16 個の並列エージェント」がどのように構築・運用されているか、その技術的な仕組みとワークフローをまとめたものである。

- Source: https://www.anthropic.com/engineering/building-c-compiler

---

## 1. 概要

Anthropic のエンジニアリングチームが、16 並列の Claude Code エージェントを使って C コンパイラを構築した。
各エージェントは Docker コンテナ内で無限ループを回し、タスクを自律的に選択・実装・コミットする。
エージェント間の同期は Git のみで行われる。

システムは 3 つのプリミティブに依存している:

| プリミティブ | 役割 |
|---|---|
| **Docker コンテナ** | 隔離と並列化 — 各エージェントが独立したコンテナで動作 |
| **無限 `while true` ループ** | 各エージェントの自律的・継続的な動作 |
| **Git push/pull** | 同期とコンフリクト解決 |

No task queue, no message broker, no distributed lock manager. Just Git.

---

## 2. コア・コンポーネント

### 2-1. エージェントの「魂」（シェルスクリプト）

各エージェントの実体は、単純な無限ループを持つシェルスクリプトである。これ単体では並列処理機能を持たず、**「1 人の作業員が延々とタスクをこなす」** という挙動を担当する。

```bash
#!/bin/bash
while true; do
    COMMIT=$(git rev-parse --short=6 HEAD)
    LOGFILE="agent_logs/agent_${COMMIT}.log"

    # エージェント実行（タスク実施）
    # 失敗しても終了せず、ログを吐いて次のループへ
    claude --dangerously-skip-permissions \
           -p "$(cat AGENT_PROMPT.md)" \
           --model claude-opus-X-Y &> "$LOGFILE"
done
```

This script defines **one agent's behavior**. The parallelism comes from Docker: 16 containers each run this same script independently.

### 2-2. 実行基盤（Docker コンテナ）

上記のスクリプトを内包した Docker コンテナを **16 個** 起動することで並列化を実現している。

- **構成:** 1 コンテナにつき、1 エージェント。
- **ファイルシステム:** コンテナごとに完全に独立（Isolation）。
- **コード管理:** ホストのディレクトリをマウントするのではなく、**各コンテナが個別に Git リポジトリを `clone` して保持する。**

### 2-3. 共有リポジトリ（ベア Git リポジトリ）

エージェント間の同期は、ローカルのベアリポジトリを介して行われる。GitHub ではなくローカルにする理由は速度（push/pull が ~10ms vs ~1-3 秒）。詳細は [bare-repository.md](./design/bare-repository.md) を参照。

---

## 3. アーキテクチャ構成図

### 3-1. 全体図（Mermaid）

```mermaid
graph TD
    subgraph Host_Machine [ホストマシン (実行環境)]
        DockerCompose[docker-compose.yml]
        note1[役割: 場所の提供のみ]

        subgraph Container_1 [コンテナ 1]
            Script1[Agent Script (無限ループ)]
            LocalRepo1[ローカルGitリポジトリ]
        end

        subgraph Container_16 [コンテナ 16]
            Script16[Agent Script (無限ループ)]
            LocalRepo16[ローカルGitリポジトリ]
        end
    end

    subgraph Remote_Server [中央集権サーバー (GitHub/GitLab)]
        MasterRepo[リモートGitリポジトリ]
        LockFile[タスク管理/ロックファイル]
        note2[役割: 正解の保持 & 排他制御]
    end

    %% データフロー
    DockerCompose -.->|"起動 (Scale=16)"| Container_1
    DockerCompose -.->|"起動 (Scale=16)"| Container_16

    LocalRepo1 <-->|"Pull / Push"| MasterRepo
    LocalRepo16 <-->|"Pull / Push"| MasterRepo
```

### 3-2. 全体図（ASCII）

```
┌─────────────────────────────────────────────────┐
│              Bare Git Repository (upstream)       │
│                  /upstream                        │
└──────┬──────┬──────┬─────────────┬──────────────┘
       │      │      │             │
  ┌────▼──┐┌──▼───┐┌─▼────┐   ┌───▼────┐
  │Docker ││Docker ││Docker │...│Docker  │  ← 16 containers
  │  #1   ││  #2  ││  #3  │   │  #16   │
  │       ││      ││      │   │        │
  │ while ││ while││ while│   │ while  │  ← Each runs the
  │ true  ││ true ││ true │   │ true   │    same agent loop
  │ ...   ││ ...  ││ ...  │   │ ...    │
  └───────┘└──────┘└──────┘   └────────┘
```

---

## 4. エージェント・ワークフロー

各エージェントは独立して動いており、Git を介して同期を行う。コンフリクトを回避するため、**「常に最新を正とし、競合したら諦める」** というサイクルを回す。

### ループの 1 回分の詳細プロセス

1. **環境リセット (Clean & Reset)**
   - 前の作業のゴミや、中途半端な変更を破棄する。
   - `git reset --hard` 等を使用。

2. **最新化 (Pull)**
   - 中央サーバーから最新のコードを取得する。

3. **タスク予約 (Locking)**
   - 「タスク A に着手します」という情報をサーバー（特定のファイルや DB）に書き込む。
   - 他のエージェントとタスクが被らないようにするための排他制御。

4. **作業実行 (Coding & Testing)**
   - LLM がコードを修正し、コンパイル・テストを行う。
   - この間、ローカルリポジトリのみが更新される。

5. **提出 (Push)**
   - 作業結果をコミットし、中央サーバーへ `git push` する。
   - **成功:** 次のタスクへ。
   - **失敗 (Reject):** タッチの差で他者が Push していた場合。
   - **対応:** マージや修正は行わず、**潔くその作業を捨てて** 手順 1（リセット）に戻る。（楽観的ロックの考え方）

---

## 5. タスク協調（楽観的ロック）

各エージェントは `current_tasks/` ディレクトリにファイルを書き込み、共有 upstream リポに push することでタスクを Claim する。

### 5-1. Happy Path

```
1. git pull origin main              # Get latest state
2. Check current_tasks/              # See what's already claimed
3. Pick an unclaimed task
4. Create current_tasks/<task>.txt   # Claim it
5. git add && git commit
6. git push origin main              # Synchronization point
```

### 5-2. Conflict Path（2 エージェントが同じタスクを Claim）

```
Timeline →

Agent #3                          Agent #7
────────                          ────────
git pull                          git pull
(task X unclaimed)                (task X unclaimed)
Claim task X                      Claim task X
git commit                        git commit
git push ✅ SUCCESS               git push ❌ REJECTED
                                  │
                                  ▼
                                  git pull
                                  "task X already claimed"
                                  Pick a different task
```

### 5-3. なぜ楽観的ロックか

| アプローチ | 説明 |
|---|---|
| **悲観的ロック** | 作業開始前にロックを取得する（例: DB の `SELECT FOR UPDATE`） |
| **楽観的ロック** | まず作業し、コミット時にコンフリクトがあればリトライする |

Git の push/pull メカニズムは自然な楽観的ロックである。分散ロックマネージャは不要。

### 5-4. ロックファイルの形式

`current_tasks/<task_name>.txt` を **1 ファイルだけ追加** して push する。実装完了コミットではタスクファイルを **削除** してコードを追加する（＝ロック解放と実装のアトミック操作）。

---

## 6. 各コンポーネントの役割定義

| コンポーネント | 役割・機能 | 備考 |
|---|---|---|
| **中央サーバー** (GitHub 等) | **Single Source of Truth (信頼できる唯一の情報源)** — 最新コードの保持、Push の競合判定（早い者勝ち判定）、タスク状況の公開 | エージェントへの指示出しは行わない。あくまで「記録係」。 |
| **ホストマシン** | **インフラ提供** — Docker Compose によるコンテナ群のライフサイクル管理 | コードの中身には関与しない。`docker-compose.yml` を持つのみ。 |
| **エージェント** (コンテナ群) | **自律作業ユニット** — コード修正、判断、テスト、競合時の撤退判断 | 16 体が独立して稼働。互いに直接通信はしない。 |

---

## 7. なぜこのアーキテクチャか

### 7-1. 設計の利点

- **単純さ:** 複雑な並列通信プログラムを書く必要がない。単一のスクリプトを複数走らせるだけでスケールする。
- **堅牢性:** 1 つのコンテナがクラッシュしても、他の 15 個には影響しない。
- **整合性:** Git の強力なバージョン管理機能をそのまま「分散システムの同期プロトコル」として利用することで、ファイルの破損を防いでいる。

### 7-2. 「粗い」アプローチが機能する理由

- **Fine-grained tasks**: タスクが細かいため、重複作業のコストが低い
- **Claude resolves merge conflicts**: "Merge conflicts are frequent, but Claude is smart enough to figure that out."
- **Throughput over correctness**: 時折の重複は、厳密な協調のオーバーヘッドより安い
- **Emergent specialization**: エージェントは自然に役割分化する（コア実装、ドキュメント、最適化など）

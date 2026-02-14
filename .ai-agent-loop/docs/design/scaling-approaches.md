# 自動スケーリング設計アプローチ

本ドキュメントは、並列エージェントの自動スケーリングを実現するための設計案を 4 つ提示し、比較・評価したものである。

---

## 核心的な課題

「**いつコンテナを追加しても安全か**」を自動で判断する必要がある。判断に使えるシグナル:

1. **コードベースの成熟度** — 基盤がないと並列作業できない
2. **タスクの供給量** — やることがないのにエージェントを増やしても衝突するだけ
3. **システムの健全性** — ビルドが壊れてる時に投入しても混乱が増すだけ

---

## 案 1: Orchestrator パターン（最も現実的）

while true ループの外に、エージェントとは別の軽量なオーケストレータを置く:

```bash
#!/bin/bash
# orchestrator.sh — エージェントではなく、純粋な制御スクリプト

MAX_AGENTS=16
CURRENT_AGENTS=0

start_agent() {
    docker run -d --name "agent-$CURRENT_AGENTS" \
        -v /upstream:/upstream agent-image
    CURRENT_AGENTS=$((CURRENT_AGENTS + 1))
    echo "$(date): Agent #$CURRENT_AGENTS started"
}

# Phase 1: Bootstrap — 1エージェントで基盤を作る
start_agent

while [ $CURRENT_AGENTS -lt $MAX_AGENTS ]; do
    sleep 60

    cd /upstream && git pull 2>/dev/null

    # Signal 1: コードベースの成熟度
    if [ ! -f "Cargo.toml" ]; then
        echo "$(date): No Cargo.toml yet, waiting..."
        continue
    fi
    SRC_FILES=$(find src/ -name "*.rs" 2>/dev/null | wc -l)
    if [ "$SRC_FILES" -lt 10 ]; then
        echo "$(date): Only $SRC_FILES source files, waiting..."
        continue
    fi

    # Signal 2: タスク供給量
    IDEA_COUNT=$(ls ideas/*.txt 2>/dev/null | wc -l)
    ACTIVE_LOCKS=$(ls current_tasks/*.txt 2>/dev/null | wc -l)
    AVAILABLE=$((IDEA_COUNT - ACTIVE_LOCKS))

    # Signal 3: ビルドが通るか
    cargo check --manifest-path Cargo.toml 2>/dev/null
    BUILD_OK=$?

    # スケーリング判定
    if [ $BUILD_OK -ne 0 ]; then
        echo "$(date): Build broken, not scaling"
        continue
    fi

    if [ $AVAILABLE -gt $CURRENT_AGENTS ]; then
        ADD=$(( AVAILABLE - CURRENT_AGENTS ))
        [ $ADD -gt 2 ] && ADD=2  # 一度に最大2つずつ追加
        for i in $(seq 1 $ADD); do
            start_agent
        done
    fi
done
```

---

## 案 2: Agent 自己申告パターン

エージェント自身が `ideas/` に大量のタスクを生成する特性を利用:

```bash
#!/bin/bash
start_agent  # 最初の1エージェント

while [ $CURRENT_AGENTS -lt $MAX_AGENTS ]; do
    sleep 120
    cd /upstream && git pull 2>/dev/null

    TASK_POOL=$(ls ideas/*.txt 2>/dev/null | wc -l)

    # "理想のエージェント数" = タスクプールの量に比例
    DESIRED=$(( TASK_POOL / 2 ))  # タスク2個につき1エージェント
    [ $DESIRED -gt $MAX_AGENTS ] && DESIRED=$MAX_AGENTS
    [ $DESIRED -lt 1 ] && DESIRED=1

    DIFF=$(( DESIRED - CURRENT_AGENTS ))
    if [ $DIFF -gt 0 ]; then
        [ $DIFF -gt 3 ] && DIFF=3
        for i in $(seq 1 $DIFF); do
            start_agent
        done
    fi
done
```

---

## 案 3: コンフリクト率ベース（フィードバックループ）

実際のコンフリクト率をモニタリングして判断:

```bash
#!/bin/bash
CONFLICT_WINDOW=300  # 直近5分間

count_conflicts() {
    cd /upstream
    git log --since="${CONFLICT_WINDOW} seconds ago" \
        --oneline --grep="^Remove.*stale\|^Unlock.*already\|already fixed" | wc -l
}

count_recent_commits() {
    cd /upstream
    git log --since="${CONFLICT_WINDOW} seconds ago" --oneline | wc -l
}

start_agent  # まず1つ

while [ $CURRENT_AGENTS -lt $MAX_AGENTS ]; do
    sleep 120
    cd /upstream && git pull 2>/dev/null

    CONFLICTS=$(count_conflicts)
    COMMITS=$(count_recent_commits)
    [ $COMMITS -eq 0 ] && continue

    CONFLICT_RATE=$(( CONFLICTS * 100 / COMMITS ))

    if [ $CONFLICT_RATE -lt 15 ]; then
        start_agent  # コンフリクト率が低い → 追加
    elif [ $CONFLICT_RATE -gt 40 ]; then
        echo "$(date): Conflict rate ${CONFLICT_RATE}%, holding"
    fi
done
```

---

## 案 4: 時間ベースのランプアップ（最もシンプル）

```bash
#!/bin/bash
SCHEDULE=(
    "0:1"     # 開始時: 1エージェント
    "30:2"    # 30分後: 2に増加
    "60:4"    # 1時間後: 4に
    "90:8"    # 1.5時間後: 8に
    "120:16"  # 2時間後: フル16
)
# ... (スケジュール通りにコンテナ追加)
```

---

## 比較

| 案 | 複雑度 | 利点 | 欠点 |
|---|:---:|---|---|
| **1. Orchestrator** | 中 | 複数シグナル、安全 | ビルドチェックにコストがかかる |
| **2. 自己申告** | 低 | ideas/ の仕組みを自然に活用 | ideas の量≠実際の並列可能性 |
| **3. コンフリクト率** | 高 | 実測ベースで最も正確 | 遅延がある（問題発生後に検知） |
| **4. 時間ベース** | 最低 | 最もシンプル、予測可能 | プロジェクト特性に依存 |

**推奨: 案 1 + 案 3 のハイブリッド。**「タスク供給が十分 AND ビルドが通る なら追加、ただしコンフリクト率が高ければ抑制」。

本リポジトリの `orchestrator.sh` はこのハイブリッドアプローチを実装している。

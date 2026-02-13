# docker-compose での段階的スケーリング

本ドキュメントは、docker-compose を使った並列エージェントの段階的スケーリングの実装方法をまとめたものである。

---

## docker-compose.yml

```yaml
services:
  upstream:
    image: alpine/git
    command: ["git", "init", "--bare", "/repo"]
    volumes:
      - upstream-repo:/repo

  agent:
    build: ./agent
    volumes:
      - upstream-repo:/upstream
      - ./AGENT_PROMPT.md:/workspace/AGENT_PROMPT.md:ro
    environment:
      - ANTHROPIC_API_KEY
    restart: unless-stopped

volumes:
  upstream-repo:
```

---

## agent/Dockerfile

```dockerfile
FROM rust:latest
RUN curl -fsSL https://claude.ai/install.sh | sh
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

---

## agent/entrypoint.sh

```bash
#!/bin/bash
git clone /upstream /workspace/code
cd /workspace/code

while true; do
    git pull origin main 2>/dev/null
    COMMIT=$(git rev-parse --short=6 HEAD)
    claude --dangerously-skip-permissions \
           -p "$(cat /workspace/AGENT_PROMPT.md)" \
           --model claude-opus-4-6 \
           &> "agent_logs/agent_${COMMIT}.log"
done
```

---

## docker-compose でのオーケストレータ

```bash
#!/bin/bash
# scale.sh

scale_to() {
    local n=$1
    docker compose up -d --scale agent=$n --no-recreate
    echo "$(date): Scaled to $n agents"
}

scale_to 1  # Phase 1: 1エージェントで基盤構築

while true; do
    sleep 120
    CURRENT=$(docker compose ps agent --status running -q | wc -l)
    [ "$CURRENT" -ge 16 ] && break

    # ... (シグナルに基づくスケーリング判定) ...

    NEXT=$(( CURRENT * 2 ))
    [ $NEXT -gt 16 ] && NEXT=16
    scale_to $NEXT
done
```

---

## ポイント: `--no-recreate` が重要

`docker compose up -d --scale agent=4 --no-recreate` で:

- **既存のコンテナを再起動せずに、差分だけ追加する**
- agent=1 → agent=4 にすると、既存の 1 コンテナはそのまま動き続け、3 コンテナが新規追加される
- これがないと全コンテナが再作成されて、作業中のエージェントが中断される

---

## docker run vs docker-compose 比較

| | `docker run -d` | `docker compose --scale` |
|---|---|---|
| スケール操作 | `docker run -d ...` を N 回 | `--scale agent=N` 1 回 |
| 設定の一元管理 | 引数に全部書く | YAML で宣言的 |
| ボリューム共有 | `-v` を毎回指定 | YAML で 1 回定義 |
| 既存コンテナの保護 | 個別管理なので問題なし | `--no-recreate` 必須 |
| スケールダウン | `docker stop agent-N` | `--scale agent=N` (自動で余分を停止) |
| コンテナ名の管理 | 自分で命名 | 自動で `project-agent-1`, `-2`... |

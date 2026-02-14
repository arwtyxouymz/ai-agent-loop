# Anthropic「Building a C Compiler」並列エージェント解析ドキュメント

本ドキュメント群は、Anthropic が 16 並列の Claude Code エージェントで C コンパイラを構築した事例を多角的に分析し、その知見を体系的にまとめたものである。

- **原典**: [Building a C Compiler with 16 Parallel Claude Agents](https://www.anthropic.com/engineering/building-c-compiler)
- **対象リポジトリ**: [anthropics/claudes-c-compiler](https://github.com/anthropics/claudes-c-compiler)
- **分析日**: 2026-02-12

---

## ドキュメント構成

### アーキテクチャ

| ドキュメント | 内容 |
|---|---|
| [architecture.md](./architecture.md) | コア・コンポーネント、構成図、エージェント・ワークフロー、タスク協調（楽観的ロック）、設計思想の統合的解説 |

### 実証分析（`analysis/`）

実際の claudes-c-compiler リポジトリのコミット履歴を詳細に調査した結果。

| ドキュメント | 内容 |
|---|---|
| [commit-granularity.md](./analysis/commit-granularity.md) | 初期コミットの粒度と内容、Claude vs 人間のコミット比率、タスク Claim ロック機構の実在性の実証 |
| [parallelization-timeline.md](./analysis/parallelization-timeline.md) | 直列 → 並列化の移行タイムライン（4 フェーズ）、スループット推移、タイムスタンプ逆転による並列 push の証明 |
| [scaling-evidence.md](./analysis/scaling-evidence.md) | 段階的スケーリングが手動か自動かの検証、4 つの証拠と推定オペレーション手順 |
| [project-statistics.md](./analysis/project-statistics.md) | プロジェクト全体の統計サマリー（コミット数、期間、日別推移、ロック統計） |

### 設計アプローチ（`design/`）

この事例から導出された実装設計の選択肢と判断根拠。

| ドキュメント | 内容 |
|---|---|
| [scaling-approaches.md](./design/scaling-approaches.md) | 自動スケーリングの 4 つのアプローチ（Orchestrator、自己申告、コンフリクト率、時間ベース）と比較 |
| [docker-compose-scaling.md](./design/docker-compose-scaling.md) | docker-compose での段階的スケーリング実装（YAML, Dockerfile, entrypoint, `--no-recreate` の重要性） |
| [bare-repository.md](./design/bare-repository.md) | ローカルベアリポジトリを採用する理由（速度、レートリミット、外部依存排除）と GitHub との比較 |

---

## 本リポジトリへの反映

これらの分析から本ボイラープレート（ai-agent-loop）に反映された主要な知見:

- **Git による楽観的ロック**はタスク協調に十分 — データベースもメッセージキューも不要
- **段階的スケーリング**（一斉投入ではなく）がコンフリクト率を管理可能に保つ
- **起動時の自己ロッククリア**がクラッシュしたエージェントによるデッドロックを防ぐ
- **エージェントプロンプト**が最も重要なコンポーネント — エージェントの協調品質を決定する
- **ローカルベアリポ**がネットワーク遅延ゼロの高速同期を実現する

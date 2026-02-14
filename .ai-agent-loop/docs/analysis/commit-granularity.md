# 初期コミット分析・タスク Claim の実証

本ドキュメントは、claudes-c-compiler リポジトリの初期コミットの粒度・内容、Claude vs 人間のコミット比率、タスク Claim ロック機構の実在性を実証分析した結果をまとめたものである。

- Repository: https://github.com/anthropics/claudes-c-compiler

---

## 1. 初期コミットの粒度と内容（0→1 フェーズ）

**全体像**: 総コミット数 **3,982 件**、期間は **2026-01-23 〜 2026-02-05** の約 14 日間。

### 最初のコミット（`d8cbbec8` 01:04 UTC）

- `current_tasks/.keep` と `ideas/.keep` のみ。空のディレクトリ構造を作っただけ。
- これがエージェント用の「土台」。`current_tasks/` がタスク管理用、`ideas/` がアイデアボード用。

### 第 2 コミット（`a28ff299` 01:07 UTC）= Lock コミット

- `current_tasks/initial_compiler_scaffold.txt` を 1 ファイル追加しただけ。これが**タスクの「Claim」**。

ファイルの中身:

```
Task: Initial C Compiler Scaffold

Building the complete initial scaffold for the C compiler in Rust.
This includes:
- Full directory structure (frontend, ir, passes, backend, common, driver)
- Lexer, preprocessor, parser, sema basics
- x86_64 backend with native ELF generation
- ARM64 and RISC-V backend stubs
- Driver with CLI args
- Three binaries: ccc (x86), ccc-arm, ccc-riscv
- Goal: pass "int main() { return N; }" and simple printf tests
```

### 第 3 コミット（`26f6f8b2` 01:30 UTC）= 最初の実装

- **59 ファイル、+5,657 行**の巨大なコミット。Rust で書かれた C コンパイラの全パイプライン（Lexer, Parser, Preprocessor, IR, x86/ARM/RISC-V の 3 バックエンド）を一発で投入。
- このコミットで `current_tasks/initial_compiler_scaffold.txt` を**削除**（タスク完了 = ロック解放）。
- 同時に `ideas/` に 3 つのアイデアファイルを追加（preprocessor 改善、ELF ライター、レジスタアロケータ）。

### 初期フェーズの粒度パターン

```
Lock (タスク宣言) → Implement (実装+ロック解放) → [Add idea] → Lock → Implement → ...
```

具体的な時間軸（最初の数時間）:

| 時刻(UTC) | コミット | 内容 |
|---|---|---|
| 01:04 | 初期構造 | 空ディレクトリ |
| 01:07 | **Lock** | scaffold タスク宣言 |
| 01:30 | **Implement** | 5,657 行の scaffold (23 分で実装) |
| 01:37 | **Lock** | array subscript タスク宣言 |
| 01:54 | **Implement** | array subscript 実装 (17 分) |
| 01:55 | Add idea | type-aware codegen のアイデア |
| 02:09 | **Lock** | type-aware codegen 宣言 |
| 02:19 | **Implement** | type-aware codegen 実装 (10 分) |

初日だけで **359 コミット**。ピーク日（2/5）は **558 コミット**。

### 日別コミット数

| 日付 | コミット数 |
|---|:---:|
| 01-23 | 359 |
| 01-24 | 442 |
| 01-25 | 405 |
| 01-26 | 383 |
| 01-27 | 289 |
| 01-28 | 294 |
| 01-29 | 308 |
| 01-30 | 332 |
| 01-31 | 39 |
| 02-01 | 48 |
| 02-02 | 10 |
| 02-03 | 77 |
| 02-04 | 437 |
| 02-05 | 558 |

---

## 2. 初期コミットは Claude か人間か

**結論: 初期コミットは 100% Claude が行っている。**

- 全 3,982 コミット中、**3,980 コミットが `Claude Opus 4.6 <noreply@anthropic.com>`** の author。
- **人間のコミットはたった 2 件**:
  - `e6f3fad0` (2026-02-05) Nicholas Carlini: LICENSE 追加と免責事項
  - `6f1b99ac` (2026-02-05) Nicholas Carlini: Linux カーネルビルド再現手順の追加
- つまり、**人間の作業はプロジェクト公開直前の文書整備のみ**。コード実装に人間は一切関与していない。
- AGENT_PROMPT.md や CLAUDE.md はリポジトリに含まれていない（公開前に削除されたか、Docker 内の別の場所にあったと推測される）。

README にも以下の記載がある:

> Note: With the exception of this one paragraph that was written by a human, 100% of the code and documentation in this repository was written by Claude Opus 4.6. A human guided some of this process by writing test cases that Claude was told to pass, but never interactively pair-programmed with Claude to debug or to provide feedback on code quality.

---

## 3. タスク Claim によるロック機構は本当に存在するか

**結論: はい、まさに `current_tasks/` ディレクトリを使ったオプティミスティックロッキングが確認できた。**

### 統計

| コミットタイプ | 件数 |
|---|---|
| `Lock:` (タスク Claim) | **1,571** |
| `Unlock:` (明示的ロック解放) | **332** |
| `Remove.*lock` (ロック削除) | **247** |
| `Starting new run; clearing task locks` (エージェント再起動時の全クリア) | **14** |
| `Add idea:` (アイデア投稿) | **31** |
| `Merge` (マージコミット) | **7** |

### ロックの仕組み（実際のデータから確認）

**Lock コミット**は、`current_tasks/<task_name>.txt` を**1 ファイルだけ追加**して push する。ファイル内容にはタスクの説明と計画が記述される:

```
Task: Implement array subscript (read/write) and lvalue assignments

Currently:
- Array subscript (a[i]) always returns 0 (placeholder)
- Assignment only works for simple identifiers, not arr[i] = val or *p = val
- Compound assign / pre/post inc/dec only work for identifiers
- Short-circuit evaluation (&&, ||) not implemented (uses bitwise AND/OR)
- Declarations with array sizes don't allocate correct amount

Plan:
1. Fix array declaration to allocate element_size * array_length bytes
2. Implement GetElementPtr for array subscripts in lowering
3. Implement lvalue-aware assignments for arr[i], *p
4. Implement short-circuit evaluation for && and ||
5. Handle compound assign and pre/post inc/dec for array elements and deref
6. Update all three backends (x86, arm, riscv) as needed
```

**実装完了コミット**では、タスクファイルを**削除**してコードを追加する（＝ロック解放と実装のアトミック操作）。

### 重複 Claim の実証（並列動作の証拠）

**ドライバモードの 3 重衝突** (03:52 UTC、同じ分内):

```
80bcfef2 03:52:01 Lock: implement driver compilation modes (-S, -c, -E, -D)
157ec6b3 03:52:24 Lock: implement compiler driver modes (-S, -c, -E, -D, -I, -g)
83611ab5 03:52:46 Lock: implement driver flags -D, -S, -c, -E
```

→ 3 つの異なるエージェントが**ほぼ同時に（45 秒以内に）**同じ機能のロックを取ろうとしている。

**function pointer indirect calls の二重 Claim**:

```
da088ca5 03:39:08 Lock: implement function pointer indirect calls
0958c591 03:47:11 Starting new run; clearing task locks  ← ロック全クリア
d3e651ae 03:48:11 Lock: implement function pointer indirect calls  ← 再度Claim
```

**static local variables の二重 Claim**:

```
f42b4f9f 04:02:33 Lock: fix static local variables
1d43d3bd 04:03:38 Lock: implement static local variable support
```

**Stale lock の検知と除去**:

```
8dd9ad18 03:59:56 Lock: fix CallIndirect build breakage in passes
6bbf2701 04:00:30 Remove stale lock: CallIndirect build breakage already fixed
```

→ あるエージェントがロックを取った時点で、別のエージェントが既に修正済みだった。34 秒後にロックが stale と判断され削除。

### エージェント再起動時のロック全クリア

`Starting new run; clearing task locks` コミット（14 件）では、`current_tasks/` 内の全ファイルを一括削除する。これは while true ループの再起動時に、前の実行で残った孤立ロックを掃除する仕組み。

### ideas/ システム

エージェントは実装中に `ideas/` ディレクトリにアイデアファイルを投稿する。これは他のエージェントへの「次にやるべきこと」の提案として機能する:

```
Type-Aware Code Generation

Current problem:
All backends use 8-byte (64-bit) operations for every value regardless of type.
...
Priority: HIGH
Impact: Would likely improve pass rate by 5-10% across all targets.
```

人間もこのシステムを通じてエージェントに指示を出した痕跡がある:

```
commit 2ef22e52 "Tell it to implement SSA"
→ ideas/IMPORTANT_implement_ssa.txt:
  "The SSA pass is currently a NOP. Implement SSA to simplify future code..."
```

---

## 4. まとめ

| 質問 | 回答 |
|---|---|
| 0→1 の粒度 | 最初の実装コミットが 5,657 行の巨大 scaffold。その後は「Lock→Implement」のペアで 10〜25 分単位の機能追加 |
| 初期コミットの主体 | **全て Claude**。人間は公開直前の LICENSE/ドキュメントのみ(2 件) |
| タスク Claim ロック | **完全に実在**。`current_tasks/` ディレクトリへのファイル追加=Lock、削除=Unlock。並列衝突・stale lock 検知・全クリアも確認済み |

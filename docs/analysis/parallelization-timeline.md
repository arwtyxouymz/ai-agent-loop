# 直列 → 並列化のタイムライン

本ドキュメントは、claudes-c-compiler リポジトリのコミット履歴を時系列で分析し、エージェントの並列化がどのように進行したかを実証したものである。

**結論: 最初は完全に直列で、段階的に並列化が進んでいる。**

---

## フェーズ 1: 完全直列（コミット#1〜#12、01:04〜02:49、約 1 時間 45 分）

```
#1  01:04  初期構造
#2  01:07  Lock: scaffold          ─┐ 1エージェント
#3  01:30  Implement scaffold      ─┘ (23分)
#4  01:37  Lock: array subscript   ─┐ 1エージェント
#5  01:54  Implement array         ─┘ (17分)
#6  01:55  Add idea
#7  02:09  Lock: type-aware codegen─┐ 1エージェント
#8  02:19  Implement type-aware    ─┘ (10分)
#9  02:23  Lock: global vars       ─┐ 1エージェント
#10 02:33  Implement global vars   ─┘ (10分)
#11 02:38  Lock: preprocessor      ─┐ 1エージェント
#12 02:49  Implement preprocessor  ─┘ (11分)
```

**特徴**: 完全にきれいな `Lock → Implement` のペアが交互に並び、10 分間隔が開いている。10 分窓のスループットは **1〜2 コミット**。明らかに**1 エージェントのみ**が動作。

---

## フェーズ 2: 2 エージェント（コミット#13〜#21、02:55〜03:30）

```
#13 02:55  Lock: typedef tracking       ─┐ Agent A
#14 02:57  Lock: switch lowering        ─┐│ Agent B  ← ★ 初の並列!
#15 03:06  Implement switch             ─┘│
#16 03:07  Remove lock: switch           │
#17 03:12  Lock: struct support         ─┐│
#18 03:14  Implement typedef tracking   ──┘ Agent A完了
#19 03:20  Lock: parser robustness       │
#20 03:29  Implement struct/union       ─┘
```

**決定的証拠**: コミット#13 と#14 で、**Implement を挟まずに Lock が 2 つ連続**している。Agent A が typedef を Lock(02:55)した 2 分後に Agent B が switch/case を Lock(02:57)。switch の実装が先に完了(03:06)し、typedef の実装は後に完了(03:14)。**異なるタスクが並行して進行している。**

---

## フェーズ 3: 3〜4 エージェント（コミット#22〜#27、03:34〜03:39）

```
#22 03:35:03  Lock: enum constant        ─┐ Agent A
#23 03:34:45  Implement parser robustness    Agent B(タイムスタンプ逆転!)★
#24 03:35:07  Lock: stack param passing  ─┐ Agent C
#25 03:35:40  Lock: stddef/stdlib macros ─┐ Agent D
#26 03:36:03  Add ideas                     (もう1エージェント?)
#27 03:39:08  Lock: function pointer     ─┐ Agent E?
```

**60 秒間に 3 つの Lock** + 1 つの Implement + 1 つの Add idea。タイムスタンプの**初めての逆転**（#23 が#22 より 18 秒前の時刻）が発生。これは Git のコミット順≠時系列順であることを意味し、**別々のエージェントが独立に push している**決定的な証拠。

---

## フェーズ 4: 大量並列（コミット#29 以降、03:47〜、再起動後）

`Starting new run; clearing task locks` (03:47) の後、爆発的に並列度が上がる:

```
03:48:11  Lock: function pointer     ─┐
03:48:36  Lock: optimization passes  ─┐  ← 25秒差
03:51:10  Lock: semantic analysis    ─┐
03:52:01  Lock: driver (-S,-c,-E)    ─┐
03:52:24  Lock: driver modes         ─┐  ← 同じ機能の重複Claim!
03:52:46  Lock: driver flags         ─┐  ← 3エージェントが同時に
03:52:44  Implement function pointer ─┘  ← タイムスタンプ逆転
03:53:39  Lock: unsigned types       ─┐
03:53:22  Implement optimization     ─┘  ← タイムスタンプ逆転
```

**10 分窓で 13 コミット**。5 分間に 6 つの Lock が立て続けに発生。ドライバモード機能に 3 エージェントが同時に Claim しようとする衝突も発生。

---

## スループットの推移（10 分窓あたりのコミット数）

```
01:00  ██ 2
01:30  ██ 2
01:50  ██ 2
02:00  █ 1           ← 完全直列期
02:10  █ 1
02:30  ██ 2
02:50  ██ 2
03:00  ██ 2
03:10  ██ 2           ← 2並列開始
03:20  ██ 2
03:30  ███████ 7      ← 3-4並列に急増
03:40  ███ 3
03:50  █████████████ 13  ← 再起動後、フル並列
05:40  ██████ 6       ← 2回目の再起動後
06:20  ████████ 8
07:00  ███████ 7
```

---

## 並列ロック数の時間推移

| 時刻(UTC) | 最大同時ロック数 | 推定エージェント数 |
|---|:---:|:---:|
| 01:00 | 1 | **1** |
| 02:00 | 2 | **2** |
| 03:00 | 6 | **~6** |
| 05:00 | 8 | **~8** |
| 06:00 | 13 | **~13** |
| 07:00 | 17 | **~16** |
| 09:00 以降 | 16-22 | **16+**（定常状態） |

---

## タイムスタンプ逆転（並列 push の決定的証拠）

プロジェクト全体で **362 回** のタイムスタンプ逆転が発生。最初の逆転はコミット#23（03:34:45）。

コミット履歴の詳細分析（gap = 前のコミットとの時間差）:

```
  1 | 01:04:22 |          | d8cbbec8 Initial commit: empty repo structure
  2 | 01:07:13 | gap=+171s | a28ff299 Lock: initial compiler scaffold task
  3 | 01:30:44 | gap=+1411s | 26f6f8b2 Initial compiler scaffold
  4 | 01:37:41 | gap=+417s | ce657fb2 Lock: implement array subscript
  5 | 01:54:39 | gap=+1018s | 46d5f2b0 Implement array subscript
  ...
 13 | 02:55:07 | gap=+355s | c91ff45f Lock: implement typedef tracking in parser
 14 | 02:57:41 | gap=+154s | 4464a023 Lock: implement proper switch/case/default
    ... (2つの Lock が同時に存在 = 2並列の証拠) ...
 22 | 03:35:03 |          | 9c918688 Lock: implement enum constant resolution
 23 | 03:34:45 | gap= -18s | 3bd91b08 Improve parser robustness  <<<< TIMESTAMP REORDER
    ... (初のタイムスタンプ逆転 = 並列pushの決定的証拠) ...
 32 | 03:52:01 | gap= +51s | 80bcfef2 Lock: driver compilation modes
 33 | 03:52:24 | gap= +23s | 157ec6b3 Lock: driver modes
 34 | 03:52:46 | gap= +22s | 83611ab5 Lock: driver flags
 35 | 03:52:44 | gap=  -2s | 4cb613ae Implement function pointer  <<<< PARALLEL!
```

# ドライバーインターフェース仕様

*[English](driver-interface.md)*

**Status:** draft (epic [#51](https://github.com/fujibee/agmsg/issues/51))
**Scope:** 軸A — storage。共通プロトコルの節は軸B（agent）および軸C（delivery）にも適用されるが、それらの軸固有の関数はここでは対象外とする。

本書は、agmsgコアとstorageドライバー間の契約を定義する。新規ドライバーが実装すべき内容の正式な情報源である。

**v1のスコープ:** バンドル済みドライバーのみ。プラグインパス（`~/.agents/agmsg/plugins/`）、`plugin.json` のメタデータ、`min_core_version` によるゲーティングは将来のリビジョンに先送りされる。§6を参照。

## 1. 共通ドライバープロトコル

これらの規約はすべての軸のすべてのドライバーに適用される。

### 1.1 ドライバーの配置場所

バンドル済みドライバーは `scripts/drivers/<axis>/<name>` に配置される。ファイルベースの軸では単一の `<name>.sh` を使用し、エージェントタイプ（"types"）軸では `type.conf` マニフェストとそのタイプのランタイムを格納するディレクトリ `scripts/drivers/types/<name>/` を使用する。それらのメタデータは暗黙的であり、agmsgコアのバージョンに紐づく。

外部（非バンドル）ドライバーは `<install_dir>/plugins/<axis>/<name>` および `$AGMSG_PLUGIN_DIRS` から検出され、明示的なオプトインが必要である — 詳細は [ADR 0002](../adr/0002-driver-discovery-and-plugin-opt-in.md) を参照。

### 1.2 呼び出し規約

ドライバーはbashスクリプトであり、agmsgコアがこれを `source` してから関数名で呼び出す。関数名は衝突を避けるため軸ごとにプレフィックスが付く：storageドライバーは `storage_*` 関数を、agentドライバーは `agent_*` 関数を、deliveryドライバーは `delivery_*` 関数を公開する。

ドライバーはそのプレフィックスを超えてグローバル名前空間を汚染してはならず、`set -e`/`set -u` のセマンティクスを定義してはならない。これらは呼び出し元の責任である。

### 1.3 必須の共通関数

すべての軸のすべてのドライバーは以下を実装する：

| Function | Purpose | Returns |
|---|---|---|
| `<axis>_check` | すべてのランタイム依存関係が存在し、ドライバーが有効化できることを検証する。依存関係が不足している場合、stdoutに `AGMSG-DIRECTIVE` を出力することがある。 | ステータスコード（§1.4を参照） |
| `<axis>_describe` | stdoutに人間可読な1行の説明を出力する。 | 常に0 |

### 1.4 ステータスコード

失敗しうるドライバー関数は、終了コード**および**stdoutの最終行にステータス名を出力することで、構造化されたステータスを報告する。ステータス名は以下の通り：

| Code | Name | Meaning |
|---|---|---|
| 0 | `ok` | 操作が成功した |
| 10 | `missing_deps` | 必要な外部依存関係がインストールされていない。インストール方法を記述した `AGMSG-DIRECTIVE` がstdoutに出力された。 |
| 12 | `corrupt_state` | ドライバーがデータストア内で回復不能な不整合を検出した。手動での対応が必要。 |
| 13 | `runtime_error` | その他すべての失敗。stderrにメッセージが含まれる。 |

（コード `11 incompatible_core` は将来のプラグインローダー用に予約されており、v1では使用されない。）

呼び出し元は非ゼロの終了コードをすべて失敗として扱ってよいが、ホストエージェントの挙動決定においてはステータス名が正となる。

### 1.6 `AGMSG-DIRECTIVE`

stdoutに書き込まれる1行で、`AGMSG-DIRECTIVE: ` というプレフィックスの後にJSONオブジェクトが続く。ホストエージェントはこのディレクティブを読み取り、パースし、それに基づいて動作する。

```
AGMSG-DIRECTIVE: {"type":"install_deps","driver":"jsonl-duckdb","commands":["brew install duckdb"],"reason":"duckdb binary not found on PATH"}
```

| Field | Type | Description |
|---|---|---|
| `type` | string | `install_deps`、`invoke_monitor`、`stop_task` のいずれか。拡張可能。 |
| `driver` | string | ディレクティブを発行したドライバー名（該当する場合） |
| `commands` | string[] | ホストエージェントが順に実行してよいシェルコマンド。任意。 |
| `reason` | string | ユーザー向けの人間可読な説明。 |
| `*` | any | タイプ固有のフィールド。本書内のタイプ別スキーマを参照。 |

ディレクティブはあくまで助言であり、ユーザーに提示するか、自動的に実行するか、無視するかはホストエージェントが決定する。

## 2. Storageドライバー

### 2.1 必須関数

```
storage_check
storage_describe
storage_init
storage_insert_message <team> <from> <to> <body>
storage_unread <team> <agent> [--limit N]
storage_mark_read <id>
storage_mark_read_batch <id> [<id> ...]
storage_history <team> <agent> [--limit N]
storage_teams
storage_team_members <team>
storage_export <file>
storage_import <file>
```

すべての関数は、レコードを返す際にstdoutへ構造化された出力（JSONL）を書き込み、ステータスについては§1.4に従う。message/event recordには常に `id`（新規書き込みではUUIDv7、レガシーIDでは不透明な文字列）と `at`（ISO-8601 UTC）が含まれる。metadata、cursor、summary、result、error recordは各操作で定義したfieldだけを持つ。

#### 2.1.1 bounded read-only操作（fork order 2b phase 1）

バンドル済みドライバーは、後続のCLI・receipt・ackが利用する下位の読み取り面として、次の関数も提供する：

```
storage_unread_summary <team> <agent>
storage_list_unread_bounded <team> <agent> [--limit-items N] [--max-body-bytes N]
storage_get_message_bounded <team> <agent> <opaque-id> [--max-body-bytes N]
```

これらは読み取り専用の観測である。存在しないstoreはファイル、schema、移行marker、cursor、lock、event、receipt、claim、keyその他の永続状態を作らず、空のsummaryまたはbounded listを返す。存在するが読めないstoreは空として扱わず、non-zeroで失敗する。各操作は1つの一貫したsnapshotを読み、公開stdoutへ出す前に候補全体を検証する。

`storage_unread_summary` は次の1 JSON recordを返す。空集合では `newest_id` が `null` になる。bodyは含めない。

```json
{"type":"unread_summary","unread_count":2,"newest_id":"..."}
```

`storage_list_unread_bounded` はdelivery順のunread `message_sent` の連続prefixを返し、最後に選択分と残りの件数・body byte数を示すrecordを返す。既定値は `limit_items=10`、`max_body_bytes=4096` で、指定値はそれぞれ `0..10`、`0..4096` である。body byte数はraw UTF-8 byte数で数え、bodyを途中で切らない。先頭候補が上限を超える場合はbodyを含まない `type=bounded_unread_error` / `reason=body_too_large` のbounded metadataだけを出してnon-zeroで終了する。後続候補が収まらない場合はremainingの件数・byte数に残す。範囲外の引数、malformed envelope、曖昧な候補、driver failureでは公開stdoutを出さずnon-zeroで終了する。

この3操作が生成する完成済みJSON recordには、出力安全ポリシー `AGMSG_BOUNDED_MAX_RECORD_BYTES` も適用する。既定値はraw UTF-8で8,192 bytes、設定する10進値の最大は65,536である。byte数はcompact JSON recordを数え、末尾newlineは含めない。driverは公開出力前に、その操作が出力し得る全recordを検証するため、list/showでは候補message recordに加えてresult/error recordも対象になる。完成recordが1件でもポリシーを超える場合、操作全体をnon-zero、stdout 0 bytes、永続状態変更なし、bounded stderr diagnosticで失敗させる。

これはbounded操作が出力する1 recordの上限であり、ID transport grammarやID固有の最大長ではない。opaque IDもencoded record byte数には含まれるため、そのIDを含むbounded recordが利用不能になることはあるが、保存済みIDと既存のunbounded storage ABIは変更しない。downstreamのID transport契約が決まるまで、`.agents`はこのbounded surfaceを呼び出さず、そのためのfork pinやruntime activationも行わない。

`storage_get_message_bounded` は指定agent宛てで、opaqueな保存済みIDに一致するunread `message_sent` を、body全体が上限内の場合だけ1件返す。recipient scopeを越えず、read markerやcursorを変更しない。後続行を調べてもack候補にはならない。bodyが大きすぎる場合はbodyを含まない `bounded_message_error` metadataだけを出してnon-zeroで終了する。ここでIDはbyte-for-byteのopaque stringであり、transport encoding、shell quoting、新しいID上限は定義しない。

この3関数の通常呼び出しは引き続き読み取り専用である。次節のoptional
SQLite receipt extensionは、明示的な`--issue-receipt`を指定しない限り
通常動作を変更しない。JSONL receipt/crash recoveryとupstream `#373`との
最終precedenceはこのphaseの対象外である。

#### 2.1.2 Optional SQLite receipt acknowledgement（fork order 2b phase 2）

SQLiteは完全一致capability token `sqlite-receipt-ack-v1`をadvertiseし、
次のoptional ABIを提供できる：

```
storage_receipt_init <team>
storage_receipt_status <team>
storage_ack_receipt <team> <recipient> --receipt <token>
```

receipt発行はbounded listとexact-showの明示的な`--issue-receipt` optionである。
選択した全recordが既存の出力検査を通過した後だけ、最後にcompactな
`bounded_unread_receipt` recordを1件追加する。receiptの有効期間は発行から
正確に900秒、tokenは最大2,048 bytesで、完成recordには
`AGMSG_BOUNDED_MAX_RECORD_BYTES`（既定8,192、設定可能な最大65,536）も
適用する。上限超過その他の失敗はnon-zero、stdout 0 bytes、永続変更なし、
boundedかつ非機密のstderrとなる。canonical byte契約とfixed vectorは
[ADR 0005](../adr/0005-sqlite-receipt-ack.md)を規範とする。

JSONLはこのoptional ABIをadvertiseも実装もせず、`--issue-receipt`を
non-zero、stdout 0 bytes、永続変更なしで拒否する。Git Bash/Windowsも
receipt init・issue・ackは非対応である。既存のlegacy経路とbounded
read-only経路は引き続き利用できる。

ackは同じclosed claim predicateを操作開始時と、`BEGIN IMMEDIATE`を開いて
全receipt効果が未commitの状態で`COMMIT`する直前に再検査する。predicate
authorityを変更するclaimのinstall・remove・update、またはagmsgの
install/updateを、receipt init・issue・ackと並行して実行してはならない。
SQLiteの`claims` tableはtransaction内でguardするが、repository file、
loaded shell function、capability metadataはSQLiteのatomic domain外にある。
2回目の検査からcommitまでには残存TOCTOUがあり、hard-atomic claim
interlockと表現してはならない。

nonce消費、対応する`message_read` event、exact legacy `read_at` mirror、
cursor前進、対象nonce pruneは1つのSQLite durable commitで行う。この保証は
外部claim保守へは及ばない。retention中の全field nonce evidenceが一致する
exact retryは`already_committed`となり、prune済みまたは不一致のreplayは
拒否する。diagnosticにreceipt token、key bytes、private body、private
filesystem pathを含めてはならない。

このextensionはopaque IDのtransport grammarもID固有最大長も定義せず、
JSONL receipt pathやlive `.agents` callerを追加しない。downstreamのinstall、
update、dependency pin、runtime activationには、先に`cattyneo/.agents#220`の
完了が必要である。

### 2.2 イベントログスキーマ

バンドル済みドライバーは、状態を追記専用のイベントログとして表現する。各イベントは `type` 判別子を持つ1レコードである：

```jsonl
{"type":"message_sent","id":"0192...","team":"agsuite","from":"alice","to":"bob","body":"...","at":"2026-05-30T19:00:00Z"}
{"type":"message_read","id":"0192...","msg_id":"0192...","agent":"bob","at":"2026-05-30T19:05:00Z"}
{"type":"team_joined","id":"0192...","team":"agsuite","agent":"alice","agent_type":"claude-code","project":"/path","at":"..."}
{"type":"team_left","id":"0192...","team":"agsuite","agent":"alice","at":"..."}
```

ドライバーはこれらのイベントを射影してクエリに応答する。`storage_unread` は、要求元エージェントに対応する `message_read` が存在しない `id` を持つ `message_sent` イベントを返す。

### 2.3 レガシー互換性（sqliteのみ）

バンドル済みのsqliteドライバーは、`storage_unread` と `storage_history` について2つのソースを読み取る：

1. イベントログのリファクタリング以前のインストールのための、レガシーな `messages` テーブル（`read=0` の行）
2. リファクタリング後に書き込まれたすべてのデータのための、新しいイベントログテーブル

通常の書き込みはイベントログを対象とする。§2.1.2のoptional receipt ackだけは
例外として、exact direct legacy rowまたは`events.legacy_id`で結ばれたexact rowの
`read_at`をmirrorする。その他の新しいread progressはlegacy `read_at`を変更しない。
自動的なマイグレーションは存在せず、レガシーな行はそのまま残り、無期限にクエリ可能であり続ける。

### 2.4 識別子

ドライバーが生成するすべてのIDは**UUIDv7**文字列でなければならない。インターフェースはIDを不透明なものとして扱うため、レガシーデータ（sqliteの整数自動採番ID）を読み取るドライバーは、それらを10進数文字列としてそのまま通過させてよい。

UUIDv7はドライバー内部で生成する（例：`python -c "..."`、v7に対応するプラットフォームでの `uuidgen`、またはシェル実装）。ドライバーはカウンターファイルに依存してはならない。

### 2.5 並行性

ドライバーは、そのバッキングストアの並行性モデルに責任を持つ：

- sqliteドライバーはSQLiteのWALモードに依存する。
- `jsonl-duckdb` ドライバーは、mark-readのシーケンス周辺および `convert`/`export`/`import` の周辺でロックファイルを使用しなければならない。単一メッセージの追記は、`PIPE_BUF` バイト以下の書き込みについてはPOSIXの追記アトミック性に依存してよい。

### 2.6 コンパクション

イベントログは無制限に増加する。ドライバーは、冗長なイベントを圧縮する内部関数 `storage_compact` を実装しなければならない（例：`message_read` マーカーの統合、削除済みチームのイベントの削除）。v1ではこれを内部コマンドとしてのみ公開し、ユーザー向けCLIは今後追加される可能性がある。

## 3. CLIマッピング

| User command | Driver function(s) |
|---|---|
| `agmsg storage` | アクティブなドライバーの `storage_describe` |
| `agmsg storage list` | 利用可能なドライバーを列挙し、ドライバーごとに `<axis>_describe` を呼び出す |
| `agmsg storage switch <name>` | 新しいドライバーの `storage_check`；`ok` の場合は設定を更新し、`missing_deps` の場合は切り替えずにディレクティブを伝播する |
| `agmsg storage convert <to>` | 新しいドライバーの `storage_check`；`ok` であれば、現行の `storage_export` → 一時ファイル → 新ドライバーの `storage_import` → 検証 → 設定のアトミックな更新 |
| `agmsg storage export <file>` | アクティブなドライバーの `storage_export` |
| `agmsg storage import <file>` | アクティブなドライバーの `storage_import` |

## 4. 設定

軸ごとのアクティブなドライバーは `~/.agents/agmsg/config.json` に記録される：

```json
{
  "storage": "sqlite",
  "delivery": { "claude-code": "monitor", "codex": "turn" }
}
```

`storage` は単一の文字列（マシン全体で共通）。`delivery` はエージェントタイプごとに設定される。これはランタイムによって利用可能な配送メカニズムが異なるためである。`agent` は呼び出しごとの `<type>` 引数から暗黙的に決まる。

## 5. スコープ外（先送り）

- **プラグインローダー** — 外部ドライバーの検出（`<install_dir>/plugins/`、`$AGMSG_PLUGIN_DIRS`）とオプトインの信頼モデルは、現在 [ADR 0002](../adr/0002-driver-discovery-and-plugin-opt-in.md) で定義されている。そのローダーからなお先送りされているのは、`plugin.json` のメタデータ解析、`min_core_version` によるゲーティング、および `incompatible_core` ステータスコードである。
- **プラグインの署名またはサンドボックス化** — ローダーとは直交する問題であり、ローダーが実装された時点で対応される。
- **プロジェクトごとのアクティブドライバーの上書き** — v1はマシン全体で共通であり、将来の拡張項目とする。
- **サブコマンド + JSONLパイプによるドライバープロトコル**（言語非依存のドライバー） — bash以外のドライバーが実際に必要になるまで先送りする。
- **クロスマシンのstorageドライバー**（postgres、s3-jsonl） — 本仕様によってブロックされるものではなく、必要になれば同じプロトコルの下で追加できる。

# rsync_migrate.sh

ファイルに書かれたディレクトリ一覧をもとに、rsync でディレクトリを移行・同期するツールです。
**移行先サーバ上で実行し、移行元からデータを取得します。**

## 必要なもの

| ツール | 用途 |
|---|---|
| bash 4.0 以上 | スクリプト実行 |
| rsync | ファイル転送 |
| ssh | リモートサーバへの接続 (`-S` 使用時) |
| sshpass | パスワード認証 (`-W` または `@user:password` 使用時) |

## 使い方

```
./rsync_migrate.sh [オプション] <移行リストファイル>
```

引数なしで実行するとヘルプが表示されます。

### オプション

| オプション | 説明 |
|---|---|
| `-S`, `--src-host HOST` | 移行元サーバ (省略時: ローカル) |
| `-W`, `--ask-password` | パスワード認証を使用する・起動時に対話入力 (要: sshpass) |
| `-e`, `--execute` | 実際に同期を実行する (省略時: ドライラン) |
| `-nc`, `--no-checksum` | チェックサム比較を無効化 (タイムスタンプ+サイズ比較、高速) |
| `-L`, `--log DIR` | ログ出力先ディレクトリ (省略時: `./exe_results/rsync_migrate_YYYYMMDD_HHMMSS/`) |
| `-h`, `--help` | ヘルプを表示 |

## 移行リストファイルの書式

```
@user:password               ← ユーザ切り替え (@ で始まる行)
<移行元パス> [移行先パス]    ← ディレクトリ指定
```

- `@user:password` 行でユーザとパスワードを切り替えます
- ディレクトリ行は直前の `@` 行のユーザで接続します
- 移行先パスを省略すると、移行元と同じパスとして扱われます
- `#` から始まる行・空行はスキップされます

```
# ユーザ別パスワードを使う場合
@user01:password01
/home/user01/work/dir1
/home/user01/work/dir2

@user02:password02
/home/user02/work/dir1

# パスが異なる場合は2列で指定
@user03:password03
/home/user03/work/old    /home/user03/work/new
```

### @ 行を使わない場合 (鍵認証 / -W)

```
/data/projectA
/data/old/app    /data/new/app
```

## 実行の流れ

### ドライラン (デフォルト)

`-e` なしで実行すると、実際には何も変更せず差異だけ表示します。

```bash
./rsync_migrate.sh -S server1 migrate_list.txt
```

### 本番実行 (`-e`)

`-e` をつけると、まず自動でドライランを実行して差異を表示し、
確認後に本番同期を行います。

```
--- ドライラン (差異確認) ---
--- ユーザ切り替え: user01@server1 ---
[1] 移行元: user01@server1:/home/user01/work/dir1
    移行先: ローカル:/home/user01/work/dir1
  >f+++++++++ a.txt  ← 新規
  .f...p..... b.txt  ← パーミッション差異

=== 結果サマリー ===

以上の内容で同期を実行しますか？ [y/n]: y

--- 本番実行 ---
```

`n` を入力すれば何も変更せず終了します。

## rsync 差異の見方

`--itemize-changes` と `--checksum` により、差異の種類を記号と日本語で表示します。

```
>f+++++++++ a.txt  ← 新規
>fc.t....... b.txt  ← 内容差異/タイムスタンプ差異
>f..t....... c.txt  ← タイムスタンプ差異
.f...p..... d.txt  ← パーミッション差異
.f....o.... e.txt  ← オーナー差異
*deleting   f.txt  ← 移行先にのみ存在 (削除対象)
```

- `>` で始まる行: ファイルの転送が発生する (内容が違う・新規・削除)
- `.` で始まる行: 内容は同一、メタデータのみ異なる

## 確認モード

本番実行 (`-e`) 時の動作:

- ドライランを自動実行して差異を表示
- `以上の内容で同期を実行しますか？ [y/n]` を一度だけ確認して全ディレクトリを一括実行

| 入力 | 動作 |
|---|---|
| `y` | 全ディレクトリを同期する |
| `n` | 中断して終了 |

## ログ出力

実行のたびにタイムスタンプのディレクトリを自動作成し、`result.log` に記録します。

```
exe_results/
└── rsync_migrate_20240115_143022/
    └── result.log
```

`-L` でディレクトリ名を指定することもできます：

```bash
./rsync_migrate.sh -S server1 -e -L /var/log/migration/run1 migrate_list.txt
```

## SSH 接続

- **ControlMaster** により SSH 接続を使い回すため、パスワードや鍵パスフレーズの入力は1回のみです
- ユーザ別パスワード (`@user:password`) 使用時は、ユーザごとに接続を確立します
- **鍵認証**: 移行先 → 移行元 への SSH 鍵を事前に設定します
- **パスワード認証 (`-W`)**: `-S user@host -W` で起動時に対話入力します (単一ユーザ向け)

```
[移行先サーバ (スクリプト実行)] --rsync/SSH--> [移行元サーバ]
```

## 権限・属性の保持

root で実行しても、各 Linux ユーザの `owner` / `group` / `permission` / `timestamp` が変わらないよう、以下の rsync オプションで転送します。

| オプション | 効果 |
|---|---|
| `-a` | パーミッション・タイムスタンプ・オーナー・グループ・シンボリックリンクを保持 |
| `-H` | ハードリンクを保持 |
| `-A` | ACL を保持 |
| `-X` | 拡張属性を保持 |
| `--delete` | 移行先にのみ存在するファイルを削除し、移行元と完全一致させる |
| `--checksum` | チェックサムで差異を判断 (内容が本当に違うか確認、デフォルト有効) |

## 実行例

```bash
# ① ドライランで差異を確認 (デフォルト。何も変更されない)
./rsync_migrate.sh -S server1 migrate_list.txt

# ② 本番実行 (ドライラン確認 → y/n → 同期)
./rsync_migrate.sh -S server1 -e migrate_list.txt

# ③ チェックサム無効 (大量ファイル・大容量で遅い場合)
./rsync_migrate.sh -S server1 -nc migrate_list.txt

# ④ -W でパスワード認証 (単一ユーザ・対話入力)
./rsync_migrate.sh -S user@server1 -W -e migrate_list.txt
```

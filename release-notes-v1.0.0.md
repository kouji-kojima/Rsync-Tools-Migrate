# v1.0.0

rsync を使ったサーバ間ディレクトリ移行ツールの初回正式リリースです。

## スクリプト構成

| ファイル | 用途 |
|---|---|
| `rsync_migrate.sh` | 標準版。ドライランで全差異を詳細表示してから実行 |
| `rsync_migrate_quiet_mode.sh` | quiet_mode版。事前チェックは差分行のみ表示・高速 |

## 主な機能

### 事前チェック（ドライラン）の最適化
- 事前チェック時はファイルごとのプリント処理を排除し、差分行のみを表示（高速化）
- `-v` フラグを除去し `--itemize-changes` のみで差分ファイルを出力

### 新オプション
- **`-O` / `--ssh-opt`**: SSH オプションを任意に追加（複数指定可）。OpenSSH セキュリティパッチで `ssh-rsa` が無効化された環境での `-O "HostKeyAlgorithms=+ssh-rsa"` 指定に対応
- **`-y` / `--yes`** (quiet_mode版のみ): 事前チェックをスキップして確認プロンプトから直接開始

### SSH 接続の改善
- ControlMaster による接続再利用（パスワード入力1回）
- `-y` モード時に事前接続確立（ユーザ切り替え後のパスワード再入力を防止）

### 接続エラーの診断
- ファイアウォール・到達不能・暗号アルゴリズム不一致を終了コードと SSH stderr で自動判定してヒントを表示
- 暗号不一致時（`no matching host key type` 等）は `-O "HostKeyAlgorithms=+ssh-rsa"` の使用を案内
- SSH の生のエラーメッセージをログに `[stderr]` 付きで記録

### 拡張属性 (`-X`) の除外（quiet_mode版）
- CentOS → RHEL 等、OS 間移行では SELinux ラベル等の xattr が一致しないため quiet_mode版は `-X` を除外。移行後は `restorecon -R <パス>` で再設定

## 動作要件

| ツール | 用途 |
|---|---|
| bash 4.0 以上 | スクリプト実行 |
| rsync | ファイル転送 |
| ssh | リモートサーバへの接続 (`-S` 使用時) |
| sshpass | パスワード認証 (`-W` または `@user:password` 使用時) |

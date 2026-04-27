#!/usr/bin/env bash
# rsync_migrate.sh - サーバ間ディレクトリ移行ツール
#
# 使い方:
#   ./rsync_migrate.sh [オプション] <移行リストファイル>
#
# オプション:
#   -S, --src-host HOST         移行元サーバ (省略時: ローカル)
#   -W, --ask-password          SSH接続にパスワード認証を使用する (要: sshpass)
#   -e, --execute               実際に同期を実行する (省略時: ドライラン)
#   -nc, --no-checksum          チェックサム比較を無効化 (タイムスタンプ+サイズで比較、高速)
#   -L, --log DIR               ログ出力先ディレクトリ (省略時: ./exe_results/rsync_migrate_YYYYMMDD_HHMMSS/)
#   -h, --help                  このヘルプを表示
#
# ログ出力:
#   実行時刻のディレクトリを自動作成し、その中に result.log を出力します。
#   ディレクトリごとの開始/終了時刻・rsync出力・成否が記録されます。
#   -L で出力先ディレクトリ名を指定できます。
#
# 移行リストファイルの書式:
#   @user:password               # ユーザ切り替え (@ で始まる行、以降のディレクトリに適用)
#   <移行元パス> [移行先パス]    # ディレクトリ (移行先省略時は移行元と同じパス)
#   # から始まる行・空行はスキップ
#
#   例:
#     @aplap165:ap165dev
#     /home/aplap165/work/dir1
#     /home/aplap165/work/dir2
#
#     @aplap164:ap164dev
#     /home/aplap164/work/dir1     /mnt/backup/dir1
#
# 実行場所とSSH要件:
#   このスクリプトは移行先サーバ上で実行します。
#   ローカル同士      : -S 不要。SSH不要。
#   リモート→ローカル : -S server1
#     認証方式は以下の2通り:
#       ファイル内パスワード: @user:password 形式 (要: sshpass)
#       -W パスワード認証  : -S user@server1 -W (要: sshpass)
#       鍵認証            : SSH鍵を事前に設定 (移行先→移行元)
#
# 実行例:
#   # ① ドライランで差異を確認 (デフォルト。何も変更されない)
#   ./rsync_migrate.sh -S server1 migrate_list.txt
#
#   # ② 本番実行 (ドライラン差異確認 → y/n で一括実行)
#   ./rsync_migrate.sh -S server1 -e migrate_list.txt
#
#   # ③ チェックサム無効 (大量ファイル・大容量で遅い場合)
#   ./rsync_migrate.sh -S server1 -nc migrate_list.txt
#
#   # ④ -W でパスワード認証 (従来形式: ユーザを -S に含める)
#   ./rsync_migrate.sh -S user@server1 -W -e migrate_list.txt

set -euo pipefail

# ------------------------------------------------------------------ #
#  定数・初期値
# ------------------------------------------------------------------ #

RED='\033[1;37;41m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

DRY_RUN=true
ASK_PASSWORD=false
USE_CHECKSUM=true
LIST_FILE=""
SRC_HOST=""
SRC_BASE_HOST=""   # user@ を除いたホスト名
SSH_PASS=""
LOG_FILE=""
LOG_DIR=""

# ControlMaster ソケット管理 (user@host -> socket path)
declare -A HOST_SOCKETS=()
CTRL_SOCKET=""

# ------------------------------------------------------------------ #
#  引数パース
# ------------------------------------------------------------------ #

usage() {
    # シェバン行を除くヘッダーコメント (最初の非コメント行が来るまで) を表示する
    awk '/^[^#]/{exit} /^#!/{next} {sub(/^# ?/,""); print}' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -S|--src-host)
            [[ -z "${2:-}" ]] && { echo -e "${RED}エラー: --src-host に値が必要です${RESET}" >&2; exit 1; }
            SRC_HOST="$2"; shift 2 ;;
        -W|--ask-password) ASK_PASSWORD=true;    shift ;;
        -e|--execute)     DRY_RUN=false;       shift ;;
        -nc|--no-checksum) USE_CHECKSUM=false; shift ;;
        -L|--log)
            [[ -z "${2:-}" ]] && { echo -e "${RED}エラー: --log に値が必要です${RESET}" >&2; exit 1; }
            LOG_DIR="$2"; shift 2 ;;
        -h|--help)        usage ;;
        -*)
            echo -e "${RED}エラー: 不明なオプション '$1'${RESET}" >&2
            echo "使い方: $0 [-S host] [-W] [-e] [-i|-y] <リストファイル>" >&2
            exit 1 ;;
        *)
            if [[ -z "$LIST_FILE" ]]; then
                LIST_FILE="$1"
            else
                echo -e "${RED}エラー: 引数が多すぎます${RESET}" >&2; exit 1
            fi
            shift ;;
    esac
done

# ------------------------------------------------------------------ #
#  事前チェック
# ------------------------------------------------------------------ #

if [[ -z "$LIST_FILE" ]]; then
    usage
fi
[[ "$(id -u)" -ne 0 ]] && { echo -e "${RED}エラー: このスクリプトは root で実行してください${RESET}" >&2; exit 1; }
[[ ! -f "$LIST_FILE" ]] && { echo -e "${RED}エラー: ファイルが見つかりません: ${LIST_FILE}${RESET}" >&2; exit 1; }
command -v rsync &>/dev/null || { echo -e "${RED}エラー: rsync がインストールされていません${RESET}" >&2; exit 1; }

# ログディレクトリ・ファイルの初期化
local_ts="$(date '+%Y%m%d_%H%M%S')"
[[ -z "$LOG_DIR" ]] && LOG_DIR="exe_results/rsync_migrate_${local_ts}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/result.log"
: > "$LOG_FILE"

# -W オプション (従来形式: -S user@host -W)
if $ASK_PASSWORD; then
    if [[ -z "$SRC_HOST" ]]; then
        echo -e "${YELLOW}警告: -S が指定されていないため -W は無効です${RESET}" >&2
        ASK_PASSWORD=false
    else
        command -v sshpass &>/dev/null || { echo -e "${RED}エラー: sshpass がインストールされていません${RESET}" >&2; exit 1; }
        echo -en "${CYAN}${SRC_HOST} のSSHパスワード: ${RESET}"
        read -rs SSH_PASS </dev/tty
        echo ""
        [[ -z "$SSH_PASS" ]] && { echo -e "${RED}エラー: パスワードが入力されませんでした${RESET}" >&2; exit 1; }
    fi
fi

# SRC_HOST から user@ を除いたベースホスト名を取得
# 例: user@server1 → server1 / server1 → server1
if [[ -n "$SRC_HOST" ]]; then
    SRC_BASE_HOST="${SRC_HOST#*@}"
fi

# ------------------------------------------------------------------ #
#  rsync オプション
#  -a            アーカイブモード (権限/タイムスタンプ/オーナー/グループ/シンボリックリンクを保持)
#  -H            ハードリンクを保持
#  -A            ACL を保持
#  -X            拡張属性を保持
#  --delete           移行先にのみ存在するファイルを削除し、移行元と完全一致させる
#  --itemize-changes  変更内容を1行ずつ記号で表示 (パーミッションのみの差異も検出)
#  --checksum         タイムスタンプではなくチェックサムで差異を判断 (中身が本当に違うか確認、デフォルト有効)
#                     大量ファイル・大容量の場合は -nc で無効化してタイムスタンプ+サイズ比較に切り替え可能
# ------------------------------------------------------------------ #

RSYNC_OPTS=(-aHAX --delete -v --itemize-changes)
$USE_CHECKSUM && RSYNC_OPTS+=(--checksum)
$DRY_RUN && RSYNC_OPTS+=(--dry-run)

# ------------------------------------------------------------------ #
#  SSH 接続の使い回し (ControlMaster)
#  移行元がリモートの場合、最初の接続で SSH マスターを確立し、
#  以降の ssh/rsync コマンドはそのソケットを経由して再接続しない。
#  これによりパスワード入力が1回で済む。
#  ユーザ別パスワード使用時はユーザごとにソケットを作成する。
# ------------------------------------------------------------------ #

SSH_OPTS=()

# 全ControlMasterソケットをクリーンアップ
cleanup_ctrl() {
    for host in "${!HOST_SOCKETS[@]}"; do
        local sock="${HOST_SOCKETS[$host]}"
        ssh -o ControlPath="$sock" -o ControlMaster=no -O exit "$host" 2>/dev/null || true
        rm -f "$sock"
    done
}
trap cleanup_ctrl EXIT

# 初期 SRC_HOST が設定されている場合 (従来形式) はソケットを作成
if [[ -n "$SRC_HOST" ]]; then
    CTRL_SOCKET="$(mktemp /tmp/.rsync_migrate_XXXXXX)"; rm -f "$CTRL_SOCKET"
    HOST_SOCKETS["$SRC_HOST"]="$CTRL_SOCKET"
    SSH_OPTS=(
        -o ControlMaster=auto
        -o ControlPath="$CTRL_SOCKET"
        -o ControlPersist=60
    )
fi

# ------------------------------------------------------------------ #
#  ヘルパー関数
# ------------------------------------------------------------------ #

# ログにプレーンテキストで書き込む (ANSIカラーコードを除去)
log() { echo "$@" | sed $'s/\033\\[[0-9;]*m//g' >> "$LOG_FILE"; }

# パスワード認証が有効な場合は sshpass 経由でコマンドを実行する
ssh_cmd() {
    if $ASK_PASSWORD; then
        sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "$@"
    else
        ssh "${SSH_OPTS[@]}" "$@"
    fi
}
rsync_cmd() {
    if $ASK_PASSWORD; then
        sshpass -p "$SSH_PASS" rsync -e "ssh ${SSH_OPTS[*]}" "$@"
    else
        rsync -e "ssh ${SSH_OPTS[*]}" "$@"
    fi
}

src_exists() {
    local path="$1"
    if [[ -z "$SRC_HOST" ]]; then
        test -e "$path" 2>/dev/null
    else
        ssh_cmd "$SRC_HOST" test -e "$path" < /dev/null 2>/dev/null
    fi
}

make_dst_dir() {
    local path="$1"
    if $DRY_RUN; then
        echo -e "  [ドライラン] mkdir -p ${path}"; return 0
    fi
    mkdir -p "$path"
}

# ユーザ切り替え: @user:password 行を処理して SSH 接続情報を更新する
switch_to_user() {
    local user="$1" pass="$2"

    if [[ -z "$SRC_BASE_HOST" ]]; then
        echo -e "${RED}エラー: @user:password 形式を使う場合は -S HOST が必要です${RESET}" >&2
        exit 1
    fi

    command -v sshpass &>/dev/null || {
        echo -e "${RED}エラー: sshpass がインストールされていません (ファイル内パスワード認証に必要)${RESET}" >&2
        exit 1
    }

    local new_host="${user}@${SRC_BASE_HOST}"
    SRC_HOST="$new_host"
    SSH_PASS="$pass"
    ASK_PASSWORD=true

    # 同じ user@host のソケットを使い回す。なければ新規作成
    if [[ -z "${HOST_SOCKETS[$new_host]:-}" ]]; then
        local sock
        sock="$(mktemp /tmp/.rsync_migrate_XXXXXX)"; rm -f "$sock"
        HOST_SOCKETS["$new_host"]="$sock"
    fi
    CTRL_SOCKET="${HOST_SOCKETS[$new_host]}"
    SSH_OPTS=(
        -o ControlMaster=auto
        -o ControlPath="$CTRL_SOCKET"
        -o ControlPersist=60
    )
}

# --itemize-changes の出力1行に日本語の説明を付与する
#   フォーマット: YXcstpog... filename
#   Y: > 転送あり  . メタデータのみ  * メッセージ(削除など)
#   X: f ファイル  d ディレクトリ
#   c: c チェックサム差異  + 新規  . 差異なし
#   s: s サイズ差異
#   t: t タイムスタンプ差異
#   p: p パーミッション差異
#   o: o オーナー差異
#   g: g グループ差異
annotate_rsync_line() {
    local line="$1"

    # *deleting
    if [[ "$line" == \*deleting* ]]; then
        echo -e "  ${line}  ${CYAN}← 移行先にのみ存在 (削除対象)${RESET}"; return
    fi

    # itemize-changes 形式 (11文字 + スペース + パス) か判定
    local itemize_pat='^[>.<][fdLDS]'
    if [[ ! "$line" =~ $itemize_pat ]]; then
        echo "  $line"; return
    fi

    local update="${line:0:1}"
    local cksum="${line:2:1}"
    local size="${line:3:1}"
    local mtime="${line:4:1}"
    local perm="${line:5:1}"
    local owner="${line:6:1}"
    local group="${line:7:1}"

    local -a parts=()

    if [[ "$cksum" == "+" ]]; then
        parts+=("新規")
    else
        [[ "$cksum"  == "c" ]] && parts+=("内容差異")
        [[ "$size"   == "s" ]] && parts+=("サイズ差異")
        [[ "$mtime"  == "t" ]] && parts+=("タイムスタンプ差異")
    fi
    [[ "$perm"  == "p" ]] && parts+=("パーミッション差異")
    [[ "$owner" == "o" ]] && parts+=("オーナー差異")
    [[ "$group" == "g" ]] && parts+=("グループ差異")

    if [[ ${#parts[@]} -gt 0 ]]; then
        local desc
        desc=$(IFS='/'; echo "${parts[*]}")
        echo -e "  ${line}  ${CYAN}← ${desc}${RESET}"
    else
        echo "  $line"
    fi
}

do_rsync() {
    local src_path="$1" dst_path="$2"
    local src="${src_path%/}/"  # 末尾 / でディレクトリの中身を同期

    if [[ -z "$SRC_HOST" ]]; then
        rsync_cmd "${RSYNC_OPTS[@]}" "$src" "$dst_path" < /dev/null
    else
        rsync_cmd "${RSYNC_OPTS[@]}" "${SRC_HOST}:${src}" "$dst_path" < /dev/null
    fi | while IFS= read -r line; do
        annotate_rsync_line "$line"
        echo "    $line" >> "$LOG_FILE"
    done
    local rc="${PIPESTATUS[0]}"
    return "$rc"
}

# ------------------------------------------------------------------ #
#  起動サマリー
# ------------------------------------------------------------------ #

echo -e "${BOLD}${CYAN}=== rsync 移行ツール ===${RESET}"
echo -e "リストファイル : ${LIST_FILE}"
echo -e "移行元サーバ   : ${SRC_BASE_HOST:-ローカル}"
[[ -n "$SRC_HOST" ]] && {
    $ASK_PASSWORD && echo -e "SSH認証        : パスワード認証 (-W)" \
                  || echo -e "SSH認証        : 鍵認証 (またはファイル内パスワード)"
}
echo -e "移行先         : ローカル (このサーバ)"
if $DRY_RUN; then
    echo -e "${YELLOW}モード         : ドライラン (実際のファイル操作は行いません)${RESET}"
else
    echo -e "モード         : ${GREEN}本番実行 (ドライラン確認 → y/n → 同期)${RESET}"
fi
$USE_CHECKSUM \
    && echo -e "チェックサム   : 有効 (遅い場合は -nc で無効化)" \
    || echo -e "チェックサム   : ${YELLOW}無効 (タイムスタンプ+サイズ比較)${RESET}"
echo -e "ログ出力先     : ${LOG_FILE}"
echo ""

# ログにヘッダーを記録
{
    echo "========================================"
    echo " rsync 移行ログ"
    echo " 開始: $(date '+%Y-%m-%d %H:%M:%S')"
    echo " リスト: ${LIST_FILE}"
    echo " 移行元サーバ: ${SRC_BASE_HOST:-ローカル}"
    echo "========================================"
} >> "$LOG_FILE"

# ------------------------------------------------------------------ #
#  メイン処理ループ
# ------------------------------------------------------------------ #

run_loop() {
    local total=0 skipped=0 success=0 failed=0
    local line_num=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))

        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]]           && continue

        # @user:password 行 — ユーザ切り替え
        if [[ "$line" =~ ^@ ]]; then
            if [[ "$line" =~ ^@([^:[:space:]]+):(.+)$ ]]; then
                local new_user="${BASH_REMATCH[1]}"
                local new_pass="${BASH_REMATCH[2]}"
                switch_to_user "$new_user" "$new_pass"
                echo -e "${BOLD}--- ユーザ切り替え: ${SRC_HOST} ---${RESET}"
                log ""
                log "--- ユーザ切り替え: ${SRC_HOST} ---"
            else
                echo -e "${YELLOW}警告 [行 ${line_num}]: @user:password の書式が不正です (スキップ): ${line}${RESET}" >&2
            fi
            continue
        fi

        read -r src dst extra <<< "$line"

        if [[ -z "$src" ]]; then
            echo -e "${YELLOW}警告 [行 ${line_num}]: 書式が不正です (スキップ): ${line}${RESET}" >&2
            skipped=$((skipped + 1)); continue
        fi
        [[ -z "$dst" ]] && dst="$src"
        [[ -n "${extra:-}" ]] && echo -e "${YELLOW}警告 [行 ${line_num}]: 3列目以降は無視します: ${extra}${RESET}" >&2

        total=$((total + 1))
        local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
        local mode; $DRY_RUN && mode="DRY-RUN" || mode="EXECUTE"

        echo -e "${BOLD}------------------------------------------------------------${RESET}"
        echo -e "${BOLD}[${total}] 移行元:${RESET} ${SRC_HOST:-ローカル}:${src}"
        echo -e "${BOLD}    移行先:${RESET} ローカル:${dst}"
        log ""
        log "------------------------------------------------------------"
        log "[${total}] ${ts} [${mode}]"
        log "  移行元: ${SRC_HOST:-ローカル}:${src}"
        log "  移行先: ローカル:${dst}"

        if ! src_exists "$src"; then
            echo -e "${RED}  エラー: 移行元が存在しません${RESET}" >&2
            log "  結果: エラー (移行元が存在しません)"
            failed=$((failed + 1)); continue
        fi

        if [[ ! -d "$dst" ]]; then
            echo -e "  移行先ディレクトリを作成: ${dst}"
            make_dst_dir "$dst"
        fi

        echo -e "  ${GREEN}rsync 実行中...${RESET}"
        log "  rsync 出力:"
        local rc=0
        do_rsync "$src" "$dst" || rc=$?
        if [[ $rc -eq 0 ]]; then
            echo -e "  ${GREEN}完了${RESET}"
            log "  結果: 完了 ($(date '+%Y-%m-%d %H:%M:%S'))"
            success=$((success + 1))
        else
            echo -e "  ${RED}失敗 (rsync 終了コード: ${rc})${RESET}" >&2
            log "  結果: 失敗 (code=${rc}, $(date '+%Y-%m-%d %H:%M:%S'))"
            failed=$((failed + 1))
        fi

    done < "$LIST_FILE"

    echo ""
    echo -e "${BOLD}=== 結果サマリー ===${RESET}"
    echo -e "  成功:     ${GREEN}${success}${RESET}"
    echo -e "  スキップ: ${YELLOW}${skipped}${RESET}"
    echo -e "  失敗:     ${RED}${failed}${RESET}"
    {
        echo ""
        echo "========================================"
        echo " 結果サマリー ($(date '+%Y-%m-%d %H:%M:%S'))"
        echo "  成功:     ${success}"
        echo "  スキップ: ${skipped}"
        echo "  失敗:     ${failed}"
        echo "========================================"
    } >> "$LOG_FILE"

    [[ $failed -gt 0 ]] && return 1
    return 0
}

# ------------------------------------------------------------------ #
#  実行
# ------------------------------------------------------------------ #

if $DRY_RUN; then
    # デフォルト: ドライランのみ
    run_loop
else
    # -e 指定時: まずドライランで差異を表示し、確認後に本番実行
    echo -e "${YELLOW}--- ドライラン (差異確認) ---${RESET}"
    DRY_RUN=true
    RSYNC_OPTS+=( --dry-run)
    run_loop || true

    echo ""
    while true; do
        echo -en "${CYAN}以上の内容で同期を実行しますか？ [y/n]: ${RESET}"
        read -r answer </dev/tty
        case "${answer,,}" in
            y|yes) break ;;
            n|no)  echo -e "${YELLOW}中断しました${RESET}"; exit 0 ;;
            *)     echo -e "  ${RED}y または n を入力してください${RESET}" ;;
        esac
    done

    echo ""
    echo -e "${GREEN}--- 本番実行 ---${RESET}"
    DRY_RUN=false
    RSYNC_OPTS=(-aHAX --delete -v --itemize-changes)
    $USE_CHECKSUM && RSYNC_OPTS+=(--checksum)
    run_loop
fi

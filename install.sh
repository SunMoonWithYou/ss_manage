#!/usr/bin/env bash

###############################################################################
# Shadowsocks-Rust 多用户管理脚本
#
# 【功能概览】
#   - 多用户、多端口 Shadowsocks-Rust 管理
#   - 每用户：流量限额（limit）+ 周期数（periods，每个 30 天）
#   - created_at 永久固定；expire 独立存储
#   - 每周期边界：used 清零；若因流量超限被禁则自动恢复
#   - 到期：永久禁用（expired），reset 不恢复，需 renew 续费
#   - reset：只清本周期 used，不改套餐
#   - renew：从 max(now, expire) 起增加周期
#   - 流量统计：iptables 计数器 + users.json 持久化（重启不丢 used）
#   - 同步 Cloudflare Worker：POST 上传，查询页 GET ?key=xxx
#   - Worker 同步频率：最多每小时一次（流量检查仍按 CRON_INTERVAL）
#   - Worker 可不配置：未填 URL/TOKEN 时所有同步调用直接跳过，核心功能不受影响
#   - 支持删除 Worker 同步（菜单 11 / ss-manager unsync）：可先清云端再删本地配置
#   - 日志：manager.log + journal 均保留约 7 天，防止无限增长
#
# 【并发安全】
#   - 所有会改写 users.json 的操作（含交互菜单与 cron）统一持有 fd 排它锁，
#     覆盖整个「读-改-写」事务，避免 cron 与人工操作互相覆盖
#   - 写入一律「先写同目录临时文件 → fsync 前 rename」，不会留下半截 JSON
#
# 【兼容】
#   旧 users.json 自动补全：periods / last_cycle_index / last_ipt_* /
#   used_total / key
#
# 【可测试性】
#   以下环境变量可覆盖路径，便于在非 root 环境干跑：
#     SS_DATA_DIR / SS_SYSTEMD_DIR / SS_CRON_FILE / SS_LOGROTATE_CONF
#     SS_JOURNALD_CONF_DIR / SS_LOCK_FILE / SS_CRON_INTERVAL
###############################################################################

set -u
set -o pipefail

# 统一 locale，避免排序/数字格式问题
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=en_US.UTF-8 2>/dev/null || true

###############################################################################
# 域名与 Worker 配置（按需修改这 3 行）
###############################################################################

# ss:// 节点域名（客户端连接用，代替服务器 IP）
SS_NODE_DOMAIN="akile-hinet-ch76eg.645781.xyz"

# 上传接口：脚本 POST 用户流量/状态数据到此 URL
WORKER_API_URL="https://ss.real-mrtang.workers.dev/sync"

# 查询接口：用户浏览器访问 ${WORKER_QUERY_DOMAIN}/?key=xxx 查看剩余流量
WORKER_QUERY_DOMAIN="https://ss.yx1314.ccwu.cc"

###############################################################################
# 路径与基础常量
###############################################################################

APP_NAME="ss-manager"
MANAGER_PATH="/usr/local/bin/ss-manager"          # 安装后的管理命令路径
CONFIG_DIR="/etc/shadowsocks-rust"                # 配置与数据目录
DATA_DIR="${SS_DATA_DIR:-${CONFIG_DIR}}"          # 数据目录（可用 SS_DATA_DIR 覆盖，便于本地测试）
USERS_FILE="${DATA_DIR}/users.json"               # 用户数据（含流量、到期等）
SS_CONFIG="${DATA_DIR}/config.json"               # ssserver 运行配置
LOG_FILE="${DATA_DIR}/manager.log"                # cron 流量检查日志
SERVICE_NAME="shadowsocks-rust"
SYSTEMD_DIR="${SS_SYSTEMD_DIR:-/etc/systemd/system}"                 # service 输出目录
SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"
BIN_PATH="/usr/local/bin/ssserver"                # ssserver 二进制

RESET_DAYS=30                                     # 一个周期天数
RESET_SECONDS=$((RESET_DAYS * 86400))             # 一个周期秒数
DEFAULT_METHOD="aes-256-gcm"                      # 默认加密
GITHUB_API="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
CRON_FILE="${SS_CRON_FILE:-/etc/cron.d/ss-manager}"   # 流量检查定时任务
CRON_INTERVAL="${SS_CRON_INTERVAL:-5}"            # 检查间隔（分钟），需为 1..59 或 60 的约数
LOGROTATE_CONF="${SS_LOGROTATE_CONF:-/etc/logrotate.d/ss-manager}"
JOURNALD_CONF_DIR="${SS_JOURNALD_CONF_DIR:-/etc/systemd/journald.conf.d}"
DEFAULT_PORT=8388                                 # 新用户建议起始端口
LOCK_FILE="${SS_LOCK_FILE:-/var/lock/ss-manager.lock}"   # cron 防重入锁
LOCK_FD_DIR="${DATA_DIR}/.locks"                  # 细粒度锁目录（所有修改 users.json 的操作）
LAST_SYNC_FILE="${DATA_DIR}/last_worker_sync"     # 上次 Worker 同步时间戳
WORKER_SYNC_INTERVAL=3600                         # Worker 同步最小间隔（秒），默认 1 小时

# Worker 运行时配置（可被 worker.conf 覆盖；TOKEN 建议只放在 conf 里）
WORKER_CONF="${DATA_DIR}/worker.conf"
WORKER_URL="${WORKER_API_URL}"
WORKER_TOKEN=""
WORKER_QUERY_BASE="${WORKER_QUERY_DOMAIN}"
[[ -f "${WORKER_CONF}" ]] && source "${WORKER_CONF}"
[[ -z "${WORKER_URL}" ]]        && WORKER_URL="${WORKER_API_URL}"
[[ -z "${WORKER_QUERY_BASE}" ]] && WORKER_QUERY_BASE="${WORKER_QUERY_DOMAIN}"

###############################################################################
# 终端颜色与输出辅助
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()  { echo -e "${BLUE}[信息]${RESET} $*"; }
ok()    { echo -e "${GREEN}[成功]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[警告]${RESET} $*"; }
err()   { echo -e "${RED}[错误]${RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

line() {
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${RESET}"
}

title() {
    echo
    echo -e "${CYAN}${BOLD}$*${RESET}"
    line
}

###############################################################################
# 显示宽度（中英文对齐用，依赖 python3）
###############################################################################

display_width() {
    local str="$1" w
    if [[ "${str}" != *[![:ascii:]]* ]]; then
        # 纯 ASCII：直接取字节数，省掉一次 python3 启动
        echo "${#str}"
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import sys, unicodedata
s = sys.argv[1]
w = 0
for ch in s:
    if unicodedata.east_asian_width(ch) in ("F", "W"):
        w += 2
    else:
        w += 1
print(w)
' "${str}"
        return
    fi
    # 无 python3 时的兜底：按 UTF-8 字节数估算，
    # 3 字节（CJK）算 2 列，2 字节（拉丁扩展等）算 1 列，1 字节算 1 列
    w="$(printf '%s' "${str}" | LC_ALL=C awk '
        {
            n = 0; i = 1
            while (i <= length($0)) {
                c = substr($0, i, 1)
                o = index("", c)
                if (o > 0) { n += 2; i += 3 }
                else { n += 1; i += 1 }
            }
            print n
        }
    ' 2>/dev/null || echo "${#str}")"
    [[ "${w}" =~ ^[0-9]+$ ]] || w="${#str}"
    echo "${w}"
}

pad_right() {
    local str="$1" target="$2" w pad
    w="$(display_width "${str}")"
    pad=$(( target - w ))
    (( pad < 0 )) && pad=0
    printf '%s' "${str}"
    printf '%*s' "${pad}" ''
}

pad_left() {
    local str="$1" target="$2" w pad
    w="$(display_width "${str}")"
    pad=$(( target - w ))
    (( pad < 0 )) && pad=0
    printf '%*s' "${pad}" ''
    printf '%s' "${str}"
}

# 必须 root 运行（iptables / systemd / 写 /etc）
check_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行此脚本。"
}

###############################################################################
# 时间工具
###############################################################################

now_ts() { date +%s; }

format_ts() {
    local ts="${1:-0}"
    if [[ "${ts}" =~ ^[0-9]+$ ]] && (( ts > 0 )); then
        date -d "@${ts}" '+%Y-%m-%d %H:%M:%S'
    else
        echo "-"
    fi
}

# 距离目标时间的剩余可读描述
remaining_time() {
    local target="$1" now diff days hours minutes
    now="$(now_ts)"
    diff=$((target - now))
    if (( diff <= 0 )); then echo "已到期"; return; fi
    days=$((diff / 86400)); diff=$((diff % 86400))
    hours=$((diff / 3600)); diff=$((diff % 3600))
    minutes=$((diff / 60))
    if (( days > 0 )); then echo "${days}天${hours}小时"
    elif (( hours > 0 )); then echo "${hours}小时${minutes}分钟"
    else echo "${minutes}分钟"; fi
}

# 统一的用户显示状态：即使 cron 尚未把 disabled_reason 写为 expired，
# 只要 expire 已过，显示状态一律为「已到期」
user_display_status() {
    local enabled="$1" reason="$2" expire="$3"
    local now
    now="$(now_ts)"
    if [[ "${expire}" =~ ^[0-9]+$ ]] && (( expire > 0 && now >= expire )); then
        echo "已到期"
        return
    fi
    if [[ "${enabled}" == "true" ]]; then echo "正常"
    elif [[ "${reason}" == "traffic" ]]; then echo "流量超限"
    elif [[ "${reason}" == "expired" ]]; then echo "已到期"
    else echo "已禁用"; fi
}

###############################################################################
# 字节格式化 / 流量解析
###############################################################################

bytes_to_human() {
    local bytes="${1:-0}"
    [[ "${bytes}" =~ ^[0-9]+$ ]] || bytes=0
    if (( bytes < 1024 )); then echo "${bytes} B"
    elif (( bytes < 1048576 )); then awk -v b="${bytes}" 'BEGIN{printf "%.2f KB", b/1024}'
    elif (( bytes < 1073741824 )); then awk -v b="${bytes}" 'BEGIN{printf "%.2f MB", b/1048576}'
    elif (( bytes < 1099511627776 )); then awk -v b="${bytes}" 'BEGIN{printf "%.2f GB", b/1073741824}'
    else awk -v b="${bytes}" 'BEGIN{printf "%.2f TB", b/1099511627776}'; fi
}

# 解析 "100G" / "1.5T" / "512M" 等为字节数；0 或空表示不限
parse_limit() {
    local input number unit
    input="$(echo "${1:-0}" | tr '[:lower:]' '[:upper:]')"
    [[ "${input}" == "0" || -z "${input}" ]] && { echo 0; return; }
    if [[ "${input}" =~ ^([0-9]+([.][0-9]+)?)([KMGT]?)B?$ ]]; then
        number="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]}"
        case "${unit}" in
            "") awk -v n="${number}" 'BEGIN{printf "%.0f", n}' ;;
            K)  awk -v n="${number}" 'BEGIN{printf "%.0f", n*1024}' ;;
            M)  awk -v n="${number}" 'BEGIN{printf "%.0f", n*1024*1024}' ;;
            G)  awk -v n="${number}" 'BEGIN{printf "%.0f", n*1024*1024*1024}' ;;
            T)  awk -v n="${number}" 'BEGIN{printf "%.0f", n*1024*1024*1024*1024}' ;;
            *)  echo 0 ;;
        esac
    else
        echo 0
    fi
}

random_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
    echo
}

# 用户查询 key：u_ + 32 位 hex（用于 Worker 查询页）
random_key() {
    local hex
    if command -v openssl >/dev/null 2>&1; then
        hex="$(openssl rand -hex 16)"
    else
        hex="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    echo "u_${hex}"
}

###############################################################################
# 目录与自安装
###############################################################################

init_dirs() {
    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"
    if [[ ! -f "${USERS_FILE}" ]]; then
        echo '[]' > "${USERS_FILE}"
        chmod 600 "${USERS_FILE}"
    fi
    touch "${LOG_FILE}"
    chmod 600 "${LOG_FILE}"
}

# 将当前脚本复制到 /usr/local/bin/ss-manager，便于 cron 与命令行调用
install_self() {
    local current_script=""
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        current_script="${BASH_SOURCE[0]}"
    fi
    if [[ -n "${current_script}" && -f "${current_script}" ]]; then
        if [[ "$(readlink -f "${current_script}")" != "$(readlink -f "${MANAGER_PATH}" 2>/dev/null || true)" ]]; then
            cp -f "${current_script}" "${MANAGER_PATH}"
            chmod 755 "${MANAGER_PATH}"
            ok "管理脚本已安装：${MANAGER_PATH}"
        fi
    fi
}

###############################################################################
# 依赖
###############################################################################

install_dependencies() {
    local need_install=()
    command -v curl >/dev/null 2>&1 || need_install+=("curl")
    command -v jq >/dev/null 2>&1 || need_install+=("jq")
    command -v iptables >/dev/null 2>&1 || need_install+=("iptables")
    command -v tar >/dev/null 2>&1 || need_install+=("tar")
    command -v xz >/dev/null 2>&1 || need_install+=("xz-utils")
    command -v base64 >/dev/null 2>&1 || need_install+=("coreutils")
    (( ${#need_install[@]} == 0 )) && return
    info "正在安装依赖：${need_install[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${need_install[@]}"
}

check_dependencies() {
    local cmds=(curl jq iptables tar xz base64 systemctl awk sed grep)
    local c
    for c in "${cmds[@]}"; do
        command -v "${c}" >/dev/null 2>&1 || die "缺少依赖：${c}"
    done
}

###############################################################################
# 安装 / 更新 Shadowsocks-Rust
###############################################################################

get_latest_version() {
    local v
    v="$(curl -fsSL --connect-timeout 10 --max-time 30 "${GITHUB_API}" 2>/dev/null | jq -r '.tag_name // empty')"
    [[ -z "${v}" ]] && return 1
    echo "${v}"
}

get_target_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) return 1 ;;
    esac
}

install_shadowsocks() {
    local version arch tmp_dir archive url extracted_bin
    info "正在获取 Shadowsocks-Rust 最新版本..."
    version="$(get_latest_version)" || die "无法获取 Shadowsocks-Rust 最新版本。"
    arch="$(get_target_arch)" || die "暂不支持当前 CPU 架构：$(uname -m)"
    info "最新版本：${version}"
    info "系统架构：${arch}"
    tmp_dir="$(mktemp -d)"
    archive="${tmp_dir}/shadowsocks-rust.tar.xz"
    url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${version}/shadowsocks-v${version#v}.${arch}-unknown-linux-gnu.tar.xz"
    info "下载：${url}"
    if ! curl -fL --connect-timeout 15 --max-time 300 --retry 3 -o "${archive}" "${url}"; then
        rm -rf "${tmp_dir}"
        die "Shadowsocks-Rust 下载失败。"
    fi
    info "正在解压..."
    tar -xJf "${archive}" -C "${tmp_dir}"
    extracted_bin="$(find "${tmp_dir}" -type f -name 'ssserver' | head -n 1)"
    if [[ -z "${extracted_bin}" || ! -f "${extracted_bin}" ]]; then
        rm -rf "${tmp_dir}"
        die "下载包中没有找到 ssserver。"
    fi
    chmod 755 "${extracted_bin}"
    [[ -f "${BIN_PATH}" ]] && cp -f "${BIN_PATH}" "${BIN_PATH}.bak"
    cp -f "${extracted_bin}" "${BIN_PATH}"
    chmod 755 "${BIN_PATH}"
    rm -rf "${tmp_dir}"
    if ! "${BIN_PATH}" --version >/dev/null 2>&1; then
        [[ -f "${BIN_PATH}.bak" ]] && mv -f "${BIN_PATH}.bak" "${BIN_PATH}"
        die "Shadowsocks-Rust 安装验证失败。"
    fi
    rm -f "${BIN_PATH}.bak"
    ok "Shadowsocks-Rust 安装完成。"
    "${BIN_PATH}" --version || true
}

###############################################################################
# 用户数据读写
###############################################################################

get_user_count() { jq 'length' "${USERS_FILE}" 2>/dev/null || echo 0; }
has_users() { [[ "$(get_user_count)" -gt 0 ]]; }
has_enabled_users() {
    jq -e 'any(.[]; (.enabled // true) == true)' "${USERS_FILE}" >/dev/null 2>&1
}

###############################################################################
# 并发控制：所有会改写 users.json 的操作串行化
#
# cron 每 5 分钟跑 traffic-check，与交互式增删改可能同时发生。
# 旧版仅用 flock 保护 cron 自身，人工操作不受保护 → 存在写丢失。
# 这里用 fd 锁，作用域覆盖整个「读-改-写」事务。
###############################################################################

LOCK_FD=200

acquire_users_lock() {
    mkdir -p "${LOCK_FD_DIR}" 2>/dev/null || true
    chmod 700 "${LOCK_FD_DIR}" 2>/dev/null || true
    if ! eval "exec ${LOCK_FD}>\"${LOCK_FD_DIR}/users.lock\"" 2>/dev/null; then
        # 极端情况下（目录不可写）退化为不加锁，保证功能可用
        return 0
    fi
    if ! flock -w "${1:-30}" "${LOCK_FD}" 2>/dev/null; then
        err "获取数据锁超时，可能有其他 ss-manager 进程正在运行。"
        eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
        return 1
    fi
    return 0
}

release_users_lock() {
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
}

# 原子写：临时文件放在同一目录，避免跨文件系统 mv 丢失原子性
atomic_write_users() {
    local tmp
    tmp="$(mktemp "${DATA_DIR}/.users.json.XXXXXX")" || return 1
    if ! jq "${1:-.}" "${USERS_FILE}" > "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        return 1
    fi
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${USERS_FILE}"
}

save_users() {
    atomic_write_users '.' || die "保存 users.json 失败。"
}

# jq 必须先校验再落盘，避免半截文件覆盖正式数据
save_users_filter() {
    atomic_write_users "$1" || die "保存 users.json 失败。"
}

# 按用户名更新 JSON 字段；expr 为 jq 表达式片段，如 '.used = 0 | .enabled = true'
# 用户名通过 jq --arg 传入，避免名字里含引号/反斜杠时破坏表达式
update_user_field_json() {
    local name="$1" expr="$2"
    atomic_write_users_arg "${name}" "${expr}"
}

atomic_write_users_arg() {
    local name="$1" expr="$2" tmp
    tmp="$(mktemp "${DATA_DIR}/.users.json.XXXXXX")" || return 1
    if ! jq --arg n "${name}" "map(if .name == \$n then ${expr} else . end)" \
        "${USERS_FILE}" > "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        return 1
    fi
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${USERS_FILE}"
}

# 一次读出用户关键字段，供 check_user 复用（避免每字段一次 jq）
# 注意：不能用 @tsv —— jq 的 @tsv 会压缩空字符串，导致 disabled_reason 为空时
# 后续列整体左移，读取错位。这里改用不会丢空字段的 join("\u001f")。
REC_SEP=$'\x1f'

# 输出：port created_at expire limit used used_total enabled reason last_cycle_index last_ipt_tcp last_ipt_udp key
get_user_fields() {
    jq -r --arg n "$1" '
        .[] | select(.name == $n) |
        [
            (.port // 0),
            (.created_at // 0),
            (.expire // 0),
            (.limit // 0),
            (.used // 0),
            (.used_total // 0),
            (if (.enabled // true) then "true" else "false" end),
            (.disabled_reason // ""),
            (.last_cycle_index // 0),
            (.last_ipt_tcp // 0),
            (.last_ipt_udp // 0),
            (.key // "")
        ] | map(if . == null then "" else tostring end) | join("\u001f")
    ' "${USERS_FILE}" | head -n 1
}

###############################################################################
# 迁移：补全旧版 users.json 字段
###############################################################################

migrate_users() {
    local tmp
    [[ -f "${USERS_FILE}" ]] || echo '[]' > "${USERS_FILE}"
    if ! jq empty "${USERS_FILE}" >/dev/null 2>&1; then
        warn "users.json 数据异常，正在重新初始化。"
        echo '[]' > "${USERS_FILE}"
        return
    fi

    tmp="$(mktemp)"

    # 补默认值；periods 由 expire/created_at 估算；last_cycle_index 由当前时间推算
    jq '
        map(
            .created_at = (.created_at // now | floor) |
            .used = (.used // 0) |
            .limit = (.limit // 0) |
            .expire = (.expire // 0) |
            .enabled = (.enabled // true) |
            .disabled_reason = (.disabled_reason // "") |
            .method = (.method // "aes-256-gcm") |

            .periods = (.periods // (
                if (.expire // 0) > 0 and (.created_at // 0) > 0
                then ([((.expire - .created_at) / 2592000) | floor, 1] | max)
                else 1
                end
            )) |

            .last_cycle_index = (.last_cycle_index // (
                if (.created_at // 0) > 0
                then (((now - .created_at) / 2592000) | floor)
                else 0
                end
            )) |

            .last_ipt_tcp = (.last_ipt_tcp // 0) |
            .last_ipt_udp = (.last_ipt_udp // 0) |
            .used_total = (.used_total // .used // 0) |

            .next_reset = (.next_reset // 0) |
            .last_reset = (.last_reset // 0) |

            .key = (.key // "")
        )
    ' "${USERS_FILE}" > "${tmp}" || { rm -f "${tmp}"; warn "migrate_users jq 失败。"; return; }

    mv -f "${tmp}" "${USERS_FILE}"
    chmod 600 "${USERS_FILE}"
}

# 保证每个用户都有 u_ 开头的查询 key
# 先一次 jq 找出缺失/格式不符的用户名，再逐个补 key（通常 0 个，无需循环）
migrate_user_keys() {
    local u missing need_save=0
    missing="$(jq -r '.[] | select(((.key // "") | startswith("u_")) | not) | .name' "${USERS_FILE}" 2>/dev/null)"
    [[ -z "${missing}" ]] && return 0

    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        local new_key
        new_key="$(random_key)"
        update_user_field_json "${u}" ".key = \"${new_key}\""
        need_save=1
        info "用户 ${u} 生成新 key：${new_key}"
    done <<<"${missing}"

    (( need_save == 1 )) && save_users
    return 0
}

###############################################################################
# 周期计算
###############################################################################

# 计算下一次“自然周期边界”时间戳（基于 created_at 对齐）
calculate_next_reset() {
    local created_at="$1" current="$2" next
    if (( created_at <= 0 )); then
        echo $((current + RESET_SECONDS))
        return
    fi
    next=$((created_at + RESET_SECONDS))
    while (( next <= current )); do
        next=$((next + RESET_SECONDS))
    done
    echo "${next}"
}

# 当前处于第几个 30 天周期（从 0 起）
current_cycle_index() {
    local created_at="$1" now="$2"
    if (( created_at <= 0 )); then
        echo 0
        return
    fi
    echo $(( (now - created_at) / RESET_SECONDS ))
}

###############################################################################
# 公网 IPv4（备用，当前主要用 SS_NODE_DOMAIN）
###############################################################################

get_public_ipv4() {
    local ip=""
    ip="$(curl -4 -fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "${ip}"; return 0; }
    ip="$(curl -4 -fsSL --connect-timeout 5 --max-time 10 https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]')"
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "${ip}"; return 0; }
    ip="$(curl -4 -fsSL --connect-timeout 5 --max-time 10 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')"
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "${ip}"; return 0; }
    return 1
}

###############################################################################
# URL 编码 / SS 链接生成
###############################################################################

url_encode() {
    local value="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "${value}" | jq -sRr @uri
    else
        printf '%s' "${value}"
    fi
}

generate_ss_link() {
    local port="$1" password="$2" method="$3" name="$4" server="${5:-}"
    [[ -z "${server}" ]] && server="${SS_NODE_DOMAIN}"
    [[ -z "${server}" ]] && return 1
    local userinfo="${method}:${password}"
    local encoded
    encoded="$(printf '%s' "${userinfo}" | base64 -w 0 | tr '+/' '-_' | tr -d '=')"
    local tag
    tag="$(url_encode "${name}")"
    echo "ss://${encoded}@${server}:${port}#${tag}"
}

###############################################################################
# iptables：按端口统计流量 + 阻断
#
# 说明：
#   - 计数器在内存中，重启后归零；used 写在 users.json，重启不丢
#   - 当 cur < last 时视为计数器重置，只取当前增量（通常为 0）
###############################################################################

in_chain()  { echo "ss-${1}-in"; }
out_chain() { echo "ss-${1}-out"; }

remove_traffic_rules() {
    local port="$1"
    local in_name out_name
    in_name="$(in_chain "${port}")"
    out_name="$(out_chain "${port}")"

    iptables -D INPUT  -p tcp --dport "${port}" -j "${in_name}"  2>/dev/null || true
    iptables -D INPUT  -p udp --dport "${port}" -j "${in_name}"  2>/dev/null || true
    iptables -D OUTPUT -p tcp --sport "${port}" -j "${out_name}" 2>/dev/null || true
    iptables -D OUTPUT -p udp --sport "${port}" -j "${out_name}" 2>/dev/null || true

    iptables -F "${in_name}"  2>/dev/null || true
    iptables -F "${out_name}" 2>/dev/null || true
    iptables -X "${in_name}"  2>/dev/null || true
    iptables -X "${out_name}" 2>/dev/null || true
}

remove_port_rules() {
    local port="$1"
    remove_traffic_rules "${port}"
    iptables -D INPUT  -p tcp --dport "${port}" -j DROP 2>/dev/null || true
    iptables -D INPUT  -p udp --dport "${port}" -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p tcp --sport "${port}" -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p udp --sport "${port}" -j DROP 2>/dev/null || true
}

add_traffic_rules() {
    local port="$1"
    local in_name out_name
    in_name="$(in_chain "${port}")"
    out_name="$(out_chain "${port}")"

    remove_traffic_rules "${port}"

    iptables -N "${in_name}"
    iptables -N "${out_name}"

    iptables -A INPUT  -p tcp --dport "${port}" -j "${in_name}"
    iptables -A INPUT  -p udp --dport "${port}" -j "${in_name}"
    iptables -A OUTPUT -p tcp --sport "${port}" -j "${out_name}"
    iptables -A OUTPUT -p udp --sport "${port}" -j "${out_name}"

    iptables -A "${in_name}"  -j ACCEPT
    iptables -A "${out_name}" -j ACCEPT
}

add_block_rules() {
    local port="$1"
    remove_traffic_rules "${port}"
    iptables -D INPUT  -p tcp --dport "${port}" -j DROP 2>/dev/null || true
    iptables -D INPUT  -p udp --dport "${port}" -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p tcp --sport "${port}" -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p udp --sport "${port}" -j DROP 2>/dev/null || true

    iptables -I INPUT  1 -p tcp --dport "${port}" -j DROP
    iptables -I INPUT  1 -p udp --dport "${port}" -j DROP
    iptables -I OUTPUT 1 -p tcp --sport "${port}" -j DROP
    iptables -I OUTPUT 1 -p udp --sport "${port}" -j DROP
}

read_chain_bytes() {
    local chain="$1"
    local bytes=0
    if iptables -L "${chain}" -n -v -x >/dev/null 2>&1; then
        bytes="$(iptables -L "${chain}" -n -v -x 2>/dev/null \
            | awk 'NR > 2 && $1 ~ /^[0-9]+$/ {sum += $2} END {print sum+0}')"
    fi
    [[ "${bytes}" =~ ^[0-9]+$ ]] || bytes=0
    echo "${bytes}"
}

get_port_traffic() {
    local port="$1"
    local in_name out_name in_bytes out_bytes
    in_name="$(in_chain "${port}")"
    out_name="$(out_chain "${port}")"
    in_bytes="$(read_chain_bytes "${in_name}")"
    out_bytes="$(read_chain_bytes "${out_name}")"
    echo $((in_bytes + out_bytes))
}

###############################################################################
# 单用户检查：过期 / 周期推进 / 流量累加 / 超限阻断
###############################################################################

check_user() {
    local u="$1"
    local port="" created_at="" expire="" limit="" used="" used_total=""
    local enabled="" reason="" last_cycle_index="" last_ipt_tcp="" last_ipt_udp="" key=""
    local now idx cur_tcp cur_udp d_tcp d_udp

    # 一次 jq 读出全部字段（旧版 8+ 次 fork，用户多时是主要开销）
    IFS="${REC_SEP}" read -r port created_at expire limit used used_total \
        enabled reason last_cycle_index last_ipt_tcp last_ipt_udp key \
        <<<"$(get_user_fields "${u}")"

    [[ -z "${port}" ]] && return 0

    [[ "${created_at}" =~ ^[0-9]+$ ]] || created_at=0
    [[ "${expire}" =~ ^[0-9]+$ ]] || expire=0
    [[ "${limit}" =~ ^[0-9]+$ ]] || limit=0
    [[ "${used}" =~ ^[0-9]+$ ]] || used=0
    [[ "${used_total}" =~ ^[0-9]+$ ]] || used_total=0
    [[ "${last_cycle_index}" =~ ^[0-9]+$ ]] || last_cycle_index=0
    [[ "${last_ipt_tcp}" =~ ^[0-9]+$ ]] || last_ipt_tcp=0
    [[ "${last_ipt_udp}" =~ ^[0-9]+$ ]] || last_ipt_udp=0
    [[ "${enabled}" == "true" ]] || enabled=false

    now="$(now_ts)"

    # 1) 账号到期 → 永久禁用，reset 无法恢复
    if (( expire > 0 && now >= expire )); then
        if [[ "${enabled}" == "true" || "${reason}" != "expired" ]]; then
            remove_port_rules "${port}"
            add_block_rules "${port}"
            update_user_field_json "${u}" '.enabled = false | .disabled_reason = "expired"'
        fi
        return 0
    fi

    # 2) 跨周期：used 清零；若此前因流量超限被禁则恢复
    idx="$(current_cycle_index "${created_at}" "${now}")"
    if (( idx > last_cycle_index )); then
        used=0
        # 计数器逻辑依赖 iptables 真实值，周期翻转时规则会被重建，届时归零
        last_ipt_tcp=0
        last_ipt_udp=0
        last_cycle_index="${idx}"

        if [[ "${reason}" == "traffic" ]]; then
            remove_port_rules "${port}"
            add_traffic_rules "${port}"
            enabled=true
            reason=""
        fi
    fi

    # 3) 从 iptables 读增量（处理重启后计数器归零）
    cur_tcp="$(read_chain_bytes "$(in_chain "${port}")")"
    cur_udp="$(read_chain_bytes "$(out_chain "${port}")")"

    # iptables 不可用（容器/未加载模块）时返回空，此时不做累加，避免流量被清零
    if [[ -z "${cur_tcp}" || -z "${cur_udp}" ]]; then
        cur_tcp="${last_ipt_tcp}"
        cur_udp="${last_ipt_udp}"
        d_tcp=0
        d_udp=0
    else
        if (( cur_tcp >= last_ipt_tcp )); then
            d_tcp=$(( cur_tcp - last_ipt_tcp ))
        else
            d_tcp=${cur_tcp}   # 计数器被重置
        fi
        if (( cur_udp >= last_ipt_udp )); then
            d_udp=$(( cur_udp - last_ipt_udp ))
        else
            d_udp=${cur_udp}
        fi
    fi

    used=$(( used + d_tcp + d_udp ))
    used_total=$(( used_total + d_tcp + d_udp ))
    last_ipt_tcp="${cur_tcp}"
    last_ipt_udp="${cur_udp}"

    # 4) 本周期超限 → 阻断，标记 traffic（下周期可自动恢复）
    if [[ "${enabled}" == "true" && "${reason}" == "" ]] && (( limit > 0 )) && (( used >= limit )); then
        remove_port_rules "${port}"
        add_block_rules "${port}"
        enabled=false
        reason="traffic"
        warn "用户 ${u} 流量已超限：$(bytes_to_human "${used}") / $(bytes_to_human "${limit}")"
    fi

    # 5) 写回 users.json
    update_user_field_json "${u}" \
        ".used = ${used} | .used_total = ${used_total} | .last_ipt_tcp = ${last_ipt_tcp} | .last_ipt_udp = ${last_ipt_udp} | .last_cycle_index = ${last_cycle_index} | .enabled = ${enabled} | .disabled_reason = \"${reason}\""
}

# 按 users.json 状态重建所有端口的统计/阻断规则（重启后建议执行）
# 一次性读出 port/enabled/reason，避免每个用户 3 次 jq
rebuild_iptables() {
    info "正在重建 iptables 流量统计规则..."
    local port enabled reason
    while IFS="${REC_SEP}" read -r port enabled reason; do
        [[ -z "${port}" || "${port}" == "null" ]] && continue
        remove_port_rules "${port}"
        if [[ "${enabled}" == "true" && -z "${reason}" ]]; then
            add_traffic_rules "${port}"
        else
            add_block_rules "${port}"
        fi
    done < <(jq -r '.[] | [(.port // ""), (if (.enabled // true) then "true" else "false" end), (.disabled_reason // "")] | map(if . == null then "" else tostring end) | join("\u001f")' "${USERS_FILE}")
}

generate_config() {
    if ! has_users; then
        rm -f "${SS_CONFIG}"
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    jq '
    {
        servers:
        [
            .[] |
            {
                server: "0.0.0.0",
                server_port: (.port | tonumber),
                password: .password,
                method: (.method // "aes-256-gcm")
            }
        ]
    }
    ' "${USERS_FILE}" > "${tmp}" || { rm -f "${tmp}"; die "生成 Shadowsocks 配置失败。"; }
    mv -f "${tmp}" "${SS_CONFIG}"
    chmod 600 "${SS_CONFIG}"
}

validate_ss_config() {
    has_users || return 0
    [[ -x "${BIN_PATH}" ]] || { err "找不到 ssserver：${BIN_PATH}"; return 1; }
    [[ -f "${SS_CONFIG}" ]] || { err "找不到配置文件：${SS_CONFIG}"; return 1; }
    jq empty "${SS_CONFIG}" >/dev/null 2>&1 || { err "config.json JSON 格式错误。"; return 1; }
    local c
    c="$(jq '.servers | length' "${SS_CONFIG}")"
    (( c > 0 )) || { err "config.json 中没有服务器。"; return 1; }
    return 0
}

###############################################################################
# systemd 服务
###############################################################################

create_systemd_service() {
    mkdir -p "$(dirname "${SERVICE_FILE}")" 2>/dev/null || true
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Shadowsocks Rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -c ${SS_CONFIG}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "${SERVICE_FILE}"
    systemctl daemon-reload
}

stop_shadowsocks() {
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
    pkill -TERM -x ssserver 2>/dev/null || true
    sleep 1
    pkill -KILL -x ssserver 2>/dev/null || true
}

start_shadowsocks_if_needed() {
    if ! has_users; then
        stop_shadowsocks
        rm -f "${SS_CONFIG}"
        return 0
    fi
    generate_config
    validate_ss_config || return 1
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "Shadowsocks-Rust 已启动。"
        return 0
    fi
    err "Shadowsocks-Rust 启动失败。"
    journalctl -u "${SERVICE_NAME}" -n 30 --no-pager 2>/dev/null || true
    return 1
}

###############################################################################
# Cron：定时流量检查（Worker 同步在 traffic_check 内限流为 1 小时）
###############################################################################

# 把检查间隔转成 crontab 的分钟字段：5 → */5，1 → *，60 → 0（每小时整点）
cron_minute_field() {
    local n="${1}"
    [[ "${n}" =~ ^[0-9]+$ ]] || n=5
    (( n < 1 )) && n=1
    if (( n >= 60 )); then echo "0"; else echo "*/${n}"; fi
}

setup_cron() {
    local field
    field="$(cron_minute_field "${CRON_INTERVAL}")"
    cat > "${CRON_FILE}" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

${field} * * * * root flock -n ${LOCK_FILE} ${MANAGER_PATH} traffic-check >> ${LOG_FILE} 2>&1
EOF
    chmod 644 "${CRON_FILE}"
    systemctl enable cron 2>/dev/null || true
    systemctl restart cron 2>/dev/null || true
}

###############################################################################
# 日志轮转：manager.log + journal 均保留约 7 天，防止无限增长
###############################################################################

setup_logrotate() {
    mkdir -p "$(dirname "${LOGROTATE_CONF}")" 2>/dev/null || true

    # manager.log：按天轮转，保留 7 份，压缩旧文件
    cat > "${LOGROTATE_CONF}" <<EOF
${LOG_FILE} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su root root
    dateext
    dateformat -%Y%m%d
}
EOF
    chmod 644 "${LOGROTATE_CONF}" 2>/dev/null || true

    # journald：整机 journal 最多保留 7 天，并限制体积（专用 VPS 一般可接受）
    mkdir -p "${JOURNALD_CONF_DIR}" 2>/dev/null || true
    cat > "${JOURNALD_CONF_DIR}/99-ss-manager-retention.conf" <<'EOF'
[Journal]
MaxRetentionSec=7day
SystemMaxUse=200M
RuntimeMaxUse=100M
EOF
    chmod 644 "${JOURNALD_CONF_DIR}/99-ss-manager-retention.conf" 2>/dev/null || true
    systemctl restart systemd-journald 2>/dev/null || true

    ok "日志轮转已配置：manager.log 与 journal 均保留约 7 天。"
}

###############################################################################
# Worker 同步频率控制（默认最多 1 小时一次）
###############################################################################

mark_worker_synced() {
    echo "$(now_ts)" > "${LAST_SYNC_FILE}" 2>/dev/null || true
    chmod 600 "${LAST_SYNC_FILE}" 2>/dev/null || true
}

should_sync_worker() {
    local now last
    now="$(now_ts)"

    if [[ ! -f "${LAST_SYNC_FILE}" ]]; then
        mark_worker_synced
        return 0
    fi

    last="$(cat "${LAST_SYNC_FILE}" 2>/dev/null || echo 0)"
    [[ "${last}" =~ ^[0-9]+$ ]] || last=0

    if (( now - last >= WORKER_SYNC_INTERVAL )); then
        mark_worker_synced
        return 0
    fi
    return 1
}

###############################################################################
# 同步到 Cloudflare Worker
###############################################################################
# Worker 同步
###############################################################################

# 是否已启用 Worker 同步（URL 与 TOKEN 都齐全才算启用）
worker_enabled() {
    [[ -n "${WORKER_URL}" && -n "${WORKER_TOKEN}" ]]
}

sync_to_worker() {
    # 未启用时静默跳过
    worker_enabled || return 0
    command -v curl >/dev/null 2>&1 || return 0

    local payload resp code body
    payload="$(jq -c --argjson now "$(now_ts)" --argjson reset_secs "${RESET_SECONDS}" '
        {
            users: [
                .[] | {
                    key:    (.key // ""),
                    name:   .name,
                    used:   (.used // 0),
                    limit:  (.limit // 0),
                    expire: (.expire // 0),
                    # 本流量周期结束时间 = created_at + (last_cycle_index + 1) * 30天
                    traffic_expire: (
                        if (.created_at // 0) > 0
                        then (.created_at + ((.last_cycle_index // 0) + 1) * $reset_secs)
                        else 0
                        end
                    ),
                    port:   (.port // 0),
                    status: (
                        # 到期时间已过则一律显示「已到期」，不依赖 disabled_reason
                        if ((.expire // 0) > 0 and $now >= (.expire // 0)) then "已到期"
                        elif (.enabled // true) == true then "正常"
                        elif (.disabled_reason // "") == "traffic" then "流量超限"
                        elif (.disabled_reason // "") == "expired" then "已到期"
                        else "已禁用"
                        end
                    )
                }
                | select(.key != "")
            ]
        }
    ' "${USERS_FILE}")" || {
        warn "生成 Worker payload 失败"
        return 1
    }

    resp="$(curl -sSL -m 15 -w '\n%{http_code}' \
        -X POST "${WORKER_URL}" \
        -H "Authorization: Bearer ${WORKER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" 2>/dev/null)" || {
        warn "同步到 Worker 失败（网络错误）"
        return 1
    }

    code="$(tail -n1 <<<"${resp}")"
    body="$(sed '$d' <<<"${resp}")"
    if [[ "${code}" != "200" ]]; then
        warn "同步到 Worker 失败：HTTP ${code} ${body}"
        return 1
    fi
    return 0
}

# 通知 Worker 清空云端数据（停用同步前调用，避免残留旧快照）
# 约定：POST 空 users 数组，Worker 侧据此清空 KV/缓存。
# 注意：仅同步清理「本脚本上传的数据」，不影响 Worker 其他功能。
worker_purge_remote() {
    worker_enabled || return 1
    command -v curl >/dev/null 2>&1 || return 1

    local resp code body
    resp="$(curl -sSL -m 15 -w '\n%{http_code}' \
        -X POST "${WORKER_URL}" \
        -H "Authorization: Bearer ${WORKER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"users":[]}' 2>/dev/null)" || return 1

    code="$(tail -n1 <<<"${resp}")"
    body="$(sed '$d' <<<"${resp}")"
    if [[ "${code}" != "200" ]]; then
        warn "清空云端数据失败：HTTP ${code} ${body}"
        return 1
    fi
    return 0
}

###############################################################################
# 自动流量检查（由 cron 定时调用）
###############################################################################

traffic_check() {
    init_dirs

    # 整个「读-改-写」过程中持锁，避免与交互式增删改互相覆盖
    acquire_users_lock 60 || return 1

    migrate_users
    migrate_user_keys

    if ! has_users; then
        release_users_lock
        stop_shadowsocks
        rm -f "${SS_CONFIG}"
        return 0
    fi

    local u
    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        check_user "${u}"
    done < <(jq -r '.[].name' "${USERS_FILE}")

    generate_config

    release_users_lock

    # 网络与 systemctl 操作放在锁外，避免长时间持锁阻塞交互操作
    # 未启用 Worker 时直接跳过，连同步时间戳文件都不写
    if worker_enabled && should_sync_worker; then
        sync_to_worker || true
    fi

    if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        if has_users; then
            start_shadowsocks_if_needed >/dev/null 2>&1 || true
        fi
    fi
}

###############################################################################
# 端口占用检查
###############################################################################

port_exists() {
    local port="$1"
    # 用 tostring 比较，避免旧数据里 port 是字符串时 tonumber 抛错
    jq -e --arg p "${port}" 'any(.[]; (.port // "" | tostring) == $p)' "${USERS_FILE}" >/dev/null 2>&1
}

get_next_port() {
    local port="${DEFAULT_PORT}"
    while port_exists "${port}"; do
        port=$((port + 1))
    done
    echo "${port}"
}

check_port_conflict() {
    local port="$1"
    port_exists "${port}" || return 0
    local owner
    owner="$(jq -r --arg p "${port}" '.[] | select((.port // "" | tostring) == $p) | .name' "${USERS_FILE}" | head -n 1)"
    warn "端口 ${port} 已被用户 ${owner} 使用。"
    read -r -p "是否删除旧用户 ${owner} 并使用该端口？[y/N]: " ans
    if [[ "${ans}" =~ ^[Yy]$ ]]; then
        remove_port_rules "${port}"
        save_users_filter "map(select(.name != \"${owner}\"))"
        ok "旧用户 ${owner} 已删除。"
        return 0
    fi
    return 1
}

###############################################################################
# 添加用户
###############################################################################

add_user() {
    title "添加 Shadowsocks 用户"

    local name port password method limit_input limit
    local months now expire next_reset user_key

    read -r -p "用户名： " name
    [[ -z "${name}" ]] && { err "用户名不能为空。"; return 1; }

    if jq -e --arg n "${name}" 'any(.[]; .name == $n)' "${USERS_FILE}" >/dev/null 2>&1; then
        err "用户已存在：${name}"
        return 1
    fi

    local suggested_port
    suggested_port="$(get_next_port)"
    read -r -p "端口 [${suggested_port}]： " port
    port="${port:-${suggested_port}}"
    if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        err "端口无效。"
        return 1
    fi

    if port_exists "${port}"; then
        check_port_conflict "${port}" || return 1
    fi

    read -r -p "密码 [自动生成]： " password
    [[ -z "${password}" ]] && password="$(random_password)"

    read -r -p "加密方式 [${DEFAULT_METHOD}]： " method
    method="${method:-${DEFAULT_METHOD}}"

    read -r -p "每月流量 [例如 100G，0=不限]： " limit_input
    limit_input="${limit_input:-0}"
    limit="$(parse_limit "${limit_input}")"
    if [[ "${limit}" == "0" && "${limit_input}" != "0" && -n "${limit_input}" ]]; then
        warn "无法识别流量限制，将设置为不限。"
        limit=0
    fi

    read -r -p "购买周期数（每个 30 天） [默认 1]： " months
    months="${months:-1}"
    if ! [[ "${months}" =~ ^[0-9]+$ ]] || (( months < 1 )); then
        err "周期数无效。"
        return 1
    fi

    now="$(now_ts)"
    next_reset="$(calculate_next_reset "${now}" "${now}")"
    expire=$(( now + months * RESET_SECONDS ))
    user_key="$(random_key)"

    local tmp
    tmp="$(mktemp "${DATA_DIR}/.users.json.XXXXXX")"
    jq \
        --arg name "${name}" \
        --arg password "${password}" \
        --arg method "${method}" \
        --arg key "${user_key}" \
        --argjson port "${port}" \
        --argjson limit "${limit}" \
        --argjson created_at "${now}" \
        --argjson next_reset "${next_reset}" \
        --argjson expire "${expire}" \
        --argjson periods "${months}" \
        '
        . + [
            {
                name: $name,
                port: $port,
                password: $password,
                method: $method,
                limit: $limit,
                used: 0,
                used_total: 0,
                created_at: $created_at,
                expire: $expire,
                periods: $periods,
                last_cycle_index: 0,
                last_ipt_tcp: 0,
                last_ipt_udp: 0,
                next_reset: $next_reset,
                last_reset: 0,
                enabled: true,
                disabled_reason: "",
                key: $key
            }
        ]
        ' "${USERS_FILE}" > "${tmp}" || { rm -f "${tmp}"; err "写入用户失败。"; return 1; }
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${USERS_FILE}"

    add_traffic_rules "${port}"
    generate_config
    start_shadowsocks_if_needed || return 1

    echo
    ok "用户添加成功"
    line
    pad_right "用户名："         16; echo "${name}"
    pad_right "服务器："         16; echo "${SS_NODE_DOMAIN}"
    pad_right "端口："           16; echo "${port}"
    pad_right "密码："           16; echo "${password}"
    pad_right "加密："           16; echo "${method}"
    if (( limit > 0 )); then
        pad_right "每月流量："   16; echo "$(bytes_to_human "${limit}")"
    else
        pad_right "每月流量："   16; echo "不限"
    fi
    pad_right "周期数："         16; echo "${months}（每个 30 天）"
    pad_right "创建时间："       16; echo "$(format_ts "${now}")"
    pad_right "到期时间："       16; echo "$(format_ts "${expire}")"
    pad_right "查询 key："       16; echo "${user_key}"
    if [[ -n "${WORKER_QUERY_BASE}" ]]; then
        pad_right "剩余流量查询：" 16; echo "${WORKER_QUERY_BASE}/?key=${user_key}"
    fi
    line
    echo "ss:// 导入链接："
    generate_ss_link "${port}" "${password}" "${method}" "${name}"
    echo

    # 增删改后立即同步 Worker，并更新同步时间戳
    mark_worker_synced
    sync_to_worker || true
}

###############################################################################
# 删除用户
###############################################################################

delete_user() {
    title "删除用户"
    local name
    read -r -p "请输入要删除的用户名： " name
    [[ -z "${name}" ]] && return

    if ! jq -e --arg n "${name}" 'any(.[]; .name == $n)' "${USERS_FILE}" >/dev/null 2>&1; then
        err "用户不存在：${name}"
        return 1
    fi

    local port
    port="$(jq -r --arg n "${name}" '.[]|select(.name==$n)|.port' "${USERS_FILE}" | head -n 1)"

    read -r -p "确定删除用户 ${name}？输入 YES： " confirm
    [[ "${confirm}" == "YES" ]] || { echo "已取消。"; return; }

    remove_port_rules "${port}"
    save_users_filter "map(select(.name != \"${name}\"))"

    if ! has_users; then
        stop_shadowsocks
        rm -f "${SS_CONFIG}"
        ok "用户已删除，已无用户，Shadowsocks-Rust 已停止。"
        mark_worker_synced
        sync_to_worker || true
        return
    fi

    rebuild_iptables
    generate_config
    start_shadowsocks_if_needed
    ok "用户 ${name} 已删除。"
    mark_worker_synced
    sync_to_worker || true
}

###############################################################################
# 重置本周期流量（不改套餐、不改 created_at；已到期用户无效）
###############################################################################

reset_user_traffic() {
    title "重置用户本周期流量"
    local name
    read -r -p "请输入用户名： " name
    [[ -z "${name}" ]] && return

    local port="" created_at="" expire=""
    IFS="${REC_SEP}" read -r port created_at expire _ <<<"$(get_user_fields "${name}")"
    [[ -z "${port}" ]] && { err "用户不存在。"; return 1; }

    local now
    now="$(now_ts)"
    [[ "${expire}" =~ ^[0-9]+$ ]] || expire=0

    if (( expire > 0 && now >= expire )); then
        warn "该用户账号已到期，reset 不会恢复。请使用「续费」功能。"
        return 1
    fi

    remove_port_rules "${port}"
    add_traffic_rules "${port}"

    update_user_field_json "${name}" \
        '.used = 0 | .last_ipt_tcp = 0 | .last_ipt_udp = 0 | .enabled = true | .disabled_reason = ""'

    generate_config
    start_shadowsocks_if_needed
    mark_worker_synced
    sync_to_worker || true

    ok "用户 ${name} 本周期流量已重置。"
    info "created_at 未改变：$(format_ts "${created_at}")"
}

###############################################################################
# 续费：从 max(now, expire) 起增加周期，并清零本周期 used、恢复可用
###############################################################################

renew_user() {
    title "续费用户（增加周期）"
    local name
    read -r -p "请输入用户名： " name
    [[ -z "${name}" ]] && return

    local port="" created_at="" expire="" periods=""
    IFS="${REC_SEP}" read -r port created_at expire _ _ _ _ _ _ _ _ _ <<<"$(get_user_fields "${name}")"
    [[ -z "${port}" ]] && { err "用户不存在。"; return 1; }

    periods="$(jq -r '.[] | select(.name == $n) | (.periods // 1)' --arg n "${name}" "${USERS_FILE}" | head -n 1)"
    [[ "${periods}" =~ ^[0-9]+$ ]] || periods=1

    local now base n new_expire new_periods new_idx
    now="$(now_ts)"
    [[ "${expire}" =~ ^[0-9]+$ ]] || expire=0
    [[ "${created_at}" =~ ^[0-9]+$ ]] || created_at=0

    echo "当前到期时间：$(format_ts "${expire}")"
    echo "当前周期数：${periods}"

    read -r -p "续费周期数 [默认 1]： " n
    n="${n:-1}"
    if ! [[ "${n}" =~ ^[0-9]+$ ]] || (( n < 1 )); then
        err "周期数无效。"
        return 1
    fi

    base="${expire}"
    (( base < now )) && base="${now}"
    new_expire=$(( base + n * RESET_SECONDS ))
    new_periods=$(( periods + n ))
    new_idx="$(current_cycle_index "${created_at}" "${now}")"

    remove_port_rules "${port}"
    add_traffic_rules "${port}"

    update_user_field_json "${name}" \
        ".expire = ${new_expire} | .periods = ${new_periods} | .used = 0 | .last_ipt_tcp = 0 | .last_ipt_udp = 0 | .enabled = true | .disabled_reason = \"\" | .last_cycle_index = ${new_idx}"

    generate_config
    start_shadowsocks_if_needed
    mark_worker_synced
    sync_to_worker || true

    ok "用户 ${name} 续费完成。"
    pad_right "新到期时间：" 16; echo "$(format_ts "${new_expire}")"
    pad_right "新周期数："   16; echo "${new_periods}"
}

###############################################################################
# 重置全部未过期用户的本周期流量
###############################################################################

reset_all_traffic() {
    title "重置全部用户流量"
    warn "将重置所有未过期用户的本周期流量，created_at 不变。"
    read -r -p "确定继续？输入 YES： " confirm
    [[ "${confirm}" == "YES" ]] || { echo "已取消。"; return; }

    local name port expire now
    now="$(now_ts)"

    # 一次取出全部用户的 name/port/expire，避免逐个 jq
    while IFS="${REC_SEP}" read -r name port expire; do
        [[ -z "${name}" || -z "${port}" ]] && continue
        [[ "${expire}" =~ ^[0-9]+$ ]] || expire=0

        remove_port_rules "${port}"

        if (( expire > 0 && now >= expire )); then
            add_block_rules "${port}"
            update_user_field_json "${name}" '.enabled = false | .disabled_reason = "expired"'
            continue
        fi

        add_traffic_rules "${port}"
        update_user_field_json "${name}" \
            '.used = 0 | .last_ipt_tcp = 0 | .last_ipt_udp = 0 | .enabled = true | .disabled_reason = ""'
    done < <(jq -r '.[] | [.name, (.port // "" | tostring), (.expire // 0)] | map(if . == null then "" else tostring end) | join("\u001f")' "${USERS_FILE}")

    generate_config
    start_shadowsocks_if_needed
    mark_worker_synced
    sync_to_worker || true
    ok "所有未过期用户流量已重置。"
}

###############################################################################
# 用户列表 / 详情 / 导出链接
###############################################################################

list_users() {
    title "Shadowsocks 用户列表"
    if ! has_users; then
        echo "暂无用户。"
        echo
        return
    fi

    local W_NAME=18
    local W_PORT=8
    local W_USED=14
    local W_LIMIT=14
    local W_EXPIRE=20
    local W_STATUS=12

    pad_right "用户名"   "${W_NAME}";   printf '  '
    pad_right "端口"     "${W_PORT}";   printf '  '
    pad_right "已使用"   "${W_USED}";   printf '  '
    pad_right "每月流量" "${W_LIMIT}";  printf '  '
    pad_right "到期时间" "${W_EXPIRE}"; printf '  '
    pad_right "状态"     "${W_STATUS}"
    echo
    line

    local u port used limit expire enabled reason current total status used_text limit_text
    # 一次 jq 取出列表所需全部字段，避免每用户 6 次 fork
    while IFS="${REC_SEP}" read -r u port used limit expire enabled reason; do
        [[ -z "${u}" ]] && continue

        [[ "${used}" =~ ^[0-9]+$ ]] || used=0
        [[ "${limit}" =~ ^[0-9]+$ ]] || limit=0
        [[ "${expire}" =~ ^[0-9]+$ ]] || expire=0
        [[ "${port}" =~ ^[0-9]+$ ]] || port=""

        current=0
        [[ -n "${port}" ]] && { current="$(get_port_traffic "${port}")"; }
        [[ "${current}" =~ ^[0-9]+$ ]] || current=0
        total=$(( used + current ))

        # 状态同时考虑 expire 与 disabled_reason，避免 cron 未运行时误显示「正常」
        status="$(user_display_status "${enabled}" "${reason}" "${expire}")"

        used_text="$(bytes_to_human "${total}")"
        (( limit > 0 )) && limit_text="$(bytes_to_human "${limit}")" || limit_text="不限"

        pad_right "${u}"          "${W_NAME}";   printf '  '
        pad_right "${port}"       "${W_PORT}";   printf '  '
        pad_right "${used_text}"  "${W_USED}";   printf '  '
        pad_right "${limit_text}" "${W_LIMIT}";  printf '  '
        pad_right "$(format_ts "${expire}")" "${W_EXPIRE}"; printf '  '
        pad_right "${status}"     "${W_STATUS}"
        echo
    done < <(jq -r '.[] | [
        .name,
        (.port // "" | tostring),
        (.used // 0),
        (.limit // 0),
        (.expire // 0),
        (if (.enabled // true) then "true" else "false" end),
        (.disabled_reason // "")
    ] | map(if . == null then "" else tostring end) | join("\u001f")' "${USERS_FILE}")
    echo
}

show_user() {
    title "用户详情"
    local name
    read -r -p "请输入用户名： " name
    [[ -z "${name}" ]] && return

    local port password method limit used expire periods enabled reason
    local current total percent used_total user_key

    # 一次 jq 取出详情页所需字段
    IFS="${REC_SEP}" read -r port password method limit used expire periods enabled reason used_total user_key \
        <<<"$(jq -r --arg n "${name}" '
            .[] | select(.name == $n) | [
                (.port // "" | tostring),
                (.password // ""),
                (.method // "aes-256-gcm"),
                (.limit // 0),
                (.used // 0),
                (.expire // 0),
                (.periods // 1),
                (if (.enabled // true) then "true" else "false" end),
                (.disabled_reason // ""),
                (.used_total // 0),
                (.key // "")
            ] | map(if . == null then "" else tostring end) | join("\u001f")
        ' "${USERS_FILE}" | head -n 1)"

    [[ -z "${port}" ]] && { err "用户不存在。"; return 1; }

    [[ "${limit}" =~ ^[0-9]+$ ]] || limit=0
    [[ "${used}" =~ ^[0-9]+$ ]] || used=0
    [[ "${expire}" =~ ^[0-9]+$ ]] || expire=0
    [[ "${used_total}" =~ ^[0-9]+$ ]] || used_total=0
    [[ "${periods}" =~ ^[0-9]+$ ]] || periods=1

    current=0
    [[ "${port}" =~ ^[0-9]+$ ]] && current="$(get_port_traffic "${port}")"
    [[ "${current}" =~ ^[0-9]+$ ]] || current=0
    total=$(( used + current ))

    echo
    pad_right "用户名："   16; echo "${name}"
    pad_right "服务器："   16; echo "${SS_NODE_DOMAIN}"
    pad_right "端口："     16; echo "${port}"
    pad_right "密码："     16; echo "${password}"
    pad_right "加密："     16; echo "${method}"
    line

    if (( limit > 0 )); then
        percent="$(awk -v u="${total}" -v l="${limit}" 'BEGIN{if(l<=0)print 0;else printf "%.2f", u/l*100}')"
        pad_right "本周期流量：" 16
        echo "$(bytes_to_human "${total}") / $(bytes_to_human "${limit}")（${percent}%）"
    else
        pad_right "本周期流量：" 16
        echo "$(bytes_to_human "${total}")（不限）"
    fi

    pad_right "累计流量：" 16; echo "$(bytes_to_human "${used_total}")"
    pad_right "周期数："   16; echo "${periods}（每个 30 天）"

    if (( expire > 0 )); then
        pad_right "到期时间：" 16; echo "$(format_ts "${expire}")"
        pad_right "剩余："     16; echo "$(remaining_time "${expire}")"
    else
        pad_right "到期时间：" 16; echo "永久"
    fi

    pad_right "状态：" 16
    echo "$(user_display_status "${enabled}" "${reason}" "${expire}")"

    if [[ -n "${user_key}" ]]; then
        pad_right "查询 key："   16; echo "${user_key}"
        if [[ -n "${WORKER_QUERY_BASE}" ]]; then
            pad_right "剩余流量查询：" 16; echo "${WORKER_QUERY_BASE}/?key=${user_key}"
        fi
    fi

    line
    echo "ss:// 导入链接："
    generate_ss_link "${port}" "${password}" "${method}" "${name}"
    echo
}

export_all_links() {
    title "Shadowsocks 用户导入链接"
    has_users || { warn "当前没有用户。"; return; }

    echo "服务器：${SS_NODE_DOMAIN}"
    echo

    local u port password method enabled reason expire user_key status
    while IFS="${REC_SEP}" read -r u port password method enabled reason expire user_key; do
        [[ -z "${u}" ]] && continue

        [[ "${expire}" =~ ^[0-9]+$ ]] || expire=0
        status="$(user_display_status "${enabled}" "${reason}" "${expire}")"

        line
        pad_right "用户：" 12; echo "${u}"
        pad_right "状态：" 12; echo "${status}"
        pad_right "端口：" 12; echo "${port}"
        if [[ -n "${user_key}" ]]; then
            pad_right "key：" 12; echo "${user_key}"
        fi
        echo
        generate_ss_link "${port}" "${password}" "${method}" "${u}"
        if [[ -n "${user_key}" && -n "${WORKER_QUERY_BASE}" ]]; then
            echo "剩余流量查询：${WORKER_QUERY_BASE}/?key=${user_key}"
        fi
        echo
    done < <(jq -r '.[] | [
        .name,
        (.port // "" | tostring),
        (.password // ""),
        (.method // "aes-256-gcm"),
        (if (.enabled // true) then "true" else "false" end),
        (.disabled_reason // ""),
        (.expire // 0),
        (.key // "")
    ] | map(if . == null then "" else tostring end) | join("\u001f")' "${USERS_FILE}")
}

###############################################################################
# Worker 手动同步与配置
###############################################################################

manual_sync_worker() {
    title "同步到 Cloudflare Worker"
    if [[ -z "${WORKER_URL}" || -z "${WORKER_TOKEN}" ]]; then
        warn "未配置 Worker。"
        echo
        echo "请创建 ${WORKER_CONF}，内容示例："
        echo
        echo "WORKER_URL=\"${WORKER_API_URL}\""
        echo 'WORKER_TOKEN="你的随机token"'
        echo "WORKER_QUERY_BASE=\"${WORKER_QUERY_DOMAIN}\""
        echo
        return 1
    fi

    if sync_to_worker; then
        mark_worker_synced
        ok "同步成功。"
        info "查询地址：${WORKER_QUERY_BASE}/?key=<用户key>"
    else
        err "同步失败，请查看日志。"
        return 1
    fi
}

worker_config() {
    title "Worker 同步配置"
    if ! worker_enabled; then
        echo -e "${YELLOW}当前未启用 Worker 同步。${RESET}"
        echo "（WORKER_URL 与 WORKER_TOKEN 至少缺一项即视为未启用）"
        echo
    fi
    echo "配置文件：${WORKER_CONF}"
    echo
    echo "当前值："
    pad_right "WORKER_URL："        20; echo "${WORKER_URL:-（未设置）}"
    pad_right "WORKER_TOKEN："      20; echo "${WORKER_TOKEN:+（已设置）}${WORKER_TOKEN:-（未设置）}"
    pad_right "WORKER_QUERY_BASE：" 20; echo "${WORKER_QUERY_BASE:-（未设置）}"
    echo
    echo "默认上传接口：${WORKER_API_URL}"
    echo "默认查询地址：${WORKER_QUERY_DOMAIN}/?key=<用户key>"
    echo

    local url token base
    read -r -p "WORKER_URL（留空保持）: " url
    read -r -p "WORKER_TOKEN（留空保持）: " token
    read -r -p "WORKER_QUERY_BASE（留空保持）: " base

    [[ -z "${url}" ]]   && url="${WORKER_URL}"
    [[ -z "${token}" ]] && token="${WORKER_TOKEN}"
    [[ -z "${base}" ]]  && base="${WORKER_QUERY_BASE}"

    cat > "${WORKER_CONF}" <<EOF
WORKER_URL="${url}"
WORKER_TOKEN="${token}"
WORKER_QUERY_BASE="${base}"
EOF
    chmod 600 "${WORKER_CONF}"

    WORKER_URL="${url}"
    WORKER_TOKEN="${token}"
    WORKER_QUERY_BASE="${base}"

    ok "配置已保存。"
}

###############################################################################
# 删除（停用）Worker 同步
#
# 包含三件事，缺一不可：
#   1) 清空云端残留数据（否则用户仍能用旧 key 看到过期快照）
#   2) 删除本地 worker.conf（TOKEN 落在这里，必须一并清掉）
#   3) 复位运行时变量，当前会话内立即生效
# 用户 key 保留在 users.json 中，将来重新启用时无需重发链接。
###############################################################################

remove_worker_sync() {
    title "删除 Worker 同步"

    local had_conf=0
    [[ -f "${WORKER_CONF}" ]] && had_conf=1
    local was_enabled=0
    worker_enabled && was_enabled=1

    if (( had_conf == 0 && was_enabled == 0 )); then
        info "当前未配置 Worker 同步，无需删除。"
        echo
        return 0
    fi

    echo "将执行以下操作："
    echo "  1) 尝试清空云端已上传的用户数据（避免残留旧快照）"
    echo "  2) 删除本地配置：${WORKER_CONF}（含 TOKEN）"
    echo "  3) 停止后续的自动/手动同步"
    echo
    echo -e "${DIM}说明：用户的查询 key 会保留在 users.json 中，"
    echo -e "      将来重新配置 Worker 时引用旧 key 依然有效。${RESET}"
    echo

    # 可选：先清云端
    local purge="y"
    if (( was_enabled == 1 )); then
        read -r -p "是否同时清空云端数据？[Y/n]: " purge
    else
        purge="n"
    fi

    echo
    if [[ ! "${purge}" =~ ^[Nn]$ ]] && (( was_enabled == 1 )); then
        info "正在清空云端数据..."
        if worker_purge_remote; then
            ok "云端数据已清空。"
        else
            warn "云端数据清空失败（可能是 Worker 不支持空数组，或网络/鉴权问题）。"
            warn "本地配置仍会继续删除；如有需要，请到 Cloudflare 后台手动清理。"
        fi
    else
        info "跳过云端清理。"
    fi

    read -r -p "确认删除本地 Worker 配置并停用同步？输入 YES： " confirm
    if [[ "${confirm}" != "YES" ]]; then
        echo "已取消。"
        return 1
    fi

    if (( had_conf == 1 )); then
        rm -f "${WORKER_CONF}"
        ok "已删除配置文件：${WORKER_CONF}"
    fi

    # 复位运行时变量，本次会话不再触发同步
    WORKER_URL=""
    WORKER_TOKEN=""
    WORKER_QUERY_BASE=""
    rm -f "${LAST_SYNC_FILE}" 2>/dev/null || true

    echo
    ok "Worker 同步已停用。"
    info "用户查询页（${WORKER_QUERY_DOMAIN}/?key=...）将不再更新；"
    info "重新启用请使用菜单 9「配置 Worker 同步」。"
    echo
}

###############################################################################
# 服务状态 / 日志
###############################################################################

service_status() {
    title "Shadowsocks-Rust 服务状态"
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo -e "服务状态：${GREEN}运行中${RESET}"
    else
        echo -e "服务状态：${RED}未运行${RESET}"
    fi
    echo
    systemctl status "${SERVICE_NAME}" --no-pager -l 2>/dev/null || true
    echo
}

show_logs() {
    title "Shadowsocks-Rust 日志"
    journalctl -u "${SERVICE_NAME}" -n 100 --no-pager 2>/dev/null || true
    echo
}

show_manager_log() {
    title "管理器日志（cron）"
    if [[ -f "${LOG_FILE}" ]]; then
        tail -n 100 "${LOG_FILE}"
    else
        warn "日志文件不存在：${LOG_FILE}"
    fi
    echo
}

###############################################################################
# 更新 / 安装 / 卸载
###############################################################################

update_shadowsocks() {
    title "更新 Shadowsocks-Rust"
    if ! [[ -x "${BIN_PATH}" ]]; then
        install_shadowsocks
        create_systemd_service
        generate_config
        start_shadowsocks_if_needed
        return
    fi
    local old_version
    old_version="$("${BIN_PATH}" --version 2>/dev/null | head -n 1)"
    info "当前版本：${old_version}"
    install_shadowsocks
    create_systemd_service
    if has_users; then
        generate_config
        start_shadowsocks_if_needed
    else
        stop_shadowsocks
        rm -f "${SS_CONFIG}"
    fi
    ok "更新完成。"
}

install_all() {
    title "Shadowsocks-Rust 多用户管理器 · 首次安装"
    install_dependencies
    check_dependencies
    init_dirs
    migrate_users
    migrate_user_keys

    if [[ ! -x "${BIN_PATH}" ]]; then
        install_shadowsocks
    else
        info "检测到已有 Shadowsocks-Rust，跳过重复安装。"
    fi

    create_systemd_service
    setup_cron
    setup_logrotate

    if has_users; then
        rebuild_iptables
        generate_config
        start_shadowsocks_if_needed
    else
        stop_shadowsocks
        rm -f "${SS_CONFIG}"
        info "当前没有用户。Shadowsocks-Rust 暂不启动。"
    fi

    ok "安装完成。"
}

uninstall() {
    title "卸载 Shadowsocks-Rust 多用户管理器"
    warn "此操作将删除 Shadowsocks-Rust、所有用户配置、systemd、Cron、iptables 规则、日志轮转和 ss-manager。"
    read -r -p "确认卸载？请输入 YES： " confirm
    [[ "${confirm}" == "YES" ]] || { echo "已取消。"; return; }

    info "停止 Shadowsocks-Rust..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true

    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload

    pkill -TERM -x ssserver 2>/dev/null || true
    sleep 1
    pkill -KILL -x ssserver 2>/dev/null || true

    rm -f "${CRON_FILE}"
    systemctl restart cron 2>/dev/null || true

    # 清理日志轮转与 journal 保留策略
    rm -f "${LOGROTATE_CONF}"
    rm -f "${JOURNALD_CONF_DIR}/99-ss-manager-retention.conf"
    systemctl restart systemd-journald 2>/dev/null || true

    if [[ -f "${USERS_FILE}" ]]; then
        while IFS= read -r port; do
            [[ -z "${port}" ]] && continue
            remove_port_rules "${port}"
        done < <(jq -r '.[].port' "${USERS_FILE}" 2>/dev/null)
    fi

    rm -f "${BIN_PATH}" "${BIN_PATH}.bak"
    rm -rf "${CONFIG_DIR}"

    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true

    rm -f "${MANAGER_PATH}"
    ok "卸载完成。"
    exit 0
}

###############################################################################
# 菜单
###############################################################################

show_banner() {
    echo
    echo -e "${CYAN}${BOLD}"
    cat <<'EOF'
   ____  ____    __  __      _    _   _    _  _____ _____ ____
  / ___|/ ___|  |  \/  |    / \  | \ | |  / \|_   _| ____|  _ \
  \___ \\___ \  | |\/| |   / _ \ |  \| | / _ \ | | |  _| | |_) |
   ___) |___) | | |  | |  / ___ \| |\  |/ ___ \| | | |___|  _ <
  |____/|____/  |_|  |_| /_/   \_\_| \_/_/   \_\_| |_____|_| \_\
EOF
    echo -e "${RESET}"
    echo -e "${DIM}        Shadowsocks-Rust 多用户管理器${RESET}"
    echo
}

main_menu() {
    while true; do
        clear
        show_banner
        echo -e "${BOLD}┌────────────────────────── 用户管理 ──────────────────────────┐${RESET}"
        echo -e "  ${GREEN}1${RESET}) 添加用户                    ${GREEN}2${RESET}) 删除用户"
        echo -e "  ${GREEN}3${RESET}) 用户列表                    ${GREEN}4${RESET}) 用户详情"
        echo -e "${BOLD}├──────────────────────── 流量与套餐 ──────────────────────────┤${RESET}"
        echo -e "  ${GREEN}5${RESET}) 重置本周期流量              ${GREEN}6${RESET}) 续费（加周期）"
        echo -e "  ${GREEN}7${RESET}) 重置全部用户流量"
        echo -e "${BOLD}├────────────────────────── 链接导出 ──────────────────────────┤${RESET}"
        echo -e "  ${GREEN}8${RESET}) 导出全部 SS 导入链接"
        echo -e "${BOLD}├──────────────────────── Worker 同步 ─────────────────────────┤${RESET}"
        echo -e "  ${GREEN}9${RESET}) 配置 Worker 同步             ${GREEN}10${RESET}) 手动同步到 Worker"
        if worker_enabled; then
            echo -e "  ${GREEN}11${RESET}) 删除 Worker 同步           ${DIM}（当前：已启用）${RESET}"
        else
            echo -e "  ${DIM}11) 删除 Worker 同步           （当前：未启用）${RESET}"
        fi
        echo -e "${BOLD}├──────────────────────── 服务与维护 ──────────────────────────┤${RESET}"
        echo -e "  ${GREEN}12${RESET}) 查看服务状态                ${GREEN}13${RESET}) 查看服务日志"
        echo -e "  ${GREEN}14${RESET}) 查看管理器日志              ${GREEN}15${RESET}) 更新 Shadowsocks-Rust"
        echo -e "  ${GREEN}16${RESET}) 手动流量检查                ${GREEN}17${RESET}) 重建 iptables 规则"
        echo -e "  ${GREEN}18${RESET}) 卸载"
        echo -e "${BOLD}└──────────────────────────────────────────────────────────────┘${RESET}"
        echo -e "  ${RED}0${RESET}) 退出"
        echo

        local choice
        read -r -p "请选择 [0-18]： " choice

        case "${choice}" in
            1)  acquire_users_lock 30 && { add_user; release_users_lock; }; read -r -p "按回车继续..." ;;
            2)  acquire_users_lock 30 && { delete_user; release_users_lock; }; read -r -p "按回车继续..." ;;
            3)  acquire_users_lock 10 && { list_users; release_users_lock; }; read -r -p "按回车继续..." ;;
            4)  acquire_users_lock 10 && { show_user; release_users_lock; }; read -r -p "按回车继续..." ;;
            5)  acquire_users_lock 30 && { reset_user_traffic; release_users_lock; }; read -r -p "按回车继续..." ;;
            6)  acquire_users_lock 30 && { renew_user; release_users_lock; }; read -r -p "按回车继续..." ;;
            7)  acquire_users_lock 30 && { reset_all_traffic; release_users_lock; }; read -r -p "按回车继续..." ;;
            8)  acquire_users_lock 10 && { export_all_links; release_users_lock; }; read -r -p "按回车继续..." ;;
            9)  worker_config;         read -r -p "按回车继续..." ;;
            10) acquire_users_lock 15 && { manual_sync_worker; release_users_lock; }; read -r -p "按回车继续..." ;;
            11) remove_worker_sync;    read -r -p "按回车继续..." ;;
            12) service_status;        read -r -p "按回车继续..." ;;
            13) show_logs;             read -r -p "按回车继续..." ;;
            14) show_manager_log;      read -r -p "按回车继续..." ;;
            15) update_shadowsocks;    read -r -p "按回车继续..." ;;
            16) traffic_check; ok "流量检查完成。"; read -r -p "按回车继续..." ;;
            17) acquire_users_lock 15 && { rebuild_iptables; release_users_lock; }; ok "iptables 重建完成。"; read -r -p "按回车继续..." ;;
            18) uninstall ;;
            0)  clear; exit 0 ;;
            *)  warn "无效选项。"; sleep 1 ;;
        esac
    done
}

###############################################################################
# 命令行入口（非交互）
###############################################################################

# CLI 公共前置：root 检查 + 目录 + 依赖 + 迁移（迁移本身会写文件，需持锁）
cli_bootstrap() {
    check_root
    init_dirs
    check_dependencies
    acquire_users_lock 30 || exit 1
    migrate_users
    migrate_user_keys
    release_users_lock
}

case "${1:-}" in
    traffic-check)
        cli_bootstrap
        traffic_check
        exit 0
        ;;
    add)
        cli_bootstrap
        add_user
        exit 0
        ;;
    list)
        cli_bootstrap
        list_users
        exit 0
        ;;
    sync)
        cli_bootstrap
        manual_sync_worker
        exit 0
        ;;
    unsync|remove-sync)
        cli_bootstrap
        if [[ "${2:-}" == "-y" || "${2:-}" == "--yes" ]]; then
            # 非交互模式：跳过确认，也不清云端（避免误删生产数据）
            rm -f "${WORKER_CONF}" "${LAST_SYNC_FILE}"
            ok "Worker 配置已删除，同步已停用。"
            warn "未清理云端数据；如需清理请使用交互菜单 11 或到 Cloudflare 后台操作。"
        else
            remove_worker_sync
        fi
        exit 0
        ;;
    status)    check_root; service_status; exit 0 ;;
    logs)      check_root; show_logs; exit 0 ;;
    update)    check_root; init_dirs; check_dependencies; update_shadowsocks; exit 0 ;;
    uninstall) check_root; uninstall; exit 0 ;;
esac

###############################################################################
# 主入口
###############################################################################

main() {
    check_root
    install_self
    init_dirs
    install_dependencies
    check_dependencies

    acquire_users_lock 30 && {
        migrate_users
        migrate_user_keys
        release_users_lock
    }

    if [[ ! -x "${BIN_PATH}" || ! -f "${SERVICE_FILE}" ]]; then
        install_all
    else
        create_systemd_service
        setup_cron
        setup_logrotate
        if has_users; then
            acquire_users_lock 30 && {
                generate_config
                rebuild_iptables
                release_users_lock
            }
            systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null \
                || start_shadowsocks_if_needed
        else
            stop_shadowsocks
            rm -f "${SS_CONFIG}"
        fi
    fi

    main_menu
}

main "$@"

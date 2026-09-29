#!/usr/bin/env bash

###############################################################################
# Shadowsocks-Rust 多用户管理脚本
#
# 功能：
#   - 自动安装 Shadowsocks-Rust（musl 优先，gnu 回退）
#   - 多用户管理（增删改查、续费、流量重置）
#   - 支持永久用户（购买周期填 0 或 "无限"）
#   - 基于 iptables 的流量统计与超限封禁
#   - systemd 托管服务、cron 定时流量检查
###############################################################################

set -u
set -o pipefail

# 保证 UTF-8 环境，中文宽度计算才准确
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=en_US.UTF-8 2>/dev/null || true

###############################################################################
# 基础配置
###############################################################################

APP_NAME="ss-manager"
MANAGER_PATH="/usr/local/bin/ss-manager"
CONFIG_DIR="/etc/shadowsocks-rust"
USERS_FILE="${CONFIG_DIR}/users.json"
SS_CONFIG="${CONFIG_DIR}/config.json"
LOG_FILE="${CONFIG_DIR}/manager.log"
SERVICE_NAME="shadowsocks-rust"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BIN_PATH="/usr/local/bin/ssserver"

RESET_DAYS=30
RESET_SECONDS=$((RESET_DAYS * 86400))
DEFAULT_METHOD="aes-256-gcm"
GITHUB_API="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
CRON_FILE="/etc/cron.d/ss-manager"
DEFAULT_PORT=8388

###############################################################################
# 颜色定义
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

###############################################################################
# 输出辅助
###############################################################################

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
# 显示宽度计算（CJK 字符占 2 列）
###############################################################################

display_width() {
    local str="$1"
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
    echo "${#str}"
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

###############################################################################
# 权限检查
###############################################################################

check_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行此脚本。"
}

###############################################################################
# 时间相关
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

# 时间戳 -> 显示用文本：0 表示永久
format_expire() {
    local ts="${1:-0}"
    if [[ "${ts}" =~ ^[0-9]+$ ]] && (( ts > 0 )); then
        format_ts "${ts}"
    else
        echo "永久"
    fi
}

remaining_time() {
    local target="$1" now diff days hours minutes
    if [[ "${target}" =~ ^[0-9]+$ ]] && (( target == 0 )); then
        echo "永久"
        return
    fi
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

###############################################################################
# 字节格式化
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

###############################################################################
# 随机密码（24 位字母数字）
###############################################################################

random_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
    echo
}

###############################################################################
# 解析周期数输入：支持 0 / 无限 / ∞ / unlimited 表示永久
###############################################################################
# 返回值：0 表示永久；正整数表示周期数
parse_periods() {
    local input="$1"
    case "${input}" in
        无限|无限期|永久|∞|unlimited|UNLIMITED|Unlimited)
            echo 0
            return 0
            ;;
    esac
    if [[ "${input}" =~ ^[0-9]+$ ]]; then
        echo "${input}"
        return 0
    fi
    return 1
}

###############################################################################
# 目录与初始文件
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

###############################################################################
# 把当前脚本安装到 /usr/local/bin/ss-manager
###############################################################################

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
# 依赖安装与检查
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
# 安装 Shadowsocks-Rust
#
# 逻辑要点：
#   1. 优先尝试 musl 静态版（无 glibc 依赖，兼容性最好）
#   2. musl 失败时自动回退到 gnu 版
#   3. 下载后先在临时目录试运行 --version，只有真能跑才替换系统文件
#   4. 替换失败自动回滚到旧版本
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
    local version arch tmp_dir archive extract_dir extracted_bin
    local base_url variants variant ok

    info "正在获取 Shadowsocks-Rust 最新版本..."
    version="$(get_latest_version)" || die "无法获取 Shadowsocks-Rust 最新版本。"
    arch="$(get_target_arch)" || die "暂不支持当前 CPU 架构：$(uname -m)"
    info "最新版本：${version}"
    info "系统架构：${arch}"

    tmp_dir="$(mktemp -d)"
    archive="${tmp_dir}/shadowsocks-rust.tar.xz"

    base_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${version}/shadowsocks-v${version#v}.${arch}-unknown-linux"
    variants=("musl" "gnu")
    ok=0

    for variant in "${variants[@]}"; do
        url="${base_url}-${variant}.tar.xz"
        info "尝试下载（${variant}）：${url}"

        rm -f "${archive}"
        if ! curl -fL --connect-timeout 15 --max-time 300 --retry 3 -o "${archive}" "${url}"; then
            warn "下载 ${variant} 版本失败，尝试下一个。"
            continue
        fi

        info "正在解压 ${variant} 版本..."
        extract_dir="${tmp_dir}/extract_${variant}"
        rm -rf "${extract_dir}"
        mkdir -p "${extract_dir}"
        if ! tar -xJf "${archive}" -C "${extract_dir}"; then
            warn "解压 ${variant} 版本失败，尝试下一个。"
            continue
        fi

        extracted_bin="$(find "${extract_dir}" -type f -name 'ssserver' | head -n 1)"
        if [[ -z "${extracted_bin}" || ! -f "${extracted_bin}" ]]; then
            warn "${variant} 包中没有找到 ssserver，尝试下一个。"
            continue
        fi

        chmod 755 "${extracted_bin}"

        if ! "${extracted_bin}" --version >/dev/null 2>&1; then
            warn "${variant} 版本无法运行（可能 glibc 不兼容），尝试下一个。"
            continue
        fi

        ok=1
        break
    done

    if (( ok == 0 )); then
        rm -rf "${tmp_dir}"
        die "Shadowsocks-Rust 安装失败：所有变体（musl / gnu）均不可用。"
    fi

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
# 用户数据基础操作
###############################################################################

get_user_count() { jq 'length' "${USERS_FILE}" 2>/dev/null || echo 0; }
has_users() { [[ "$(get_user_count)" -gt 0 ]]; }

has_enabled_users() {
    jq -e 'any(.[]; (.enabled // true) == true)' "${USERS_FILE}" >/dev/null 2>&1
}

save_users() {
    local tmp
    tmp="$(mktemp)"
    jq '.' "${USERS_FILE}" > "${tmp}" || { rm -f "${tmp}"; die "保存 users.json 失败。"; }
    mv -f "${tmp}" "${USERS_FILE}"
    chmod 600 "${USERS_FILE}"
}

get_user_json() {
    jq -c --arg n "$1" '.[] | select(.name == $n)' "${USERS_FILE}" | head -n 1
}

update_user_field_json() {
    local name="$1" expr="$2" tmp
    tmp="$(mktemp)"
    jq --arg n "${name}" "
        map(
            if .name == \$n
            then ${expr}
            else . end
        )
    " "${USERS_FILE}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${USERS_FILE}"
    chmod 600 "${USERS_FILE}"
}

###############################################################################
# 数据迁移：为旧版 users.json 补齐缺失字段
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

    jq '
        map(
            .created_at = (.created_at // now | floor) |
            .used = (.used // 0) |
            .limit = (.limit // 0) |
            .expire = (.expire // 0) |
            .enabled = (.enabled // true) |
            .disabled_reason = (.disabled_reason // "") |
            .method = (.method // "aes-256-gcm") |

            # 注意：periods 允许为 0（永久用户），不能简单用 // 兜底
            .periods = (
                if has("periods") and (.periods | type == "number")
                then .periods
                else (
                    if (.expire // 0) > 0 and (.created_at // 0) > 0
                    then ([((.expire - .created_at) / 2592000) | floor, 1] | max)
                    else 1
                    end
                )
                end
            ) |

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
            .last_reset = (.last_reset // 0)
        )
    ' "${USERS_FILE}" > "${tmp}" || { rm -f "${tmp}"; warn "migrate_users jq 失败。"; return; }

    mv -f "${tmp}" "${USERS_FILE}"
    chmod 600 "${USERS_FILE}"
}

###############################################################################
# 周期计算
###############################################################################

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

current_cycle_index() {
    local created_at="$1" now="$2"
    if (( created_at <= 0 )); then
        echo 0
        return
    fi
    echo $(( (now - created_at) / RESET_SECONDS ))
}

###############################################################################
# 获取服务器公网 IPv4
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
# URL 编码 与 SS 链接生成
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
    [[ -z "${server}" ]] && server="$(get_public_ipv4 2>/dev/null || true)"
    [[ -z "${server}" ]] && return 1
    local userinfo="${method}:${password}"
    local encoded
    encoded="$(printf '%s' "${userinfo}" | base64 -w 0 | tr '+/' '-_' | tr -d '=')"
    local tag
    tag="$(url_encode "${name}")"
    echo "ss://${encoded}@${server}:${port}#${tag}"
}

###############################################################################
# iptables 流量统计
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
# 核心：单用户检查
###############################################################################

check_user() {
    local u="$1"
    local json
    json="$(get_user_json "${u}")"
    [[ -z "${json}" ]] && return 0

    local port created_at expire limit used used_total
    local enabled reason
    local last_cycle_index last_ipt_tcp last_ipt_udp
    local now idx cur_tcp cur_udp d_tcp d_udp

    port="$(jq -r '.port' <<<"${json}")"
    created_at="$(jq -r '.created_at // 0' <<<"${json}")"
    expire="$(jq -r '.expire // 0' <<<"${json}")"
    limit="$(jq -r '.limit // 0' <<<"${json}")"
    used="$(jq -r '.used // 0' <<<"${json}")"
    used_total="$(jq -r '.used_total // 0' <<<"${json}")"
    enabled="$(jq -r '(.enabled // true)' <<<"${json}")"
    reason="$(jq -r '.disabled_reason // ""' <<<"${json}")"
    last_cycle_index="$(jq -r '.last_cycle_index // 0' <<<"${json}")"
    last_ipt_tcp="$(jq -r '.last_ipt_tcp // 0' <<<"${json}")"
    last_ipt_udp="$(jq -r '.last_ipt_udp // 0' <<<"${json}")"

    [[ "${created_at}" =~ ^[0-9]+$ ]] || created_at=0
    [[ "${expire}" =~ ^[0-9]+$ ]] || expire=0
    [[ "${limit}" =~ ^[0-9]+$ ]] || limit=0
    [[ "${used}" =~ ^[0-9]+$ ]] || used=0
    [[ "${used_total}" =~ ^[0-9]+$ ]] || used_total=0
    [[ "${last_cycle_index}" =~ ^[0-9]+$ ]] || last_cycle_index=0
    [[ "${last_ipt_tcp}" =~ ^[0-9]+$ ]] || last_ipt_tcp=0
    [[ "${last_ipt_udp}" =~ ^[0-9]+$ ]] || last_ipt_udp=0

    now="$(now_ts)"

    # 1) 过期检查：expire > 0 才判断（expire=0 表示永久）
    if (( expire > 0 && now >= expire )); then
        if [[ "${enabled}" == "true" || "${reason}" != "expired" ]]; then
            remove_port_rules "${port}"
            add_block_rules "${port}"
            update_user_field_json "${u}" '.enabled = false | .disabled_reason = "expired"'
        fi
        return 0
    fi

    # 2) 周期推进：永久用户（expire=0）不做周期重置，只累积
    if (( expire > 0 )); then
        idx="$(current_cycle_index "${created_at}" "${now}")"
        if (( idx > last_cycle_index )); then
            used=0
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
    fi

    # 3) 增量累加
    cur_tcp="$(read_chain_bytes "$(in_chain "${port}")")"
    cur_udp="$(read_chain_bytes "$(out_chain "${port}")")"

    if (( cur_tcp >= last_ipt_tcp )); then
        d_tcp=$(( cur_tcp - last_ipt_tcp ))
    else
        d_tcp=${cur_tcp}
    fi
    if (( cur_udp >= last_ipt_udp )); then
        d_udp=$(( cur_udp - last_ipt_udp ))
    else
        d_udp=${cur_udp}
    fi

    used=$(( used + d_tcp + d_udp ))
    used_total=$(( used_total + d_tcp + d_udp ))
    last_ipt_tcp="${cur_tcp}"
    last_ipt_udp="${cur_udp}"

    # 4) 超限封禁
    if [[ "${enabled}" == "true" && "${reason}" == "" ]] && (( limit > 0 )) && (( used >= limit )); then
        remove_port_rules "${port}"
        add_block_rules "${port}"
        enabled=false
        reason="traffic"
        warn "用户 ${u} 流量已超限：$(bytes_to_human "${used}") / $(bytes_to_human "${limit}")"
    fi

    update_user_field_json "${u}" \
        ".used = ${used} | .used_total = ${used_total} | .last_ipt_tcp = ${last_ipt_tcp} | .last_ipt_udp = ${last_ipt_udp} | .last_cycle_index = ${last_cycle_index} | .enabled = ${enabled} | .disabled_reason = \"${reason}\""
}

###############################################################################
# 重建所有 iptables 规则
###############################################################################

rebuild_iptables() {
    info "正在重建 iptables 流量统计规则..."
    local u port enabled reason
    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        port="$(jq -r --arg n "${u}" '.[]|select(.name==$n)|.port' "${USERS_FILE}" | head -n 1)"
        enabled="$(jq -r --arg n "${u}" '.[]|select(.name==$n)|(.enabled//true)' "${USERS_FILE}" | head -n 1)"
        reason="$(jq -r --arg n "${u}" '.[]|select(.name==$n)|(.disabled_reason//"")' "${USERS_FILE}" | head -n 1)"
        [[ -z "${port}" || "${port}" == "null" ]] && continue

        remove_port_rules "${port}"
        if [[ "${enabled}" == "true" && -z "${reason}" ]]; then
            add_traffic_rules "${port}"
        else
            add_block_rules "${port}"
        fi
    done < <(jq -r '.[].name' "${USERS_FILE}")
}

###############################################################################
# 生成 ssserver 的 config.json
###############################################################################

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
# Cron
###############################################################################

setup_cron() {
    cat > "${CRON_FILE}" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

*/5 * * * * root ${MANAGER_PATH} traffic-check >> ${LOG_FILE} 2>&1
EOF
    chmod 644 "${CRON_FILE}"
    systemctl enable cron 2>/dev/null || true
    systemctl restart cron 2>/dev/null || true
}

###############################################################################
# 定时任务执行的流量检查
###############################################################################

traffic_check() {
    init_dirs
    migrate_users

    if ! has_users; then
        stop_shadowsocks
        rm -f "${SS_CONFIG}"
        return 0
    fi

    local u
    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        check_user "${u}"
    done < <(jq -r '.[].name' "${USERS_FILE}")

    save_users
    generate_config

    if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        if has_users; then
            start_shadowsocks_if_needed >/dev/null 2>&1 || true
        fi
    fi
}

###############################################################################
# 端口检查
###############################################################################

port_exists() {
    local port="$1"
    jq -e --argjson p "${port}" 'any(.[]; (.port | tonumber) == $p)' "${USERS_FILE}" >/dev/null 2>&1
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
    owner="$(jq -r --argjson p "${port}" '.[] | select((.port|tonumber)==$p) | .name' "${USERS_FILE}" | head -n 1)"
    warn "端口 ${port} 已被用户 ${owner} 使用。"
    read -r -p "是否删除旧用户 ${owner} 并使用该端口？[y/N]: " ans
    if [[ "${ans}" =~ ^[Yy]$ ]]; then
        remove_port_rules "${port}"
        local tmp
        tmp="$(mktemp)"
        jq --arg n "${owner}" 'map(select(.name != $n))' "${USERS_FILE}" > "${tmp}"
        mv -f "${tmp}" "${USERS_FILE}"
        save_users
        ok "旧用户 ${owner} 已删除。"
        return 0
    fi
    return 1
}

###############################################################################
# 添加用户（★ 支持永久用户）
###############################################################################

add_user() {
    title "添加 Shadowsocks 用户"

    local name port password method limit_input limit
    local months_input months now expire next_reset

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

    # ★ 支持 0 / 无限 / 永久 等输入
    read -r -p "购买周期数（每个 30 天，填 0 或 无限 表示永久） [默认 1]： " months_input
    months_input="${months_input:-1}"
    if ! months="$(parse_periods "${months_input}")"; then
        err "周期数无效（应为非负整数，或输入“无限/永久”）。"
        return 1
    fi

    now="$(now_ts)"
    if (( months == 0 )); then
        # 永久用户：expire=0，periods=0
        expire=0
        next_reset=0
    else
        next_reset="$(calculate_next_reset "${now}" "${now}")"
        expire=$(( now + months * RESET_SECONDS ))
    fi

    local tmp
    tmp="$(mktemp)"
    jq \
        --arg name "${name}" \
        --arg password "${password}" \
        --arg method "${method}" \
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
                disabled_reason: ""
            }
        ]
        ' "${USERS_FILE}" > "${tmp}" || { rm -f "${tmp}"; err "写入用户失败。"; return 1; }
    mv -f "${tmp}" "${USERS_FILE}"
    chmod 600 "${USERS_FILE}"

    add_traffic_rules "${port}"
    generate_config
    start_shadowsocks_if_needed || return 1
    save_users

    local ip
    ip="$(get_public_ipv4 2>/dev/null || true)"

    echo
    ok "用户添加成功"
    line
    pad_right "用户名："   16; echo "${name}"
    pad_right "服务器："   16; echo "${ip:-获取失败}"
    pad_right "端口："     16; echo "${port}"
    pad_right "密码："     16; echo "${password}"
    pad_right "加密："     16; echo "${method}"
    if (( limit > 0 )); then
        pad_right "每月流量：" 16; echo "$(bytes_to_human "${limit}")"
    else
        pad_right "每月流量：" 16; echo "不限"
    fi
    # ★ 永久用户显示"永久"
    if (( months == 0 )); then
        pad_right "周期数："   16; echo "永久（不限时间）"
    else
        pad_right "周期数："   16; echo "${months}（每个 30 天）"
    fi
    pad_right "创建时间：" 16; echo "$(format_ts "${now}")"
    pad_right "到期时间：" 16; echo "$(format_expire "${expire}")"
    line
    if [[ -n "${ip}" ]]; then
        echo "ss:// 导入链接："
        generate_ss_link "${port}" "${password}" "${method}" "${name}" "${ip}"
    else
        warn "无法自动获取公网 IPv4，请稍后在用户详情中查看。"
    fi
    echo
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

    local tmp
    tmp="$(mktemp)"
    jq --arg n "${name}" 'map(select(.name != $n))' "${USERS_FILE}" > "${tmp}"
    mv -f "${tmp}" "${USERS_FILE}"
    save_users

    if ! has_users; then
        stop_shadowsocks
        rm -f "${SS_CONFIG}"
        ok "用户已删除，已无用户，Shadowsocks-Rust 已停止。"
        return
    fi

    rebuild_iptables
    generate_config
    start_shadowsocks_if_needed
    ok "用户 ${name} 已删除。"
}

###############################################################################
# 重置单用户本周期流量
###############################################################################

reset_user_traffic() {
    title "重置用户本周期流量"
    local name
    read -r -p "请输入用户名： " name
    [[ -z "${name}" ]] && return

    local json
    json="$(get_user_json "${name}")"
    [[ -z "${json}" ]] && { err "用户不存在。"; return 1; }

    local expire port now
    expire="$(jq -r '.expire // 0' <<<"${json}")"
    port="$(jq -r '.port' <<<"${json}")"
    now="$(now_ts)"

    # expire>0 才判断是否到期（expire=0 永久）
    if (( expire > 0 && now >= expire )); then
        warn "该用户账号已到期，reset 不会恢复。请使用「续费」功能。"
        return 1
    fi

    remove_port_rules "${port}"
    add_traffic_rules "${port}"

    update_user_field_json "${name}" \
        '.used = 0 | .last_ipt_tcp = 0 | .last_ipt_udp = 0 | .enabled = true | .disabled_reason = ""'

    save_users
    generate_config
    start_shadowsocks_if_needed

    ok "用户 ${name} 本周期流量已重置。"
    local created_at
    created_at="$(jq -r --arg n "${name}" '.[]|select(.name==$n)|.created_at' "${USERS_FILE}" | head -n 1)"
    info "created_at 未改变：$(format_ts "${created_at}")"
}

###############################################################################
# 用户续费（★ 永久用户不参与）
###############################################################################

renew_user() {
    title "续费用户（增加周期）"
    local name
    read -r -p "请输入用户名： " name
    [[ -z "${name}" ]] && return

    local json
    json="$(get_user_json "${name}")"
    [[ -z "${json}" ]] && { err "用户不存在。"; return 1; }

    local expire periods port created_at now base n new_expire new_periods new_idx
    expire="$(jq -r '.expire // 0' <<<"${json}")"
    periods="$(jq -r '.periods // 1' <<<"${json}")"
    port="$(jq -r '.port' <<<"${json}")"
    created_at="$(jq -r '.created_at // 0' <<<"${json}")"
    now="$(now_ts)"

    # ★ 永久用户直接跳过
    if (( expire == 0 )); then
        warn "该用户为永久账号，无需续费。"
        return 0
    fi

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

    save_users
    generate_config
    start_shadowsocks_if_needed

    ok "用户 ${name} 续费完成。"
    pad_right "新到期时间：" 16; echo "$(format_ts "${new_expire}")"
    pad_right "新周期数："   16; echo "${new_periods}"
}

###############################################################################
# 重置全部用户流量
###############################################################################

reset_all_traffic() {
    title "重置全部用户流量"
    warn "将重置所有未过期用户的本周期流量，created_at 不变。"
    read -r -p "确定继续？输入 YES： " confirm
    [[ "${confirm}" == "YES" ]] || { echo "已取消。"; return; }

    local u now
    now="$(now_ts)"
    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        local json expire port
        json="$(get_user_json "${u}")"
        [[ -z "${json}" ]] && continue
        expire="$(jq -r '.expire // 0' <<<"${json}")"
        port="$(jq -r '.port' <<<"${json}")"

        # 只有 expire>0 且已过期才封禁；永久用户不受影响
        if (( expire > 0 && now >= expire )); then
            remove_port_rules "${port}"
            add_block_rules "${port}"
            update_user_field_json "${u}" '.enabled = false | .disabled_reason = "expired"'
            continue
        fi

        remove_port_rules "${port}"
        add_traffic_rules "${port}"
        update_user_field_json "${u}" \
            '.used = 0 | .last_ipt_tcp = 0 | .last_ipt_udp = 0 | .enabled = true | .disabled_reason = ""'
    done < <(jq -r '.[].name' "${USERS_FILE}")

    save_users
    generate_config
    start_shadowsocks_if_needed
    ok "所有未过期用户流量已重置。"
}

###############################################################################
# 用户列表（★ 永久用户显示"永久"）
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

    local u
    while IFS= read -r u; do
        local json port used limit expire enabled reason current total status used_text limit_text
        json="$(get_user_json "${u}")"
        port="$(jq -r '.port' <<<"${json}")"
        used="$(jq -r '.used // 0' <<<"${json}")"
        limit="$(jq -r '.limit // 0' <<<"${json}")"
        expire="$(jq -r '.expire // 0' <<<"${json}")"
        enabled="$(jq -r '(.enabled // true)' <<<"${json}")"
        reason="$(jq -r '.disabled_reason // ""' <<<"${json}")"

        [[ "${used}" =~ ^[0-9]+$ ]] || used=0
        current="$(get_port_traffic "${port}")"
        [[ "${current}" =~ ^[0-9]+$ ]] || current=0
        total=$(( used + current ))

        if [[ "${enabled}" == "true" ]]; then status="正常"
        elif [[ "${reason}" == "traffic" ]]; then status="流量超限"
        elif [[ "${reason}" == "expired" ]]; then status="已到期"
        else status="已禁用"; fi

        used_text="$(bytes_to_human "${total}")"
        (( limit > 0 )) && limit_text="$(bytes_to_human "${limit}")" || limit_text="不限"

        pad_right "${u}"          "${W_NAME}";   printf '  '
        pad_right "${port}"       "${W_PORT}";   printf '  '
        pad_right "${used_text}"  "${W_USED}";   printf '  '
        pad_right "${limit_text}" "${W_LIMIT}";  printf '  '
        pad_right "$(format_expire "${expire}")" "${W_EXPIRE}"; printf '  '
        pad_right "${status}"     "${W_STATUS}"
        echo
    done < <(jq -r '.[].name' "${USERS_FILE}")
    echo
}

###############################################################################
# 用户详情（★ 永久用户显示"永久"）
###############################################################################

show_user() {
    title "用户详情"
    local name
    read -r -p "请输入用户名： " name
    [[ -z "${name}" ]] && return

    local json
    json="$(get_user_json "${name}")"
    [[ -z "${json}" ]] && { err "用户不存在。"; return 1; }

    local port password method limit used expire periods enabled reason
    local current total ip percent used_total
    port="$(jq -r '.port' <<<"${json}")"
    password="$(jq -r '.password' <<<"${json}")"
    method="$(jq -r '.method // "aes-256-gcm"' <<<"${json}")"
    limit="$(jq -r '.limit // 0' <<<"${json}")"
    used="$(jq -r '.used // 0' <<<"${json}")"
    expire="$(jq -r '.expire // 0' <<<"${json}")"
    periods="$(jq -r '.periods // 0' <<<"${json}")"
    enabled="$(jq -r '(.enabled // true)' <<<"${json}")"
    reason="$(jq -r '.disabled_reason // ""' <<<"${json}")"
    used_total="$(jq -r '.used_total // 0' <<<"${json}")"

    current="$(get_port_traffic "${port}")"
    [[ "${current}" =~ ^[0-9]+$ ]] || current=0
    [[ "${used}" =~ ^[0-9]+$ ]] || used=0
    total=$(( used + current ))

    ip="$(get_public_ipv4 2>/dev/null || true)"

    echo
    pad_right "用户名："   16; echo "${name}"
    pad_right "服务器："   16; echo "${ip:-获取失败}"
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

    # ★ 永久用户显示"永久"
    if (( expire == 0 )); then
        pad_right "周期数："   16; echo "永久（不限时间）"
    else
        pad_right "周期数："   16; echo "${periods}（每个 30 天）"
    fi

    if (( expire > 0 )); then
        pad_right "到期时间：" 16; echo "$(format_ts "${expire}")"
        pad_right "剩余："     16; echo "$(remaining_time "${expire}")"
    else
        pad_right "到期时间：" 16; echo "永久"
        pad_right "剩余："     16; echo "永久"
    fi

    pad_right "状态：" 16
    if [[ "${enabled}" == "true" ]]; then echo "正常"
    elif [[ "${reason}" == "traffic" ]]; then echo "流量超限"
    elif [[ "${reason}" == "expired" ]]; then echo "已到期"
    else echo "已禁用"; fi

    line
    if [[ -n "${ip}" ]]; then
        echo "ss:// 导入链接："
        generate_ss_link "${port}" "${password}" "${method}" "${name}" "${ip}"
    else
        warn "无法获取服务器公网 IPv4。"
    fi
    echo
}

###############################################################################
# 导出全部用户 ss:// 链接
###############################################################################

export_all_links() {
    title "Shadowsocks 用户导入链接"
    has_users || { warn "当前没有用户。"; return; }

    local server_ip
    server_ip="$(get_public_ipv4 2>/dev/null || true)"
    [[ -z "${server_ip}" ]] && { err "无法获取服务器公网 IPv4。"; return 1; }

    echo "服务器 IP：${server_ip}"
    echo

    local u
    while IFS= read -r u; do
        [[ -z "${u}" ]] && continue
        local json port password method enabled reason status
        json="$(get_user_json "${u}")"
        port="$(jq -r '.port' <<<"${json}")"
        password="$(jq -r '.password' <<<"${json}")"
        method="$(jq -r '.method // "aes-256-gcm"' <<<"${json}")"
        enabled="$(jq -r '(.enabled // true)' <<<"${json}")"
        reason="$(jq -r '.disabled_reason // ""' <<<"${json}")"

        if [[ "${enabled}" == "true" ]]; then status="正常"
        elif [[ "${reason}" == "traffic" ]]; then status="流量超限"
        elif [[ "${reason}" == "expired" ]]; then status="已到期"
        else status="已禁用"; fi

        line
        pad_right "用户：" 12; echo "${u}"
        pad_right "状态：" 12; echo "${status}"
        pad_right "端口：" 12; echo "${port}"
        echo
        generate_ss_link "${port}" "${password}" "${method}" "${u}" "${server_ip}"
        echo
    done < <(jq -r '.[].name' "${USERS_FILE}")
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

###############################################################################
# 更新 Shadowsocks-Rust
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

###############################################################################
# 首次安装全流程
###############################################################################

install_all() {
    title "Shadowsocks-Rust 多用户管理器 · 首次安装"
    install_dependencies
    check_dependencies
    init_dirs
    migrate_users

    if [[ ! -x "${BIN_PATH}" ]]; then
        install_shadowsocks
    else
        info "检测到已有 Shadowsocks-Rust，跳过重复安装。"
    fi

    create_systemd_service
    setup_cron

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

###############################################################################
# 卸载
###############################################################################

uninstall() {
    title "卸载 Shadowsocks-Rust 多用户管理器"
    warn "此操作将删除 Shadowsocks-Rust、所有用户配置、systemd、Cron、iptables 规则和 ss-manager。"
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
        echo -e "${BOLD}├──────────────────────── 服务与维护 ──────────────────────────┤${RESET}"
        echo -e "  ${GREEN}9${RESET}) 查看服务状态                ${GREEN}10${RESET}) 查看日志"
        echo -e "  ${GREEN}11${RESET}) 更新 Shadowsocks-Rust       ${GREEN}12${RESET}) 手动流量检查"
        echo -e "  ${GREEN}13${RESET}) 重建 iptables 规则          ${GREEN}14${RESET}) 卸载"
        echo -e "${BOLD}└──────────────────────────────────────────────────────────────┘${RESET}"
        echo -e "  ${RED}0${RESET}) 退出"
        echo

        local choice
        read -r -p "请选择 [0-14]： " choice

        case "${choice}" in
            1)  add_user;              read -r -p "按回车继续..." ;;
            2)  delete_user;           read -r -p "按回车继续..." ;;
            3)  list_users;            read -r -p "按回车继续..." ;;
            4)  show_user;             read -r -p "按回车继续..." ;;
            5)  reset_user_traffic;    read -r -p "按回车继续..." ;;
            6)  renew_user;            read -r -p "按回车继续..." ;;
            7)  reset_all_traffic;     read -r -p "按回车继续..." ;;
            8)  export_all_links;      read -r -p "按回车继续..." ;;
            9)  service_status;        read -r -p "按回车继续..." ;;
            10) show_logs;             read -r -p "按回车继续..." ;;
            11) update_shadowsocks;    read -r -p "按回车继续..." ;;
            12) traffic_check; ok "流量检查完成。"; read -r -p "按回车继续..." ;;
            13) rebuild_iptables; ok "iptables 重建完成。"; read -r -p "按回车继续..." ;;
            14) uninstall ;;
            0)  clear; exit 0 ;;
            *)  warn "无效选项。"; sleep 1 ;;
        esac
    done
}

###############################################################################
# 命令行入口
###############################################################################

case "${1:-}" in
    traffic-check)
        check_root
        init_dirs
        check_dependencies
        migrate_users
        traffic_check
        exit 0
        ;;
    add)
        check_root
        init_dirs
        check_dependencies
        migrate_users
        add_user
        exit 0
        ;;
    list)
        check_root
        init_dirs
        check_dependencies
        migrate_users
        list_users
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
    migrate_users

    if [[ ! -x "${BIN_PATH}" || ! -f "${SERVICE_FILE}" ]]; then
        install_all
    else
        create_systemd_service
        setup_cron
        if has_users; then
            generate_config
            rebuild_iptables
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

#!/usr/bin/env bash
# 入口口令的来源与幂等性（`scripts/init-cred.sh` 的 ④ 段）。
#
#   ./dev/tests/init-cred-secret.test.sh
#
# 在临时目录里复制一份 `scripts/`，用**假 gops** 提供密钥，所以不碰真实栈根、
# 不需要 gops，也不联网。验证六件事：
#   ① 缺密钥文件 → 失败（不能拿旧 htpasswd 顶上去）；
#   ② 有文件但缺键 → 失败，并给出补密钥的命令；
#   ③ 有键 → htpasswd 的 apr1 与密钥对得上，模式 640，且不含明文；
#   ④ 同一密钥重跑不重写（mtime 不变）；
#   ⑤ 换密钥 → 重写且仍对得上，旧口令失效；
#   ⑥ 删掉密钥文件但留着 htpasswd → 仍然失败（不静默沿用旧口令）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_REAL="$(cd "${HERE}/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

STACK="${TMP}/stack"
SEC_FILE="${STACK}/.wist/sec-value.yml"
HTPASSWD="${STACK}/configs/web/htpasswd"
mkdir -p "${STACK}" "${TMP}/bin"
cp -R "${STACK_REAL}/scripts" "${STACK}/scripts"

# ── 假 gops：只实现 `sec list` / `sec get --show`，语义与真的一致
#    （文件不存在 → 非零；键不存在 → 非零；成功 → 只打值）。
cat >"${TMP}/bin/gops" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
sec_file="${FAKE_SEC_FILE:?}"
case "${1:-} ${2:-}" in
  "sec list")
    [[ -f "${sec_file}" ]] || {
      echo "sys-prj.yml 声明了 secrets.file，但文件不存在" >&2
      exit 1
    }
    echo '{"file":"'"${sec_file}"'","items":[]}'
    ;;
  "sec get")
    shift 2
    [[ "${1:-}" == "--show" ]] && shift
    [[ -f "${sec_file}" ]] || exit 1
    # 只认 `key: "value"` 这一种写法（够本测试用）。
    value="$(sed -n "s/^${1}:[[:space:]]*//p" "${sec_file}" | tail -n 1)"
    value="${value%\"}"
    value="${value#\"}"
    [[ -n "${value}" ]] || exit 1
    printf '%s\n' "${value}"
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "${TMP}/bin/gops"
export PATH="${TMP}/bin:${PATH}"
export FAKE_SEC_FILE="${SEC_FILE}"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok  %s\n' "$*"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }

run_init() { ( cd "${STACK}" && ./scripts/init-cred.sh configs/cred example.test ); }

mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

mode_of() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

# htpasswd 里存的那一行和给定口令是否一致（重算 apr1，salt 取自文件）。
htpasswd_matches() {
  local line salt
  line="$(sed -n 's/^admin://p' "${HTPASSWD}" | head -n 1)"
  [[ -n "${line}" ]] || return 1
  salt="$(printf '%s' "${line}" | awk -F'\$' '{print $3}')"
  [[ -n "${salt}" ]] || return 1
  [[ "$(openssl passwd -apr1 -salt "${salt}" "$1")" == "${line}" ]]
}

echo "① 缺密钥文件 → 必须失败"
out="$(run_init 2>&1)"; rc=$?
[[ ${rc} -ne 0 ]] && ok "退出码 ${rc}" || no "应当失败，实际退出码 0"
grep -q '密钥文件不可用' <<<"${out}" && ok "提示指向密钥文件" || no "缺少「密钥文件不可用」提示"
[[ ! -f "${HTPASSWD}" ]] && ok "没有生成 htpasswd" || no "不该生成 htpasswd"

echo "② 有文件但缺键 → 必须失败，并给出补密钥的命令"
mkdir -p "${STACK}/.wist"
printf 'something_else: "x"\n' >"${SEC_FILE}"
out="$(run_init 2>&1)"; rc=$?
[[ ${rc} -ne 0 ]] && ok "退出码 ${rc}" || no "应当失败，实际退出码 0"
grep -q '入口口令没有来源' <<<"${out}" && ok "提示「入口口令没有来源」" || no "缺少错误提示"
grep -q 'cred_web_password' <<<"${out}" && ok "给出缺失的键名" || no "没提键名"

echo "③ 有键 → 写出可用的 apr1 摘要"
PW1="$(openssl rand -hex 12)"
printf 'cred_web_password: "%s"\n' "${PW1}" >"${SEC_FILE}"
chmod 600 "${SEC_FILE}"
out="$(run_init 2>&1)"; rc=$?
if [[ ${rc} -eq 0 ]]; then ok "退出码 0"; else no "应当成功，实际 ${rc}"; printf '%s\n' "${out}" >&2; fi
htpasswd_matches "${PW1}" && ok "apr1 与密钥对得上" || no "apr1 与密钥不符"
[[ "$(mode_of "${HTPASSWD}")" == "640" ]] && ok "模式 640" || no "模式应为 640（实际 $(mode_of "${HTPASSWD}")）"
grep -q "${PW1}" "${HTPASSWD}" 2>/dev/null && no "明文口令不应出现在 htpasswd 里" || ok "htpasswd 里没有明文"

echo "④ 同一密钥重跑 → 不重写（mtime 不变）"
before="$(mtime "${HTPASSWD}")"
sleep 1
out="$(run_init 2>&1)"
[[ "$(mtime "${HTPASSWD}")" == "${before}" ]] && ok "文件未被重写" || no "文件被无谓重写"
grep -q '一致，跳过' <<<"${out}" && ok "输出「一致，跳过」" || no "缺少「一致，跳过」"

echo "⑤ 换密钥 → 重写且仍对得上"
PW2="$(openssl rand -hex 12)"
printf 'cred_web_password: "%s"\n' "${PW2}" >"${SEC_FILE}"
out="$(run_init 2>&1)"; rc=$?
[[ ${rc} -eq 0 ]] && ok "退出码 0" || no "应当成功，实际 ${rc}"
htpasswd_matches "${PW2}" && ok "新口令生效" || no "新口令未生效"
if htpasswd_matches "${PW1}"; then no "旧口令仍然有效"; else ok "旧口令已失效"; fi

echo "⑥ 删掉密钥文件但留 htpasswd → 仍然必须失败"
rm -f "${SEC_FILE}"
before="$(mtime "${HTPASSWD}")"
out="$(run_init 2>&1)"; rc=$?
[[ ${rc} -ne 0 ]] && ok "退出码 ${rc}" || no "应当失败，实际退出码 0"
[[ "$(mtime "${HTPASSWD}")" == "${before}" ]] && ok "htpasswd 未被动过" || no "htpasswd 被改了"

echo
printf '通过 %d，失败 %d\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]

#!/usr/bin/env bash
# 页面口令的来源（`scripts/init-cred.sh` 的 ④ 段）。
#
#   ./dev/tests/init-cred-password.test.sh
#
# 人机面的口令**不在这一层验**（那是 `wist-cred` 的事，见它的 token 模式与单测）；
# 这里只钉住“口令有没有来源”：缺了就**早一步**失败，而不是等 `docker compose up`
# 之后 cred 起不来。在临时目录里复制一份 `scripts/`，用**假 gops** 提供密钥，
# 所以不碰真实栈根、不需要 gops，也不联网。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_REAL="$(cd "${HERE}/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

STACK="${TMP}/stack"
SEC_FILE="${STACK}/.wist/sec-value.yml"
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
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }

run_init() { ( cd "${STACK}" && ./scripts/init-cred.sh configs/cred example.test ); }

echo "① 缺密钥文件 → localize 必须失败，且把能照抄的命令给出来"
out="$(run_init 2>&1)"; rc=$?
[[ ${rc} -ne 0 ]] && ok "退出码 ${rc}" || no "应当失败，实际退出码 0"
grep -q '密钥文件不存在' <<<"${out}" && ok "提示「密钥文件不存在」" || no "缺少「密钥文件不存在」提示"
# 新站点首次部署就靠这段命令：缺了就变成“报错但不知道敲什么”
grep -q 'gops sec fix' <<<"${out}" && ok "给出 gops sec fix" || no "没提权限收敛"
grep -q 'cred_web_password' <<<"${out}" && ok "给出建口令的命令" || no "没给建口令的命令"
grep -q 'usermod -aG 999' <<<"${out}" && ok "给出属组前置（Linux）" || no "没提属组"

echo "② 有文件但缺键 → 必须失败，并给出补密钥的命令"
mkdir -p "${STACK}/.wist"
printf 'something_else: "x"\n' >"${SEC_FILE}"
out="$(run_init 2>&1)"; rc=$?
[[ ${rc} -ne 0 ]] && ok "退出码 ${rc}" || no "应当失败，实际退出码 0"
grep -q '页面口令没有来源' <<<"${out}" && ok "提示「页面口令没有来源」" || no "缺少错误提示"
grep -q 'cred_web_password' <<<"${out}" && ok "给出缺失的键名" || no "没提键名"

echo "③ 有键 → 通过，且口令不落任何产物"
printf 'cred_web_password: "%s"\n' "$(openssl rand -hex 12)" >"${SEC_FILE}"
chmod 600 "${SEC_FILE}"
out="$(run_init 2>&1)"; rc=$?
if [[ ${rc} -eq 0 ]]; then ok "退出码 0"; else no "应当成功，实际 ${rc}"; printf '%s\n' "${out}" >&2; fi
grep -q '页面口令已就位' <<<"${out}" && ok "说明口令已就位（不回显）" || no "缺少确认输出"
# 关键不变式：**不再生成 htpasswd** —— 认证不在入口那一层了。
[[ ! -f "${STACK}/configs/web/htpasswd" ]] && ok "没有生成 htpasswd" || no "不该生成 htpasswd"

echo "④ 幂等：同一密钥重跑仍通过"
out="$(run_init 2>&1)"; rc=$?
[[ ${rc} -eq 0 ]] && ok "退出码 0" || no "重跑应当成功，实际 ${rc}"

echo
printf '通过 %d，失败 %d\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]

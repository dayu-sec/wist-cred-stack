#!/usr/bin/env bash
# 改名守卫：`CRED_REGISTRY` 已改名 `WIST_SPC`（与 wist-gateway-stack 同名同义）。
#
#   ./dev/tests/vars-rename-guard.test.sh
#
# 为什么钉：gops 对 values 里的**未知键是静默接受的** —— 旧键留着不会报错，
# `${WIST_SPC}` 会默默取默认值（ghcr），而现场以为在拉 TCR。改名必须在 localize 当场拦住。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_REAL="$(cd "${HERE}/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

STACK="${TMP}/stack"
SEC_FILE="${STACK}/.wist/sec-value.yml"
mkdir -p "${STACK}" "${TMP}/bin"
cp -R "${STACK_REAL}/scripts" "${STACK}/scripts"

cat >"${TMP}/bin/gops" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
sec_file="${FAKE_SEC_FILE:?}"
case "${1:-} ${2:-}" in
  "sec list")
    [[ -f "${sec_file}" ]] || exit 1
    echo '{"file":"'"${sec_file}"'","items":[]}'
    ;;
  "sec get")
    shift 2
    [[ "${1:-}" == "--show" ]] && shift
    value="$(sed -n "s/^${1}:[[:space:]]*//p" "${sec_file}" | tail -n 1)"
    value="${value%\"}"; value="${value#\"}"
    [[ -n "${value}" ]] || exit 1
    printf '%s\n' "${value}"
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "${TMP}/bin/gops"
export PATH="${TMP}/bin:${PATH}"
export FAKE_SEC_FILE="${SEC_FILE}"

mkdir -p "${STACK}/.wist"
printf 'cred_web_password: "test-only"\n' >"${SEC_FILE}"
chmod 600 "${SEC_FILE}"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }

run_init() { ( cd "${STACK}" && ./scripts/init-cred.sh configs/cred example.test ); }

echo "① values 里还留着旧键 CRED_REGISTRY → localize 必须失败"
out="$(CRED_REGISTRY=ghcr.io/dayu-sec run_init 2>&1)"; rc=$?
[[ ${rc} -ne 0 ]] && ok "退出码 ${rc}" || no "应当失败，实际 0"
grep -q 'WIST_SPC' <<<"${out}" && ok "提示指向新键 WIST_SPC" || no "没提新键"
grep -q 'CRED_REGISTRY' <<<"${out}" && ok "点名旧键，便于现场搜索" || no "没点旧键"

echo "② 不设旧键 → 正常通过"
out="$(run_init 2>&1)"; rc=$?
if [[ ${rc} -eq 0 ]]; then ok "退出码 0"; else no "应当成功，实际 ${rc}"; printf '%s\n' "${out}" >&2; fi

echo "③ 模板/示例里不应再出现旧变量名（防回潮）"
if grep -rq 'CRED_REGISTRY' \
  "${STACK_REAL}/sys/docker-compose.yml" \
  "${STACK_REAL}/.env.example" \
  "${STACK_REAL}/sys/setting/vars.yml"; then
  no "仍在引用 CRED_REGISTRY"
else
  ok "compose / .env.example / vars.yml 已全部改名"
fi

echo
printf '通过 %d，失败 %d\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]

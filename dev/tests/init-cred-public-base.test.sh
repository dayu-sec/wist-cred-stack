#!/usr/bin/env bash
# 对外基址（`scripts/init-cred.sh` 的 ② 段）：
#
#   ./dev/tests/init-cred-public-base.test.sh
#
# 接入脚本里的「交 CSR」地址是 cred 按 `[server].public_base_url` 拼出来的**绝对地址**。
# 入口 nginx 默认的 `$host` 不带端口 —— 2026-11-03 现场就是这里丢了 `:4444`，
# 机器把 CSR 打到 443（OrbStack 的入口）拿到空体 404，登记怎么都过不去。
# 所以钉住三件事：端口照写、443 不写、模板里确实有那个占位符。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_REAL="$(cd "${HERE}/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

STACK="${TMP}/stack"
SEC_FILE="${STACK}/.wist/sec-value.yml"
mkdir -p "${STACK}" "${TMP}/bin" "${STACK}/sys/configs/cred"
cp -R "${STACK_REAL}/scripts" "${STACK}/scripts"
cp "${STACK_REAL}/sys/configs/cred/wist-cred.toml.tpl" "${STACK}/sys/configs/cred/"

# 假 gops：只实现 `sec list` / `sec get --show`（与 init-cred-password 同一套）。
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

mkdir -p "${STACK}/.wist"
printf 'cred_web_password: "test-only"\n' >"${SEC_FILE}"
chmod 600 "${SEC_FILE}"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }

# 每次重跑都清掉旧值，避免“上一轮的值留在文件里”让断言假通过。
run_init() {
  rm -f "${STACK}/configs/cred/wist-cred.value.json"
  ( cd "${STACK}" && WEB_HOST_PORT="$1" ./scripts/init-cred.sh configs/cred example.test )
}
rendered_base() {
  sed -n 's/.*"public_base_url": *"\([^"]*\)".*/\1/p' \
    "${STACK}/configs/cred/wist-cred.value.json" | head -n 1
}

echo "① 非 443 端口 → 必须照写（丢掉端口就是那个 404）"
if run_init 4444 >/dev/null 2>&1; then ok "init-cred 退出码 0"; else no "init-cred 应当成功"; fi
base="$(rendered_base)"
[[ "${base}" == "https://example.test:4444" ]] && ok "public_base_url=${base}" \
  || no "期望 https://example.test:4444，实际 '${base}'"

echo "② 443 → 不写端口（写出来也不算错，但不写更干净）"
run_init 443 >/dev/null 2>&1
base="$(rendered_base)"
[[ "${base}" == "https://example.test" ]] && ok "public_base_url=${base}" \
  || no "期望 https://example.test，实际 '${base}'"

echo "③ 未设 WEB_HOST_PORT → 按 443 处理"
run_init "" >/dev/null 2>&1
base="$(rendered_base)"
[[ "${base}" == "https://example.test" ]] && ok "public_base_url=${base}" \
  || no "期望 https://example.test，实际 '${base}'"

echo "④ 渲染值必须是合法 JSON（多一个引号就会让 cred 拒启）"
if command -v python3 >/dev/null 2>&1; then
  run_init 4444 >/dev/null 2>&1
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "${STACK}/configs/cred/wist-cred.value.json" 2>/dev/null; then
    ok "value.json 可解析"
  else
    no "value.json 不是合法 JSON"
  fi
else
  ok "跳过（没有 python3）"
fi

echo "⑤ 模板必须真的用上这个渲染值"
grep -q '^public_base_url = "{{public_base_url}}"$' "${STACK}/sys/configs/cred/wist-cred.toml.tpl" \
  && ok "模板有 {{public_base_url}}" || no "模板缺少 public_base_url 占位符"

# 兜底：即使现场没配 public_base_url（仍靠请求头推），入口也不能把端口剥了。
echo "⑥ 反代的 /enroll/ 必须转发 \$http_host（\$host 会剥端口）"
enroll_block="$(awk '/location \/enroll\/ \{/{f=1} f{print} f&&/^[[:space:]]*\}/{exit}' \
  "${STACK_REAL}/sys/configs/web/nginx.conf.tpl")"
grep -Eq 'Host[[:space:]]+\$http_host' <<<"${enroll_block}" \
  && ok "/enroll/ 用 \$http_host" || no "/enroll/ 没有用 \$http_host"
if grep -Eq 'Host[[:space:]]+\$host;' <<<"${enroll_block}"; then
  no "/enroll/ 里出现了 \$host（会丢端口）"
else
  ok "/enroll/ 没有 \$host"
fi

echo
printf '通过 %d，失败 %d\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]

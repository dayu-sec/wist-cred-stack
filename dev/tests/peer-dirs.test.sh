#!/usr/bin/env bash
# 材料目录声明（`CRED_PEER_DIRS` → `cred.toml` 的 `peer_dirs`）：
#
#   ./dev/tests/peer-dirs.test.sh
#
# 为什么要有这个变量：接入命令是在**对方的栈**里跑的，落点取决于那个栈的目录布局
# （`wist-center-stack` 是 `identity/center/cred`，不是 `identity/<peer>`）。猜不出来，
# 只能拦 —— 而拦一次就烧一张一次性券。这里钉住三件事：
#   ① 写错格式在 **localize 阶段**就失败（别等到 cred 启动才报）；
#   ② 合法值原样进渲染值，模板会用上；
#   ③ 空值 = 不声明（不能渲染出 `peer_dirs = ""` 之外的垃圾）。
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

# 假 gops：只实现 `sec list` / `sec get --show`（与其它测试同一套）。
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

run_init() {
  rm -f "${STACK}/configs/cred/wist-cred.value.json"
  ( cd "${STACK}" && CRED_PEER_DIRS="$1" ./scripts/init-cred.sh configs/cred example.test )
}
rendered() {
  sed -n 's/.*"peer_dirs": *"\([^"]*\)".*/\1/p' \
    "${STACK}/configs/cred/wist-cred.value.json" | head -n 1
}

echo "① 合法声明 → 原样进渲染值"
if run_init 'wist-center=./identity/center/cred,wist-ingest=./identity/ingest/cred' >/dev/null 2>&1; then
  ok "init-cred 退出码 0"
else
  no "init-cred 应当成功"
fi
got="$(rendered)"
[[ "${got}" == "wist-center=./identity/center/cred,wist-ingest=./identity/ingest/cred" ]] \
  && ok "peer_dirs=${got}" || no "渲染值不对：'${got}'"

echo "② 格式错误 → localize 阶段就失败（别等服务起来才报）"
for bad in 'wist-center' 'wist-center=' '=./identity/center/cred' 'a=./x,,b'; do
  if run_init "${bad}" >/dev/null 2>&1; then
    no "'${bad}' 应当被拒绝"
  else
    ok "'${bad}' 被拒绝"
  fi
done

echo "③ 空值 → 渲染成空串（不是 'null' / 不是残留上一轮的值）"
run_init '' >/dev/null 2>&1
got="$(rendered)"
[[ -z "${got}" ]] && ok "peer_dirs 为空" || no "期望空串，实际 '${got}'"

echo "④ 渲染值必须是合法 JSON"
if command -v python3 >/dev/null 2>&1; then
  run_init 'wist-center=./identity/center/cred' >/dev/null 2>&1
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "${STACK}/configs/cred/wist-cred.value.json" 2>/dev/null; then
    ok "value.json 可解析"
  else
    no "value.json 不是合法 JSON"
  fi
else
  ok "跳过（没有 python3）"
fi

echo "⑤ 模板真的用上了这个渲染值，而且是**不过 HTML 转义**的那种"
# `{{x}}` 会把 `=` 转成 `&#x3D;`（handlebars 默认 HTML 转义）—— 值里带 `=` 时
# 渲染出来就是错的，而且看起来“很像是配了”。实测踩过，所以连写法一起钉。
grep -q '^peer_dirs = "{{{peer_dirs}}}"$' \
  "${STACK}/sys/configs/cred/wist-cred.toml.tpl" \
  && ok "模板用 {{{peer_dirs}}}（原始值）" || no "模板必须用三花括号，否则 '=' 被转义"

echo
printf '通过 %d，失败 %d\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]

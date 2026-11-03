#!/usr/bin/env bash
# 时区接线：`scripts/init-timezone.sh` 真的产出 zone 文件，且 compose 真的把它交给容器。
#
#   ./dev/tests/init-timezone.test.sh
#
# 为什么钉：`TZ` 变量本身**不保证生效** ——
#   * 只写 `TZ=Asia/Shanghai` 要求镜像自带 tzdata，索引不到时 glibc 静默回落 UTC；
#   * 只声明变量、compose 不挂载也不设 env，则变量形同虚设（本次改动前的状态）。
# 这里同时钉住「文件产出了」和「容器拿到了」两段。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_REAL="$(cd "${HERE}/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

STACK="${TMP}/stack"
mkdir -p "${STACK}/scripts"
cp "${STACK_REAL}/scripts/init-timezone.sh" "${STACK}/scripts/"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$*" >&2; }

echo "① 按 TZ 名称取 zone 文件"
out="$(TZ=Asia/Shanghai bash "${STACK}/scripts/init-timezone.sh" 2>&1)"; rc=$?
if [[ ${rc} -eq 0 ]]; then ok "退出码 0"; else no "应当成功，实际 ${rc}"; printf '%s\n' "${out}" >&2; fi
if [[ -s "${STACK}/configs/runtime/tz/localtime" ]]; then
  ok "产物 configs/runtime/tz/localtime 非空"
else
  no "没有产出 zone 文件"
fi
# 容器里那份必须是**文件**：`/etc/localtime` 在多数发行版上是符号链接，悬空链接等于没设。
if [[ -L "${STACK}/configs/runtime/tz/localtime" ]]; then
  no "产物是符号链接（应当是解引用后的实体文件）"
else
  ok "产物是实体文件（不是链接）"
fi

echo "② 幂等：第二次是 no-op"
out="$(TZ=Asia/Shanghai bash "${STACK}/scripts/init-timezone.sh" 2>&1)"
grep -q '已是最新' <<<"${out}" && ok "第二次提示「已是最新」" || no "第二次不是 no-op：${out}"

echo "③ 未知 TZ 名称 → 回落到宿主 /etc/localtime（不静默产出空文件）"
if [[ -e /etc/localtime ]]; then
  rm -f "${STACK}/configs/runtime/tz/localtime"
  out="$(TZ=Nope/Nowhere bash "${STACK}/scripts/init-timezone.sh" 2>&1)"; rc=$?
  if [[ ${rc} -eq 0 && -s "${STACK}/configs/runtime/tz/localtime" ]]; then
    ok "回落成功"
  else
    no "回落后没有产物（rc=${rc}）：${out}"
  fi
else
  ok "跳过（宿主没有 /etc/localtime）"
fi

echo "④ compose 必须把时区交给每个容器"
if command -v docker >/dev/null 2>&1; then
  rendered="$(cd "${STACK_REAL}" && docker compose --env-file .env.example \
    -f sys/docker-compose.yml --project-directory . config 2>/dev/null)"
else
  rendered="$(cat "${STACK_REAL}/sys/docker-compose.yml")"
fi
tz_env="$(grep -c 'TZ: :/etc/tz-runtime/localtime\|TZ: ":/etc/tz-runtime/localtime"' <<<"${rendered}")"
[[ "${tz_env}" -ge 2 ]] && ok "cred 与 web 都设了 TZ=:<file>（${tz_env} 处）" \
  || no "设了 TZ 的容器不足 2 个（${tz_env} 处）"
mounts="$(grep -c '/etc/tz-runtime' <<<"${rendered}")"
[[ "${mounts}" -ge 2 ]] && ok "时区数据挂到了容器（${mounts} 处）" \
  || no "时区数据没有挂进容器（${mounts} 处）"

echo "⑤ .env.example 必须能提供 TZ_RUNTIME_DIR（否则 compose 插值失败）"
grep -q '^TZ_RUNTIME_DIR=' "${STACK_REAL}/.env.example" \
  && ok ".env.example 有 TZ_RUNTIME_DIR" || no ".env.example 缺 TZ_RUNTIME_DIR"

echo
printf '通过 %d，失败 %d\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]

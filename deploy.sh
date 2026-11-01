#!/usr/bin/env bash
# 在 Unikraft Cloud 上创建/更新一个监控实例。
# 全部走 REST API（metro 端点），不依赖 CLI 的子命令细节。
set -euo pipefail

: "${UNIKRAFT_TOKEN:?需要 UNIKRAFT_TOKEN}"
: "${IMAGE_REF:?需要 IMAGE_REF，例如 longke233/uptime-kuma:latest}"

METRO="${METRO:-sin}"
NAME="${INSTANCE_NAME:-kuma}"
MEM_MB="${MEM_MB:-1024}"
VCPUS="${VCPUS:-1}"
VOLUME_NAME="${VOLUME_NAME:-kuma-data}"
VOLUME_MOUNT="${VOLUME_MOUNT:-/app/data}"
DEST_PORT="${DEST_PORT:-3001}"
VOLUME_SIZE_MB="${VOLUME_SIZE_MB:-1024}"

API="https://api.${METRO}.unikraft.cloud"
AUTH=(-H "Authorization: Bearer ${UNIKRAFT_TOKEN}")

echo "==> metro=${METRO} instance=${NAME} image=${IMAGE_REF}"

# 1) 已存在同名实例则先删除，保证幂等
EXISTING_UUID="$(curl -fsS "${AUTH[@]}" "${API}/v1/instances" \
  | jq -r --arg n "${NAME}" '.data.instances[]? | select(.name==$n) | .uuid' | head -n1)"

if [ -n "${EXISTING_UUID}" ]; then
  echo "==> 删除已有实例 ${NAME} (${EXISTING_UUID})"
  curl -fsS -X DELETE "${AUTH[@]}" "${API}/v1/instances/${EXISTING_UUID}" >/dev/null
  sleep 3
fi

# 2) 卷不存在则创建
if curl -fsS "${AUTH[@]}" "${API}/v1/volumes" \
   | jq -e --arg n "${VOLUME_NAME}" '.data.volumes[]? | select(.name==$n)' >/dev/null; then
  echo "==> 复用已有卷 ${VOLUME_NAME}"
else
  echo "==> 创建卷 ${VOLUME_NAME} (${VOLUME_SIZE_MB}MB)"
  curl -fsS -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
    -d "{\"name\":\"${VOLUME_NAME}\",\"size_mb\":${VOLUME_SIZE_MB}}" \
    "${API}/v1/volumes" >/dev/null
fi

# 3) 创建实例（用 uuid 追踪，按名查询的接口不可靠）
BODY="$(mktemp)"
cat > "${BODY}" <<EOF
{
  "name": "${NAME}",
  "image": "${IMAGE_REF}",
  "memory_mb": ${MEM_MB},
  "vcpus": ${VCPUS},
  "restart_policy": "on-failure",
  "env": {"DATA_DIR": "${VOLUME_MOUNT}", "UPTIME_KUMA_PORT": "${DEST_PORT}"},
  "service_group": {
    "services": [
      {"port": 443, "destination_port": ${DEST_PORT}, "protocol": "tcp", "handlers": ["http", "tls"]}
    ]
  },
  "volumes": [{"name": "${VOLUME_NAME}", "at": "${VOLUME_MOUNT}"}],
  "scale_to_zero": {"policy": "off"}
}
EOF

echo "==> 创建实例"
UUID="$(curl -fsS -X POST "${AUTH[@]}" -H "Content-Type: application/json" -d @"${BODY}" "${API}/v1/instances" \
  | jq -r '.data.instances[0].uuid')"
rm -f "${BODY}"
echo "    uuid=${UUID}"

# 4) 启动（首次 start 偶发不生效，带重试）
echo "==> 启动实例"
STATE=""
for attempt in 1 2 3; do
  curl -fsS -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
    -d "[{\"uuid\":\"${UUID}\",\"timeout_s\":-1}]" "${API}/v1/instances/start" >/dev/null || true

  for i in $(seq 1 8); do
    sleep 6
    STATE="$(curl -fsS "${AUTH[@]}" "${API}/v1/instances/${UUID}" | jq -r '.data.instances[0].state')"
    echo "    [try ${attempt}.${i}] state=${STATE}"
    [ "${STATE}" = "running" ] && break 2
  done
  echo "    启动未生效，重试..."
done

URL="$(curl -fsS "${AUTH[@]}" "${API}/v1/instances/${UUID}" | jq -r '.data.instances[0].service_group.domains[0].fqdn')"
echo "==> 访问地址：https://${URL}"

if [ "${STATE}" != "running" ]; then
  echo "!! 实例未能保持 running，日志："
  curl -fsS "${AUTH[@]}" "${API}/v1/instances/${UUID}/log" \
    | jq -r '.data.instances[0].output // ""' | base64 -d 2>/dev/null | tail -40 || true
  exit 1
fi

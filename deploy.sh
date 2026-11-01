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

# 3) 创建实例
BODY="$(mktemp)"
cat > "${BODY}" <<EOF
{
  "name": "${NAME}",
  "image": "${IMAGE_REF}",
  "memory_mb": ${MEM_MB},
  "vcpus": ${VCPUS},
  "restart_policy": "on-failure",
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
curl -fsS -X POST "${AUTH[@]}" -H "Content-Type: application/json" -d @"${BODY}" "${API}/v1/instances" >/dev/null
rm -f "${BODY}"

# 4) 启动
echo "==> 启动实例"
curl -fsS -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
  -d "[{\"name\":\"${NAME}\",\"timeout_s\":-1}]" "${API}/v1/instances/start" >/dev/null || true

# 5) 汇报状态与访问域名
sleep 5
curl -fsS "${AUTH[@]}" "${API}/v1/instances/${NAME}" \
  | jq -r '.data.instances[0] | "state=\(.state)  uptime_ms=\(.uptime_ms // 0)  url=https://\(.service_group.domains[0].fqdn)"'

STATE="$(curl -fsS "${AUTH[@]}" "${API}/v1/instances/${NAME}" | jq -r '.data.instances[0].state')"
if [ "${STATE}" != "running" ]; then
  echo "!! 实例未能保持 running，查看日志："
  curl -fsS "${AUTH[@]}" "${API}/v1/instances/${NAME}/log" | jq -r '.data.instances[0].output // "(空)"'
  exit 1
fi

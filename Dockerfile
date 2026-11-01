# Uptime Kuma —— 直接复用官方镜像，不做二次改造
# Unikraft 的 `unikraft build` 会以本文件为 rootfs 来源，打包成 EROFS 后推到 registry。
FROM louislam/uptime-kuma:1

# 数据目录：部署时把卷挂到这里，SQLite 与配置都会持久化
VOLUME ["/app/data"]

EXPOSE 3001

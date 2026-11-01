# unikraft-monitor

在 [Unikraft Cloud](https://unikraft.com) 上构建并部署自托管监控程序。

## 为什么需要这个仓库

Unikraft Cloud 不是普通的容器托管：**它不能直接拉取 Docker Hub 上的任意镜像**。
镜像必须由 `unikraft build` 构建、打包成 EROFS rootfs 后推送到它自己的 registry（`index.unikraft.io`），
`docker push` 无法直接推送过去。

实测对比（同账号同区域）：

| 镜像 | 部署方式 | 结果 |
|---|---|---|
| `nginx:latest` | 平台公共目录 | ✅ 17ms 启动 |
| `louislam/uptime-kuma:1` | 直接引用 Docker Hub | ❌ 约 1s 后退出，日志为空 |
| `adamboutcher/statping-ng:latest` | 直接引用 Docker Hub | ❌ 同上 |
| `traefik/whoami:latest` | 直接引用 Docker Hub | ❌ 同上 |

所以本仓库做的事就是：**GitHub Actions 里跑 `unikraft build` → 推送到 registry → 调 API 部署**。

## 候选监控程序

| 项目 | 语言 | Web 后台 | 数据存储 | 适配 Unikraft |
|---|---|---|---|---|
| [louislam/uptime-kuma](https://github.com/louislam/uptime-kuma) | Node | ✅ 完整 | SQLite（挂卷） | ✅ 当前默认，镜像较大 |
| [TwinProduction/gatus](https://github.com/TwinProduction/gatus) | Go | ❌ 配置驱动 | SQLite/Postgres | ✅ 单二进制，最轻 |
| [adamboutcher/statping-ng](https://github.com/adamboutcher/statping-ng) | Go | ✅ | SQLite | ⚠️ 已基本停更 |
| [bluewave-labs/Checkmate](https://github.com/bluewave-labs/Checkmate) | TS | ✅ | MongoDB | ❌ 需要外部数据库 |
| [operacle/checkcle](https://github.com/operacle/checkcle) | Go | ✅ | SQLite | ⚠️ 组件较多 |

换程序只需要改两处：`Dockerfile` 的 `FROM`，以及 workflow 里的 `IMAGE_REF` / `DEST_PORT`。

## 部署

推送到 `main` 或手动触发 `build-and-deploy` workflow 即可。

需要仓库 Secret：

| Secret | 说明 |
|---|---|
| `UNIKRAFT_TOKEN` | Unikraft Cloud API token |

workflow 里的环境变量控制部署形态：

```yaml
IMAGE_REF: longke233/uptime-kuma:latest   # 必须带 <org>/<name>
INSTANCE_NAME: kuma
METRO: sin
MEM_MB: "1024"
DEST_PORT: "3001"
VOLUME_NAME: kuma-data
VOLUME_MOUNT: /app/data
```

## 注意

- **不要开 scale-to-zero**：监控程序靠自身定时轮询，实例休眠后就不再检查，界面上却看不出异常。脚本里已固定 `policy: off`。
- 免费额度只有 2 个 running 实例，一个常驻监控就占掉一个。
- `IMAGE_REF` 必须写成 `<org>/<name>:tag`，裸名会被解析到 `official/` 命名空间，拉不到自己的镜像。

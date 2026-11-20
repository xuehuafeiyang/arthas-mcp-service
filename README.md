# Arthas MCP Service（一键安装包）

把官方 **Arthas 4.3.5**（内置实验性 **MCP Server**，29 个 JVM 诊断工具）打包成本地服务。
任何支持 MCP（Model Context Protocol）的大模型客户端（Claude Code、Cursor、Cline、Cherry Studio、Codex 等）都能直接连接，用自然语言诊断你的 Java 应用。

```text
LLM / AI 客户端 ──MCP(Streamable HTTP)──▶ Arthas MCP Server ──attach──▶ 目标 JVM
                  http://127.0.0.1:8563/mcp
```

- 传输协议：MCP `2025-06-18`，Streamable HTTP（支持 STATELESS 模式）
- 认证：Bearer Token（默认随机生成）
- 端口：**完全可配置**（默认 8563）
- 离线分发：包内含 Arthas 官方 4.3.5 全量文件，安装后不联网

---

## 1. 一键安装

要求：目标机器有 JDK/JRE 8+（Arthas 4 支持 JDK 8~25），Linux/macOS。

```bash
chmod +x install.sh
./install.sh                     # 默认端口 8563，随机 token
./install.sh --port 9700 --password my-secret
./install.sh --pid 12345         # 直接指定目标 Java 进程
./install.sh --name 'my-app.jar' # 按进程名匹配（pgrep -f）
./install.sh --demo              # 装完顺手起一个官方 demo 目标并 attach
```

全部参数：`--port --telnet-port --password --username --dir --pid --name --protocol(STREAMABLE|STATELESS) --no-systemd --demo`

安装后信息（安装结束也会打印）：

| 项 | 默认 | 说明 |
|---|---|---|
| 安装目录 | `/opt/arthas-mcp`（不可写则 `~/arthas-mcp`） | |
| MCP 端点 | `http://127.0.0.1:8563/mcp` | 端口随 `--port` 变 |
| Bearer token | 随机生成 | 在 `conf/arthas-mcp.env` |
| systemd | 自动安装 `arthas-mcp.service` | 不支持 systemd 时用脚本管理 |

## 2. 启动 / 停止

```bash
/opt/arthas-mcp/arthas-mcp.sh start     # attach 到目标 JVM 并起 MCP 服务
/opt/arthas-mcp/arthas-mcp.sh status    # 健康检查
/opt/arthas-mcp/arthas-mcp.sh restart
/opt/arthas-mcp/arthas-mcp.sh stop      # 通过 HTTP API 优雅下线（目标 JVM 不受影响）
/opt/arthas-mcp/arthas-mcp.sh doctor    # 环境自检
```

没有目标进程可诊断时，先起包内官方 demo：

```bash
/opt/arthas-mcp/arthas-mcp.sh demo-start   # 启动 math-game.jar 并自动设为服务目标
/opt/arthas-mcp/arthas-mcp.sh start
```

systemd 环境：`systemctl start arthas-mcp` / `systemctl status arthas-mcp` / `systemctl stop arthas-mcp`。

**更换目标进程 / 端口**：编辑 `/opt/arthas-mcp/conf/arthas-mcp.env`（`ARTHAS_TARGET_PID` / `ARTHAS_TARGET_NAME` / `ARTHAS_MCP_PORT`），然后 `restart`。

## 3. 大模型客户端接入

Cherry Studio / Cline / 通用 streamableHttp 客户端：

```json
{
  "mcpServers": {
    "arthas-mcp": {
      "type": "streamableHttp",
      "url": "http://127.0.0.1:8563/mcp",
      "headers": { "Authorization": "Bearer <你的token>" }
    }
  }
}
```

Claude Code：

```bash
claude mcp add --transport http arthas-mcp http://127.0.0.1:8563/mcp \
  --header "Authorization: Bearer <你的token>"
```

Cursor（`~/.cursor/mcp.json`）：

```json
{
  "mcpServers": {
    "arthas-mcp": {
      "url": "http://127.0.0.1:8563/mcp",
      "headers": { "Authorization": "Bearer <你的token>" }
    }
  }
}
```

连上后大模型可用的 29 个工具（对应 Arthas 命令）：

- **JVM**：`dashboard` `jvm` `memory` `thread` `sysprop` `sysenv` `vmoption` `mbean` `perfcounter` `vmtool` `getstatic` `ognl` `heapdump`
- **类/类加载**：`sc` `sm` `jad` `classloader` `mc` `redefine` `retransform` `dump`
- **监控诊断**：`monitor` `stack` `trace` `tt` `watch` `profiler`
- **辅助**：`viewfile`（目录白名单内）`options`

例如直接对模型说：*“这个 Java 进程为什么 CPU 这么高？先看最忙的线程和它的堆栈”*，模型会自动串联 `thread` → `jad` → `trace` 等工具调用。

## 4. 安全建议（重要）

- 服务只绑定 `127.0.0.1`，不要把 8563 端口暴露到公网。
- Bearer token 等同于目标 JVM 的完整诊断权限（含 `ognl`/`redefine` 等高权限工具），妥善保管；生产环境建议只开放只读类工具，`redefine`/`retransform`/`vmtool`/`ognl` 默认禁用（可在 `arthas.properties` 中配置 `arthas.disabledCommands`）。
- `watch`/`trace` 会做字节码增强，注意加 `-n`/条件过滤，避免高频方法上长时间挂监控。
- `arthas.mcpProtocol=STATELESS` 适合一次性查询场景；默认 `STREAMABLE` 支持流式输出（watch/trace/monitor）。

## 5. 工作原理

- `install.sh` 渲染 `arthas.properties`（端口/认证/MCP 端点）→ 安装到目标目录 → 注册 systemd（可选）。
- `start` 用 `arthas-boot --attach-only` 把 Arthas agent 注入目标 JVM；Arthas 的 HTTP/Netty 服务（含 MCP 端点）**运行在目标 JVM 内部**，boot 客户端随即退出。
- `stop` 调用 `POST /api`（Basic 认证）执行 `stop` 命令，Arthas 从目标 JVM 卸载，应用进程本身不受影响。

## 6. 故障排查

| 现象 | 处理 |
|---|---|
| `attach failed` | 确认 pid 是 Java 进程且与 arthas 用户一致（权限）；容器内需同 UID |
| 健康检查失败 | `arthas-mcp.sh doctor`；检查端口占用 `ss -ltn`；换 `--port` |
| 401 | token 不匹配，核对 `conf/arthas-mcp.env` 与客户端 header |
| 想换端口 | 改 `env` 中 `ARTHAS_MCP_PORT` + `restart`，或重跑 `install.sh --port` |

# TProxy 管理界面

只读运维仪表盘：缓存占用、劫持规则、证书到期、分流入口。

## 运行

```bash
# 方式一：容器（推荐，随 proxy 编排一起起）
cd ../proxy && docker compose up -d manager

# 方式二：直接跑（需本机有 flask）
cd manager && python3 app.py
```

访问 `http://127.0.0.1:5557`。

> **仅绑定回环地址。** 界面没有认证机制，因此不做远程暴露。
> 需远程访问时请走 SSH 隧道：`ssh -L 5557:127.0.0.1:5557 grigs@192.168.0.18`

## 设计取舍

### 只读

配置与缓存均以 `:ro` 挂载，**界面不写任何文件**。

原因：界面写规则会与运维手工编辑互相覆盖；且在无认证的前提下开放写权限风险过高。
「新增上游」走文档化流程 —— 见 [`proxy/docs/ADD-UPSTREAM.md`](../proxy/docs/ADD-UPSTREAM.md)。

### 空态必须写明原因

每个空列表都给出具体指引（如「未解析到劫持规则 —— 检查 dnsmasq 配置路径与内容」），
不留白。**旧 proxy-manager 正是因「显示为空却不报错」，让缓存完全失效持续数月无人察觉。**

### 路径映射是硬编码的

`backend/cache_stats.py` 的 `CACHE_PATHS` 记录六类缓存的真实相对路径。
这不是「六类都在 CACHE_BASE 下」—— tengine 的缓存挂在 `${CACHE_BASE}/nginx`
（compose 中 `${CACHE_BASE}/nginx:/var/cache/tproxy`），故 os/python/nodejs/java
位于其子目录。

> 早期版本按扁平布局统计，把已有 75MB 数据的 os 缓存报成「未启用」，
> 而当时的验收脚本只清点 type 个数，全绿放过。
> 现在 `test-manager.sh` 会逐类核对界面报告与磁盘实际。

**若调整 compose 中的缓存挂载，必须同步修改 `CACHE_PATHS` 与 `test-manager.sh`。**

## 未实现（相对 spec §3.1）

| 项 | 状态 | 说明 |
|---|---|---|
| **缓存命中率统计** | ❌ 未实现 | spec 称其为「判断缓存是否真正生效」的核心。数据基础已具备（nginx 日志含 `$upstream_cache_status`），但解析需严格对照 `nginx.conf` 的 `log_format main` —— 旧 monitor 正是栽在格式不符上 |
| 服务状态与控制 | ❌ 未实现 | 可由 `docker compose ps` 替代 |
| SQLite 持久化 | ❌ 未实现 | 当前无需要持久化的数据 |
| 界面写操作 | ❌ 刻意不做 | 见上文「只读」 |

## API

| 端点 | 返回 |
|---|---|
| `/api/status` | 存活探测 |
| `/api/cache` | 六类缓存的占用与启用状态 |
| `/api/rules` | 劫持规则 + 分流配置 |
| `/api/certs` | 证书与剩余天数 |

路径经环境变量注入（`TPROXY_CACHE_BASE` 等），便于测试与部署分离。

## 测试

```bash
python3 -m pytest tests/ -q          # 单元测试（23 项）
cd ../proxy && ./tests/test-manager.sh   # 在目标机上验证真实数据
```

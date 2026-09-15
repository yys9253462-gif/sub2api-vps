# Sub2API VPS 一键部署与生产级运维管理脚本

适用于任何 Linux VPS（Debian / Ubuntu / CentOS / AlmaLinux / Rocky Linux / Alpine）的一键部署脚本，专为大模型 API 中转站打造。

---

## ✨ 核心特性

1. **零配置 HTTPS**：集成 Caddy 2 作为反向代理网关，自动申请与自动续期 Let's Encrypt / ZeroSSL 证书。
2. **独家 Gemini 适配层**：
   - 自动修复客户端（Codex Desktop、ZCode 等）调用 Gemini 工具时报 `400 Unknown name "const" / "anyOf"` 的兼容性缺陷。
   - 自动拦截流式响应中的 `<thinking>` 标签，无缝转换为标准 `reasoning_content`。
3. **数据库与安全隔离**：PostgreSQL 16 与 Redis 7 仅在容器专用内网运行，不暴露宿主机危险端口。
4. **全功能运维面板**：包含一键安装、日志监控、在线升级、一键换域名与证书重签、管理员密码重置、全量打包备份、一键干净卸载。

---

## 🚀 极速部署使用方法

### 1. 登录 VPS 终端并运行

以 `root` 用户登录您的 VPS，执行以下单行命令即可启动管理面板：

```bash
curl -fsSL https://raw.githubusercontent.com/yys9253462-gif/sub2api-vps/main/sub2api.sh -o sub2api.sh && chmod +x sub2api.sh && bash sub2api.sh
```

*(也可以直接将 `sub2api.sh` 上传到 VPS 运行)*

---

## 📋 功能菜单一览

运行 `bash sub2api.sh` 后会展示如下运维管理控制台：

```text
======================================================================
                Sub2API VPS 一键部署与运维管理平台
======================================================================
 运行状态 : ● 运行中
 绑定域名 : https://api.yourdomain.com
 管理账号 : admin@yourdomain.com
 适配层   : 已开启 (Gemini 400/Thinking 优化)
----------------------------------------------------------------------
  1. 全新一键部署 Sub2API 集群 (自动配置 Caddy HTTPS / 数据库)
  2. 查看各容器运行状态与端口
  3. 查看各服务实时日志 (支持多组件分流)
  4. 重启全部服务
  5. 停止全部服务
  6. 启动全部服务
  7. 在线一键升级 Sub2API 与所有容器镜像
  8. 更换绑定域名 (自动重签 HTTPS 证书)
  9. 重置/修改管理员密码
 10. 一键全量数据备份 (PostgreSQL + Redis + 配置)
 11. 彻底卸载并清理所有数据
  0. 退出脚本
======================================================================
```

---

## 📂 默认文件结构

脚本默认安装在 `/opt/sub2api` 目录下：

```text
/opt/sub2api/
├── .env                  # 核心环境变量与随机安全密钥
├── docker-compose.yml    # Docker 容器编排配置
├── caddy/
│   ├── Caddyfile         # Caddy 自动化反代与证书配置
│   └── data/             # SSL 证书持久化存储
├── adapter/
│   ├── Dockerfile        # Gemini 双向适配层容器构建文件
│   └── adapter_service.py# Schema 清洗与 Thinking 标签提取服务
├── data/                 # Sub2API 核心业务数据
├── postgres_data/        # PostgreSQL 数据库持久卷
├── redis_data/           # Redis 数据持久卷
└── backups/              # 历史全量备份 tar.gz 归档目录
```

---

## ⚙️ 前提要求

1. **VPS 系统**：Debian 10+ / Ubuntu 20.04+ / AlmaLinux / RockyLinux / CentOS 7+
2. **开放端口**：防火墙需放行 **80** 和 **443** 端口（用于 Web 访问与申请 HTTPS 证书）。
3. **域名解析**：部署前请先将域名的 **A 记录** 解析到您的 VPS 公网 IP。

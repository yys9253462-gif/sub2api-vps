#!/usr/bin/env bash
# ==============================================================================
# Sub2API VPS 一键部署与全生命周期运维管理脚本 (v2.1 深度加固与生产修复版)
# GitHub: https://github.com/yys9253462-gif/sub2api-vps
# 适用系统: Debian 10+, Ubuntu 20.04+, CentOS 7/8/9, AlmaLinux, Rocky Linux, Alpine
# ==============================================================================

set -e

# --- 颜色与样式定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- 全局路径变量 ---
INSTALL_DIR="/opt/sub2api"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"
CADDY_FILE="${INSTALL_DIR}/caddy/Caddyfile"
ADAPTER_DIR="${INSTALL_DIR}/adapter"
BACKUP_DIR="${INSTALL_DIR}/backups"
GLOBAL_BIN="/usr/local/bin/sub2api"
SCRIPT_URL="https://raw.githubusercontent.com/yys9253462-gif/sub2api-vps/main/sub2api.sh"

# --- 辅助输出函数 ---
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
title() {
    echo -e "${PURPLE}======================================================================${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${PURPLE}======================================================================${NC}"
}

# --- 检查 Root 权限 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "此脚本必须以 root 用户身份运行！请使用 sudo -i 或 su root 切换后重试。"
        exit 1
    fi
}

# --- 安全读取 .env 文件的键值 (严禁 source 防止命令注入) ---
read_env() {
    local key=$1
    if [ -f "$ENV_FILE" ]; then
        grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d '=' -f2- | sed -e 's/^"//' -e 's/"$//'
    fi
}

# --- 操作系统检测与包管理器适配 ---
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION_ID=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        VERSION_ID=$(lsb_release -sr)
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        error "无法识别当前操作系统类型。"
        exit 1
    fi

    case "$OS" in
        ubuntu|debian|raspbian)
            PKG_MANAGER="apt"
            ;;
        centos|almalinux|rocky|rhel|fedora)
            PKG_MANAGER="dnf"
            if ! command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro)
            PKG_MANAGER="pacman"
            ;;
        alpine)
            PKG_MANAGER="apk"
            ;;
        *)
            PKG_MANAGER="unknown"
            ;;
    esac
}

# --- 基础工具安装 ---
install_dependencies() {
    info "正在检查并安装基础依赖 (curl, wget, tar, openssl, python3, lsof, jq)..."
    case "$PKG_MANAGER" in
        apt)
            apt update -y -q
            apt install -y -q curl wget tar openssl ca-certificates python3 python3-pip lsof jq
            ;;
        dnf|yum)
            $PKG_MANAGER install -y -q curl wget tar openssl ca-certificates python3 python3-pip lsof jq
            ;;
        pacman)
            pacman -Sy --noconfirm curl wget tar openssl ca-certificates python python-pip lsof jq
            ;;
        apk)
            apk update
            apk add curl wget tar openssl ca-certificates python3 py3-pip lsof jq bash
            ;;
        *)
            warn "未识别的包管理器，请确保 curl, openssl, tar 已安装。"
            ;;
    esac
}

# --- 智能放行防火墙 ---
configure_firewall() {
    local port=${1:-80}
    info "正在检测并配置系统防火墙，确保端口 ${port} 通畅..."
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        success "已通过 UFW 放行 ${port}/tcp 端口。"
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        success "已通过 Firewalld 放行 ${port}/tcp 端口。"
    fi

    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
    fi
}

# --- Docker 与 Docker Compose 检测及安装 ---
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        success "检测到 Docker 已安装: $(docker --version)"
    else
        info "未检测到 Docker，正在全自动安装官方最新 Docker 引擎..."
        if [ "$OS" = "alpine" ]; then
            apk add docker docker-cli-compose
            rc-update add docker boot
            service docker start
        else
            curl -fsSL https://get.docker.com | bash
            systemctl enable docker
            systemctl start docker
        fi
        success "Docker 安装成功！"
    fi

    if docker compose version >/dev/null 2>&1; then
        success "检测到 Docker Compose: $(docker compose version)"
    elif command -v docker-compose >/dev/null 2>&1; then
        success "检测到 docker-compose 独立二进制: $(docker-compose --version)"
    else
        info "正在安装 Docker Compose 插件..."
        DOCKER_CONFIG=${DOCKER_CONFIG:-/root/.docker}
        mkdir -p "$DOCKER_CONFIG/cli-plugins"
        COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
        curl -SL "$COMPOSE_URL" -o "$DOCKER_CONFIG/cli-plugins/docker-compose" || \
        curl -SL "https://ghproxy.com/$COMPOSE_URL" -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
        chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"
        success "Docker Compose 安装完成！"
    fi
}

# --- 封装 Compose 执行命令 ---
run_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" "$@"
    else
        docker-compose -f "$COMPOSE_FILE" "$@"
    fi
}

# --- 端口占用检查 ---
check_port() {
    local port=$1
    if command -v lsof >/dev/null 2>&1; then
        if lsof -i :"$port" -sTCP:LISTEN >/dev/null 2>&1; then
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -q ":$port "; then
            return 1
        fi
    fi
    return 0
}

# --- 随机密码生成 (仅含字母数字) ---
gen_password() {
    local len=${1:-16}
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "$len"
}

# --- 生成 Gemini 适配层源码 (含非流式与流式全场景 Thinking 提取与编码保护) ---
generate_adapter() {
    mkdir -p "$ADAPTER_DIR"
    cat > "$ADAPTER_DIR/adapter_service.py" << 'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sub2API Gemini 工具调用与 Thinking 标签双向适配层
特性:
1. 请求改写: 修复 Google Gemini 不支持 const/anyOf/oneOf/$schema 导致的 400 报错
2. 响应改写: 流式与非流式全场景精准提取 <thinking> 标签，防止泄露
3. 传输加固: 剥离 Accept-Encoding 避免 gzip 乱码，支持 ThreadingHTTPServer 高并发
"""

import sys
import json
import re
import socket
import logging
from socketserver import ThreadingMixIn
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

SUB2API_HOST = "sub2api"
SUB2API_PORT = 8080

def clean_gemini_schema(obj):
    if isinstance(obj, dict):
        new_dict = {}
        for k, v in obj.items():
            if k in ("$schema", "patternProperties", "additionalItems"):
                continue
            if k == "const":
                new_dict["enum"] = [v]
                continue
            if k == "anyOf" and isinstance(v, list):
                const_values = []
                all_const = True
                for item in v:
                    if isinstance(item, dict) and "const" in item:
                        const_values.append(item["const"])
                    else:
                        all_const = False
                        break
                if all_const and const_values:
                    new_dict["enum"] = const_values
                    continue
                else:
                    new_dict[k] = [clean_gemini_schema(x) for x in v]
                    continue
            new_dict[k] = clean_gemini_schema(v)
        return new_dict
    elif isinstance(obj, list):
        return [clean_gemini_schema(x) for x in obj]
    return obj

def process_request_body(body_bytes):
    try:
        data = json.loads(body_bytes.decode('utf-8'))
        if isinstance(data, dict) and "tools" in data:
            data = clean_gemini_schema(data)
            return json.dumps(data, ensure_ascii=False).encode('utf-8')
    except Exception:
        pass
    return body_bytes

def extract_thinking_from_text(text):
    """从完整文本中提取 <thinking> 标签并拆分为正文与思考内容"""
    if not text or "<thinking>" not in text:
        return text, ""
    
    reasoning_parts = []
    clean_parts = []
    pos = 0
    pattern = re.compile(r'<thinking>(.*?)</thinking>', re.DOTALL)
    
    for match in pattern.finditer(text):
        clean_parts.append(text[pos:match.start()])
        reasoning_parts.append(match.group(1))
        pos = match.end()
    clean_parts.append(text[pos:])
    
    return "".join(clean_parts), "\n".join(reasoning_parts)

class ThinkingTagFilter:
    """严格的前缀匹配流式分块状态机"""
    START_TAG = "<thinking>"
    END_TAG = "</thinking>"

    def __init__(self):
        self.in_thinking = False
        self.buffer = ""

    def process_chunk(self, chunk):
        self.buffer += chunk
        clean_out = []
        reasoning_out = []

        while self.buffer:
            if not self.in_thinking:
                idx = self.buffer.find(self.START_TAG)
                if idx != -1:
                    clean_out.append(self.buffer[:idx])
                    self.buffer = self.buffer[idx + len(self.START_TAG):]
                    self.in_thinking = True
                    continue
                
                matched_prefix_len = 0
                for i in range(1, min(len(self.START_TAG), len(self.buffer) + 1)):
                    if self.START_TAG.startswith(self.buffer[-i:]):
                        matched_prefix_len = i
                
                if matched_prefix_len > 0:
                    clean_out.append(self.buffer[:-matched_prefix_len])
                    self.buffer = self.buffer[-matched_prefix_len:]
                    break
                else:
                    clean_out.append(self.buffer)
                    self.buffer = ""
                    break
            else:
                idx = self.buffer.find(self.END_TAG)
                if idx != -1:
                    reasoning_out.append(self.buffer[:idx])
                    self.buffer = self.buffer[idx + len(self.END_TAG):]
                    self.in_thinking = False
                    continue
                
                matched_prefix_len = 0
                for i in range(1, min(len(self.END_TAG), len(self.buffer) + 1)):
                    if self.END_TAG.startswith(self.buffer[-i:]):
                        matched_prefix_len = i
                
                if matched_prefix_len > 0:
                    reasoning_out.append(self.buffer[:-matched_prefix_len])
                    self.buffer = self.buffer[-matched_prefix_len:]
                    break
                else:
                    reasoning_out.append(self.buffer)
                    self.buffer = ""
                    break

        return "".join(clean_out), "".join(reasoning_out)

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        self.handle_proxy()

    def do_GET(self):
        self.handle_proxy()

    def do_OPTIONS(self):
        self.handle_proxy()

    def handle_proxy(self):
        content_len = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_len) if content_len > 0 else b""
        
        if self.command == "POST" and body:
            body = process_request_body(body)

        target_url = f"http://{SUB2API_HOST}:{SUB2API_PORT}{self.path}"
        req = Request(target_url, data=body if self.command == "POST" else None, method=self.command)
        
        # 转发 Headers (剥离 accept-encoding 防止 gzip 二进制流打乱行解析)
        for k, v in self.headers.items():
            if k.lower() not in ("host", "content-length", "connection", "accept-encoding"):
                req.add_header(k, v)
        if body:
            req.add_header("Content-Length", str(len(body)))
        req.add_header("Host", f"{SUB2API_HOST}:{SUB2API_PORT}")

        try:
            with urlopen(req, timeout=300) as response:
                self.send_response(response.status)
                for k, v in response.headers.items():
                    if k.lower() not in ("transfer-encoding", "content-length", "connection", "content-encoding"):
                        self.send_header(k, v)
                
                is_sse = "text/event-stream" in response.headers.get("Content-Type", "")
                
                if not is_sse:
                    resp_body = response.read()
                    # 尝试清洗非流式响应中的 Thinking 标签
                    try:
                        resp_json = json.loads(resp_body.decode('utf-8'))
                        choices = resp_json.get("choices", [])
                        if choices and "message" in choices[0]:
                            msg = choices[0]["message"]
                            raw_content = msg.get("content", "")
                            if raw_content and "<thinking>" in raw_content:
                                clean_t, reason_t = extract_thinking_from_text(raw_content)
                                msg["content"] = clean_t
                                if reason_t:
                                    msg["reasoning_content"] = reason_t
                                resp_body = json.dumps(resp_json, ensure_ascii=False).encode('utf-8')
                    except Exception:
                        pass
                    
                    self.send_header("Content-Length", str(len(resp_body)))
                    self.end_headers()
                    self.wfile.write(resp_body)
                else:
                    self.send_header("Connection", "close")
                    self.end_headers()
                    tag_filter = ThinkingTagFilter()
                    
                    for raw_line in response:
                        line = raw_line.decode('utf-8', errors='ignore')
                        if line.startswith("data: ") and line.strip() != "data: [DONE]":
                            try:
                                payload = json.loads(line[6:].strip())
                                choices = payload.get("choices", [])
                                if choices and "delta" in choices[0]:
                                    delta = choices[0]["delta"]
                                    content = delta.get("content", "")
                                    if content:
                                        clean_text, reasoning_text = tag_filter.process_chunk(content)
                                        delta["content"] = clean_text
                                        if reasoning_text:
                                            delta["reasoning_content"] = reasoning_text
                                        line = "data: " + json.dumps(payload, ensure_ascii=False) + "\n"
                            except Exception:
                                pass
                        self.wfile.write(line.encode('utf-8'))
                        self.wfile.flush()
        except HTTPError as e:
            self.send_response(e.code)
            self.end_headers()
            self.wfile.write(e.read())
        except Exception as e:
            logging.error(f"Proxy error: {e}")
            self.send_response(502)
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode('utf-8'))

def run_server(port=8086):
    server = ThreadedHTTPServer(("0.0.0.0", port), ProxyHandler)
    logging.info(f"Gemini Adapter listening on port {port} -> {SUB2API_HOST}:{SUB2API_PORT}")
    server.serve_forever()

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8086
    run_server(port)
EOF

    cat > "$ADAPTER_DIR/Dockerfile" << 'EOF'
FROM python:3.11-alpine
WORKDIR /app
COPY adapter_service.py .
USER nobody
EXPOSE 8086
CMD ["python", "-u", "adapter_service.py", "8086"]
EOF
}

# --- 生成 Docker Compose 配置文件 (支持 Caddy 自动 HTTPS 或 独立端口映射模式) ---
generate_compose() {
    local domain=$1
    local enable_adapter=$2
    local deploy_mode=${3:-"caddy_ssl"}
    local custom_port=${4:-18080}

    mkdir -p "$INSTALL_DIR/caddy" "$INSTALL_DIR/caddy/data" "$INSTALL_DIR/caddy/config" \
             "$INSTALL_DIR/data" "$INSTALL_DIR/postgres_data" "$INSTALL_DIR/redis_data"
    chmod 755 "$INSTALL_DIR/caddy/data" "$INSTALL_DIR/caddy/config" 2>/dev/null || true

    if [ "$deploy_mode" = "caddy_ssl" ]; then
        # 生成 Caddyfile
        cat > "$CADDY_FILE" << 'EOF'
{
    email {$ACME_EMAIL}
    admin off
}

{$DOMAIN} {
    encode gzip zstd

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
EOF
        if [ "$enable_adapter" = "true" ]; then
            cat >> "$CADDY_FILE" << 'EOF'
    @llm_routes {
        path /v1/chat/completions*
        path /v1/responses*
        path /v1/messages*
    }
    reverse_proxy @llm_routes gemini-adapter:8086 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }

    reverse_proxy sub2api:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF
        else
            cat >> "$CADDY_FILE" << 'EOF'
    reverse_proxy sub2api:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF
        fi

        # 生成 带 Caddy 的 compose
        cat > "$COMPOSE_FILE" << 'EOF'
services:
  caddy:
    image: caddy:2-alpine
    container_name: sub2api-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - DOMAIN=${DOMAIN}
      - ACME_EMAIL=${ACME_EMAIL}
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/data:/data
      - ./caddy/config:/config
    networks:
      - sub2api-net
    depends_on:
      - sub2api
EOF
    else
        # 独立端口映射模式 (无需 Caddy，直接映射宿主机端口)
        cat > "$COMPOSE_FILE" << 'EOF'
services:
EOF
    fi

    # Sub2API 核心服务定义
    if [ "$deploy_mode" = "custom_port" ] && [ "$enable_adapter" != "true" ]; then
        cat >> "$COMPOSE_FILE" << EOF
  sub2api:
    image: weishaw/sub2api:latest
    container_name: sub2api
    restart: unless-stopped
    ports:
      - "${custom_port}:8080"
EOF
    else
        cat >> "$COMPOSE_FILE" << 'EOF'
  sub2api:
    image: weishaw/sub2api:latest
    container_name: sub2api
    restart: unless-stopped
EOF
    fi

    cat >> "$COMPOSE_FILE" << 'EOF'
    environment:
      - AUTO_SETUP=true
      - SERVER_HOST=0.0.0.0
      - SERVER_PORT=8080
      - SERVER_MODE=release
      - TZ=${TZ:-Asia/Shanghai}
      - DATABASE_HOST=sub2api-db
      - DATABASE_PORT=5432
      - DATABASE_USER=sub2api
      - DATABASE_PASSWORD=${POSTGRES_PASSWORD}
      - DATABASE_DBNAME=sub2api
      - DATABASE_SSLMODE=disable
      - REDIS_HOST=sub2api-redis
      - REDIS_PORT=6379
      - REDIS_DB=0
      - ADMIN_EMAIL=${ADMIN_EMAIL}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD}
      - JWT_SECRET=${JWT_SECRET}
      - JWT_EXPIRE_HOUR=24
      - TOTP_ENCRYPTION_KEY=${TOTP_ENCRYPTION_KEY}
      - SECURITY_URL_ALLOWLIST_ENABLED=true
      - ANTIGRAVITY_USER_AGENT_VERSION=4.3.0
    volumes:
      - ./data:/app/data
    networks:
      - sub2api-net
    depends_on:
      sub2api-db:
        condition: service_healthy
      sub2api-redis:
        condition: service_healthy

  sub2api-db:
    image: postgres:16-alpine
    container_name: sub2api-db
    restart: unless-stopped
    environment:
      - POSTGRES_USER=sub2api
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=sub2api
      - TZ=${TZ:-Asia/Shanghai}
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    networks:
      - sub2api-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sub2api -d sub2api"]
      interval: 5s
      timeout: 5s
      retries: 5

  sub2api-redis:
    image: redis:7-alpine
    container_name: sub2api-redis
    restart: unless-stopped
    command: sh -c 'redis-server --save 60 1 --appendonly yes'
    volumes:
      - ./redis_data:/data
    networks:
      - sub2api-net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5
EOF

    if [ "$enable_adapter" = "true" ]; then
        generate_adapter
        if [ "$deploy_mode" = "custom_port" ]; then
            cat >> "$COMPOSE_FILE" << EOF

  gemini-adapter:
    build:
      context: ./adapter
    container_name: sub2api-gemini-adapter
    restart: unless-stopped
    ports:
      - "${custom_port}:8086"
    networks:
      - sub2api-net
    depends_on:
      - sub2api
EOF
        else
            cat >> "$COMPOSE_FILE" << 'EOF'

  gemini-adapter:
    build:
      context: ./adapter
    container_name: sub2api-gemini-adapter
    restart: unless-stopped
    networks:
      - sub2api-net
    depends_on:
      - sub2api
EOF
        fi
    fi

    cat >> "$COMPOSE_FILE" << 'EOF'

networks:
  sub2api-net:
    driver: bridge
EOF
}

# --- 注册全局快捷管理命令 (兼容管道执行) ---
register_global_cmd() {
    info "正在配置全局快捷管理命令 'sub2api'..."
    mkdir -p "$INSTALL_DIR"
    if [ -f "$0" ] && grep -q "Sub2API VPS" "$0" 2>/dev/null; then
        cp "$0" "${INSTALL_DIR}/sub2api.sh"
    else
        curl -fsSL "$SCRIPT_URL" -o "${INSTALL_DIR}/sub2api.sh" || true
    fi
    chmod +x "${INSTALL_DIR}/sub2api.sh" 2>/dev/null || true
    ln -sf "${INSTALL_DIR}/sub2api.sh" "$GLOBAL_BIN" 2>/dev/null || true
    success "全局快捷命令已注册！在终端任何路径直接输入 'sub2api' 即可唤出管理面板。"
}

# --- 一键全新部署交互向导 ---
deploy_wizard() {
    title "Sub2API VPS 一键部署配置向导"

    # 1. 检查端口占用与部署模式选择
    local deploy_mode="caddy_ssl"
    local custom_port=18080
    local domain_input=""

    info "正在检查 80 / 443 端口占用状态..."
    local port80_busy=0
    local port443_busy=0
    if ! check_port 80; then port80_busy=1; fi
    if ! check_port 443; then port443_busy=1; fi

    if [ $port80_busy -eq 1 ] || [ $port443_busy -eq 1 ]; then
        warn "检测到端口 80 或 443 已被系统现有服务 (如 Nginx/Apache/Xray) 占用！"
        echo -e "  [1] ${GREEN}使用独立端口共存模式 (推荐，不影响现有 Nginx 站点)${NC}"
        echo -e "  [2] 终止现有服务并由 Caddy 独占 80/443"
        echo -e "  [0] 退出部署"
        read -p "请选择应对方案 [1-2, 默认: 1]: " PORT_CONFLICT_CHOICE
        PORT_CONFLICT_CHOICE=${PORT_CONFLICT_CHOICE:-1}

        case "$PORT_CONFLICT_CHOICE" in
            1)
                deploy_mode="custom_port"
                read -p "请输入对外映射的主机端口 [默认: 18080]: " CUSTOM_PORT_INPUT
                custom_port=${CUSTOM_PORT_INPUT:-18080}
                while ! check_port "$custom_port"; do
                    error "端口 ${custom_port} 仍被占用，请更换其他端口！"
                    read -p "请输入对外映射的主机端口 [默认: 18080]: " CUSTOM_PORT_INPUT
                    custom_port=${CUSTOM_PORT_INPUT:-18080}
                done
                success "已选择独立端口模式，将映射到公网端口: ${custom_port}"
                ;;
            2)
                deploy_mode="caddy_ssl"
                warn "请自行在外部停止占用 80/443 的进程后再继续。"
                ;;
            *)
                info "已取消部署。"
                exit 0
                ;;
        esac
    else
        success "80 / 443 端口空闲，可使用 Caddy 自动申请 HTTPS 模式。"
    fi

    # 2. 交互收集域名或 IP
    echo ""
    if [ "$deploy_mode" = "caddy_ssl" ]; then
        echo -e "${YELLOW}提示: 请确保域名已在 DNS 处添加 A 记录解析到本 VPS IP (若用 Cloudflare 请设置为 DNS Only / 灰色小云朵)。${NC}"
        while true; do
            read -p "请输入您绑定的完整域名 (例如: api.example.com): " DOMAIN_INPUT
            if [[ "$DOMAIN_INPUT" =~ ^[a-zA-Z0-9][-a-zA-Z0-9.]*[a-zA-Z0-9]$ ]]; then
                domain_input="$DOMAIN_INPUT"
                break
            else
                error "域名格式不合法，请重新输入！"
            fi
        done
        read -p "请输入 SSL 证书接收告警邮箱 [默认: admin@${domain_input}]: " EMAIL_INPUT
        EMAIL_INPUT=${EMAIL_INPUT:-"admin@${domain_input}"}
    else
        LOCAL_IP=$(curl -4sSL https://api.ipify.org || curl -4sSL https://icanhazip.com || echo "YOUR_VPS_IP")
        echo -e "${CYAN}当前处于独立端口模式，可直接通过 http://${LOCAL_IP}:${custom_port} 访问，也可通过现有 Nginx 反代。${NC}"
        read -p "请输入访问域名或主机IP [默认: ${LOCAL_IP}]: " DOMAIN_INPUT
        domain_input=${DOMAIN_INPUT:-$LOCAL_IP}
        EMAIL_INPUT="admin@sub2api.local"
    fi

    # 3. 收集管理员邮箱
    read -p "请输入 Sub2API 初始管理员账号邮箱 [默认: admin@${domain_input}]: " ADMIN_EMAIL_INPUT
    ADMIN_EMAIL_INPUT=${ADMIN_EMAIL_INPUT:-"admin@${domain_input}"}

    # 4. 收集/生成管理员密码
    DEFAULT_PASS=$(gen_password 16)
    read -p "请输入 Sub2API 管理员密码 [回车使用随机安全密码: ${DEFAULT_PASS}]: " ADMIN_PASS_INPUT
    ADMIN_PASS_INPUT=${ADMIN_PASS_INPUT:-$DEFAULT_PASS}

    # 5. 选择是否启用 Gemini 适配层
    echo ""
    echo -e "是否启用 ${GREEN}Gemini 工具调用与 Thinking 标签双向适配层${NC}？"
    echo -e "  - 自动修复 Gemini 400 Unknown name 'const' / 'anyOf' 错误"
    echo -e "  - 自动将 <thinking> 标签剥离并输出标准 reasoning_content"
    read -p "是否启用？[Y/n, 默认: Y]: " ENABLE_ADAPTER_INPUT
    case "$ENABLE_ADAPTER_INPUT" in
        [nN][oO]|[nN])
            ENABLE_ADAPTER="false"
            ;;
        *)
            ENABLE_ADAPTER="true"
            ;;
    esac

    # 6. 确认部署
    echo ""
    title "部署参数确认"
    echo -e "部署模式       : $([ "$deploy_mode" = "caddy_ssl" ] && echo -e "${GREEN}Caddy 自动 HTTPS (80/443)${NC}" || echo -e "${YELLOW}独立端口模式 (${custom_port})${NC}")"
    echo -e "绑定地址/域名  : ${GREEN}${domain_input}${NC}"
    echo -e "管理员账号     : ${CYAN}${ADMIN_EMAIL_INPUT}${NC}"
    echo -e "管理员密码     : ${YELLOW}${ADMIN_PASS_INPUT}${NC}"
    echo -e "Gemini 适配层  : $([ "$ENABLE_ADAPTER" = "true" ] && echo -e "${GREEN}已启用 (全场景 Thinking 适配版)${NC}" || echo -e "${RED}已关闭${NC}")"
    echo -e "安装目录       : ${CYAN}${INSTALL_DIR}${NC}"
    echo ""
    read -p "确认以上配置无误并开始部署？[Y/n]: " CONFIRM_DEPLOY
    if [[ "$CONFIRM_DEPLOY" =~ ^[nN] ]]; then
        warn "用户取消部署。"
        exit 0
    fi

    # 执行安装流程
    install_dependencies
    if [ "$deploy_mode" = "caddy_ssl" ]; then
        configure_firewall 80
        configure_firewall 443
    else
        configure_firewall "$custom_port"
    fi
    install_docker

    info "正在创建安装目录并写入配置文件..."
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # 生成安全的随机密码与密钥
    PG_PASS=$(gen_password 24)
    JWT_SEC=$(gen_password 32)
    TOTP_KEY=$(gen_password 32)

    # 安全写入 .env 文件
    cat > "$ENV_FILE" << EOF
DOMAIN="${domain_input}"
DEPLOY_MODE="${deploy_mode}"
HOST_PORT="${custom_port}"
ACME_EMAIL="${EMAIL_INPUT}"
ADMIN_EMAIL="${ADMIN_EMAIL_INPUT}"
ADMIN_PASSWORD="${ADMIN_PASS_INPUT}"
POSTGRES_PASSWORD="${PG_PASS}"
JWT_SECRET="${JWT_SEC}"
TOTP_ENCRYPTION_KEY="${TOTP_KEY}"
TZ="Asia/Shanghai"
ENABLE_ADAPTER="${ENABLE_ADAPTER}"
EOF
    chmod 600 "$ENV_FILE"

    # 生成 Compose 与 Caddyfile
    generate_compose "$domain_input" "$ENABLE_ADAPTER" "$deploy_mode" "$custom_port"

    info "正在拉取 Docker 镜像并启动容器集群..."
    run_compose pull
    run_compose up -d --build

    # 注册全局管理命令
    register_global_cmd

    # 精确健康检查
    info "正在等待 Sub2API 服务与数据库就绪..."
    local retry=0
    local max_retries=30
    local is_ready=0

    while [ $retry -lt $max_retries ]; do
        sleep 3
        local sub2api_status=$(docker inspect --format '{{.State.Status}}' sub2api 2>/dev/null || echo "not_found")
        if [ "$deploy_mode" = "caddy_ssl" ]; then
            local caddy_status=$(docker inspect --format '{{.State.Status}}' sub2api-caddy 2>/dev/null || echo "not_found")
            if [ "$sub2api_status" = "running" ] && [ "$caddy_status" = "running" ]; then
                is_ready=1
                break
            fi
        else
            if [ "$sub2api_status" = "running" ]; then
                is_ready=1
                break
            fi
        fi
        retry=$((retry + 1))
        echo -n "."
    done
    echo ""

    if [ $is_ready -eq 1 ]; then
        echo ""
        title "Sub2API 部署成功！"
        if [ "$deploy_mode" = "caddy_ssl" ]; then
            echo -e "公网访问地址   : ${GREEN}https://${domain_input}${NC}"
        else
            echo -e "公网访问地址   : ${GREEN}http://${domain_input}:${custom_port}${NC}"
            echo -e "----------------------------------------------------------------------"
            echo -e "若需使用当前 VPS 已有的 Nginx 反代并配置 HTTPS，可在 Nginx 中添加："
            echo -e "${CYAN}location / {${NC}"
            echo -e "${CYAN}    proxy_pass http://127.0.0.1:${custom_port};${NC}"
            echo -e "${CYAN}    proxy_set_header Host \$host;${NC}"
            echo -e "${CYAN}    proxy_set_header X-Real-IP \$remote_addr;${NC}"
            echo -e "${CYAN}    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;${NC}"
            echo -e "${CYAN}    proxy_set_header X-Forwarded-Proto \$scheme;${NC}"
            echo -e "${CYAN}}${NC}"
        fi
        echo -e "管理员账号     : ${CYAN}${ADMIN_EMAIL_INPUT}${NC}"
        echo -e "管理员密码     : ${YELLOW}${ADMIN_PASS_INPUT}${NC}"
        echo -e "----------------------------------------------------------------------"
        echo -e "快捷管理命令   : ${BOLD}${GREEN}sub2api${NC} (在终端任何地方直接输入即可唤出管理面板)"
        echo -e "配置文件目录   : ${CYAN}${INSTALL_DIR}${NC}"
        echo -e "${PURPLE}======================================================================${NC}"
    else
        error "部署超时或异常退出！请在终端输入 'sub2api' 选择 [3] 查看容器日志排查。"
    fi
}

# --- 运维操作函数 ---
show_status() {
    title "Sub2API 服务运行状态"
    if [ ! -f "$COMPOSE_FILE" ]; then
        warn "未检测到已安装的 Sub2API 项目 (目录: ${INSTALL_DIR})。"
        return
    fi
    cd "$INSTALL_DIR"
    run_compose ps
    echo ""
    local cur_domain=$(read_env "DOMAIN")
    local cur_email=$(read_env "ADMIN_EMAIL")
    if [ -n "$cur_domain" ]; then
        echo -e "当前域名   : ${GREEN}https://${cur_domain}${NC}"
        echo -e "管理员账号 : ${CYAN}${cur_email}${NC}"
    fi
}

view_logs() {
    title "查看实时日志"
    if [ ! -f "$COMPOSE_FILE" ]; then
        error "项目尚未安装！"
        return
    fi
    cd "$INSTALL_DIR"
    echo -e "请选择要查看日志的服务:"
    echo -e "  1. 全部服务日志"
    echo -e "  2. Sub2API 核心服务"
    echo -e "  3. Caddy 网关与 HTTPS"
    echo -e "  4. Gemini 适配层"
    echo -e "  5. PostgreSQL 数据库"
    echo -e "  6. Redis 缓存"
    echo -e "  0. 返回上一级"
    read -p "请输入序号 [1-6]: " LOG_CHOICE
    case "$LOG_CHOICE" in
        1) run_compose logs -f --tail 100 ;;
        2) run_compose logs -f --tail 100 sub2api ;;
        3) run_compose logs -f --tail 100 caddy ;;
        4) run_compose logs -f --tail 100 gemini-adapter ;;
        5) run_compose logs -f --tail 100 sub2api-db ;;
        6) run_compose logs -f --tail 100 sub2api-redis ;;
        *) return ;;
    esac
}

restart_services() {
    info "正在重启 Sub2API 全部容器集群..."
    cd "$INSTALL_DIR" && run_compose restart
    success "服务重启完成！"
}

stop_services() {
    info "正在停止 Sub2API 容器集群..."
    cd "$INSTALL_DIR" && run_compose down
    success "服务已安全停止（数据已保存在磁盘持久卷中）。"
}

start_services() {
    info "正在启动 Sub2API 容器集群..."
    cd "$INSTALL_DIR" && run_compose up -d
    success "服务已启动！"
}

update_services() {
    title "在线升级 Sub2API 及组件镜像"
    cd "$INSTALL_DIR"
    info "正在拉取最新 Docker 镜像..."
    run_compose pull
    info "正在重新构建与滚动更新容器..."
    run_compose up -d --build
    success "全量镜像与服务升级完成！"
}

change_domain() {
    title "更换绑定域名与重签 HTTPS 证书"
    cd "$INSTALL_DIR"
    if [ ! -f "$ENV_FILE" ]; then
        error "未找到配置文件！"
        return
    fi
    local cur_domain=$(read_env "DOMAIN")
    local cur_adapter=$(read_env "ENABLE_ADAPTER")
    echo -e "当前配置的域名为: ${YELLOW}${cur_domain}${NC}"
    while true; do
        read -p "请输入全新的域名 (例如: api.newdomain.com): " NEW_DOMAIN
        if [[ "$NEW_DOMAIN" =~ ^[a-zA-Z0-9][-a-zA-Z0-9.]*[a-zA-Z0-9]$ ]]; then
            break
        else
            error "域名格式不合法，请重新输入！"
        fi
    done

    sed -i "s/^DOMAIN=.*/DOMAIN=\"${NEW_DOMAIN}\"/g" "$ENV_FILE"
    generate_compose "$NEW_DOMAIN" "${cur_adapter:-true}"

    info "正在重新加载容器并让 Caddy 申请新域名证书..."
    run_compose up -d --remove-orphans
    success "域名已成功更新为: https://${NEW_DOMAIN}，Caddy 正在后台自动申请 HTTPS 证书。"
}

reset_admin_password() {
    title "Sub2API 管理员密码管理"
    cd "$INSTALL_DIR"
    if [ ! -f "$ENV_FILE" ]; then
        error "未找到配置文件！"
        return
    fi
    local cur_email=$(read_env "ADMIN_EMAIL")
    echo -e "当前管理员账号: ${CYAN}${cur_email}${NC}"
    echo ""
    echo -e "${YELLOW}注意: Sub2API 的密码由数据库安全加密存储。${NC}"
    echo -e "  方法 1 (推荐): 请直接登录 Web 管理后台 -> 右上角个人中心直接修改密码。"
    echo -e "  方法 2: 若彻底忘记密码且无法登录，可通过本工具重置 .env 初始化密码并按需重建。"
    echo ""
    read -p "是否更新 .env 中的预设管理员密码？[y/N]: " UPDATE_ENV_PASS
    if [[ "$UPDATE_ENV_PASS" =~ ^[yY] ]]; then
        DEFAULT_P=$(gen_password 16)
        read -p "请输入新密码 [回车使用随机密码: ${DEFAULT_P}]: " NEW_P
        NEW_P=${NEW_P:-$DEFAULT_P}
        sed -i "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=\"${NEW_P}\"/g" "$ENV_FILE"
        success "已更新 .env 中的预设管理员密码为: ${YELLOW}${NEW_P}${NC}"
        info "请在 Web 后台使用该密码登录；如遇老库不生效，请进入后台个人资料中同步修改。"
    fi
}

backup_data() {
    title "全量数据备份 (PostgreSQL + Redis + 配置)"
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    TAR_FILE="${BACKUP_DIR}/sub2api_backup_${TIMESTAMP}.tar.gz"
    SQL_DUMP="${INSTALL_DIR}/sub2api_dump_${TIMESTAMP}.sql"

    info "正在触发 Redis 数据落盘 (SAVE)..."
    docker exec sub2api-redis redis-cli save 2>/dev/null || true

    info "正在导出 PostgreSQL 数据库 SQL 归档..."
    if ! docker exec sub2api-db pg_dump -U sub2api sub2api > "$SQL_DUMP" 2>/dev/null || [ ! -s "$SQL_DUMP" ]; then
        warn "PostgreSQL 实时导出失败或为空，将直接打包磁盘持久卷数据。"
        rm -f "$SQL_DUMP"
    fi

    info "正在打包核心数据目录与配置..."
    tar -czf "$TAR_FILE" \
        -C "$INSTALL_DIR" \
        .env \
        docker-compose.yml \
        caddy \
        data \
        postgres_data \
        redis_data \
        $( [ -f "$SQL_DUMP" ] && echo "sub2api_dump_${TIMESTAMP}.sql" ) 2>/dev/null || true

    rm -f "$SQL_DUMP"
    if [ -f "$TAR_FILE" ] && [ -s "$TAR_FILE" ]; then
        chmod 600 "$TAR_FILE"
        success "全量备份文件已生成 (已设 600 安全权限): ${GREEN}${TAR_FILE}${NC}"
        echo -e "文件大小: $(du -h "$TAR_FILE" | awk '{print $1}')"
    else
        error "备份生成失败，请检查磁盘剩余空间！"
    fi
}

uninstall_all() {
    title "彻底卸载 Sub2API 并清理数据"
    echo -e "${RED}${BOLD}⚠️ 警告: 此操作将停止并删除所有 Sub2API 容器、网络以及所有业务数据（数据库、Redis、证书等）！${NC}"
    read -p "请输入 'YES' 确认彻底卸载: " UNINSTALL_CONFIRM
    if [ "$UNINSTALL_CONFIRM" != "YES" ]; then
        info "已取消卸载操作。"
        return
    fi

    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        info "正在停止并清理容器与网络..."
        run_compose down -v --remove-orphans 2>/dev/null || true
        info "正在删除安装目录: ${INSTALL_DIR}..."
        rm -rf "$INSTALL_DIR"
        rm -f "$GLOBAL_BIN"
    fi
    success "Sub2API 已从本机彻底卸载干净！"
}

# --- 主交互菜单 ---
main_menu() {
    check_root
    detect_os

    while true; do
        clear
        echo -e "${PURPLE}======================================================================${NC}"
        echo -e "${BOLD}${CYAN}                Sub2API VPS 一键部署与运维管理平台 (v2.1)${NC}"
        echo -e "${PURPLE}======================================================================${NC}"
        local cur_domain=$(read_env "DOMAIN")
        local cur_email=$(read_env "ADMIN_EMAIL")
        local cur_adapter=$(read_env "ENABLE_ADAPTER")

        if [ -n "$cur_domain" ]; then
            local is_running=$(docker inspect --format '{{.State.Status}}' sub2api 2>/dev/null || echo "stopped")
            echo -e " 运行状态 : $([ "$is_running" = "running" ] && echo -e "${GREEN}● 运行中${NC}" || echo -e "${RED}○ 已停止${NC}")"
            echo -e " 绑定域名 : ${CYAN}https://${cur_domain}${NC}"
            echo -e " 管理账号 : ${CYAN}${cur_email}${NC}"
            echo -e " 适配层   : $([ "$cur_adapter" = "true" ] && echo -e "${GREEN}已开启 (Gemini 400/Thinking 优化)${NC}" || echo -e "${YELLOW}未启用${NC}")"
        else
            echo -e " 运行状态 : ${YELLOW}未安装${NC}"
        fi
        echo -e "----------------------------------------------------------------------"
        echo -e "  ${BOLD}1.${NC} ${GREEN}全新一键部署 Sub2API 集群 (自动配置 Caddy HTTPS / 数据库)${NC}"
        echo -e "  ${BOLD}2.${NC} 查看各容器运行状态与端口"
        echo -e "  ${BOLD}3.${NC} 查看各服务实时日志 (支持多组件分流)"
        echo -e "  ${BOLD}4.${NC} 重启全部服务"
        echo -e "  ${BOLD}5.${NC} 停止全部服务"
        echo -e "  ${BOLD}6.${NC} 启动全部服务"
        echo -e "  ${BOLD}7.${NC} 在线一键升级 Sub2API 与所有容器镜像"
        echo -e "  ${BOLD}8.${NC} 更换绑定域名 (自动重签 HTTPS 证书)"
        echo -e "  ${BOLD}9.${NC} 管理员密码说明与预设修改"
        echo -e " ${BOLD}10.${NC} 一键全量数据备份 (PostgreSQL + Redis + 配置)"
        echo -e " ${BOLD}11.${NC} ${RED}彻底卸载并清理所有数据${NC}"
        echo -e "  ${BOLD}0.${NC} 退出脚本"
        echo -e "${PURPLE}======================================================================${NC}"
        read -p "请输入菜单选项编号 [0-11]: " CHOICE
        case "$CHOICE" in
            1) deploy_wizard ;;
            2) show_status ;;
            3) view_logs ;;
            4) restart_services ;;
            5) stop_services ;;
            6) start_services ;;
            7) update_services ;;
            8) change_domain ;;
            9) reset_admin_password ;;
            10) backup_data ;;
            11) uninstall_all ;;
            0) exit 0 ;;
            *) warn "无效选项，请重新输入！" ;;
        esac
        echo ""
        read -p "按回车键继续..." DUMMY
    done
}

# --- 脚本入口 ---
main_menu

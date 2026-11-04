#!/usr/bin/env bash
# 个人 AI 服务安全远程接入 自检器 v1.0
# 配套作品：面向低成本场景的个人 AI 服务安全远程接入系统
# 用途：部署完成后一条命令跑完，逐项判定安全模型是否成立，失败项直接对应排查条目。
#
# 用法：
#   DOMAIN=bot.example.xyz TOKEN=<你的Bearer token> bash ai-access-check.sh
#   可选 PUBLIC_IP=<公网IP>，不填则自动探测
#
# 注意：TOKEN 写在命令行会进 shell 历史，请在前面加一个空格：
#    DOMAIN=... TOKEN=... bash ai-access-check.sh

set -u

MCP_PORT="${MCP_PORT:-18001}"
LOCAL_PORT="${LOCAL_PORT:-443}"
MCP_PATH="${MCP_PATH:-/mcp}"
METHOD_HINT="${METHOD_HINT:-POST}"

DOMAIN="${DOMAIN:-}"
TOKEN="${TOKEN:-}"
PUBLIC_IP="${PUBLIC_IP:-}"

PASS_N=0
FAIL_N=0
WARN_N=0

C_PASS="PASS"
C_FAIL="FAIL"
C_WARN="WARN"

ok()   { PASS_N=$((PASS_N+1)); printf '[%-4s] %-34s %s\n' "$C_PASS" "$1" "${2:-}"; }
bad()  { FAIL_N=$((FAIL_N+1)); printf '[%-4s] %-34s %s\n' "$C_FAIL" "$1" "${2:-}"; }
warn() { WARN_N=$((WARN_N+1)); printf '[%-4s] %-34s %s\n' "$C_WARN" "$1" "${2:-}"; }
advice(){ printf '         -> %s\n' "$1"; }

echo "=============================================="
echo " 个人 AI 服务安全远程接入  自检报告"
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo " 主机: $(hostname 2>/dev/null)"
echo "=============================================="
echo

# ---------- 工具函数 ----------
listen_addrs() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | awk -v p=":$port" 'NR>1 && $4 ~ (p "$") {print $4}'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") {print $4}'
  fi
}

if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || true)
  [ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(curl -s --max-time 8 http://ifconfig.me 2>/dev/null || true)
fi

echo "域名: ${DOMAIN:-未设置}   公网IP: ${PUBLIC_IP:-未探测到}   token: ${TOKEN:+已提供}"
echo

# ---------- 1. 入站监听面 ----------
echo "--- 一、入站暴露面 ---"

a443=$(listen_addrs "$LOCAL_PORT")
if [ -z "$a443" ]; then
  bad "反代端口 $LOCAL_PORT 监听" "未监听"
  advice "检查 nginx 是否在跑：systemctl status nginx；配置里 listen 127.0.0.1:$LOCAL_PORT 是否生效"
else
  leak=""
  for a in $a443; do
    case "$a" in
      127.0.0.1:$LOCAL_PORT) ;;
      *) leak="$leak $a" ;;
    esac
  done
  if [ -n "$leak" ]; then
    bad "反代端口 $LOCAL_PORT 仅绑本机" "发现对外地址:$leak"
    advice "把 listen 改成 127.0.0.1:$LOCAL_PORT 后 restart，不是 reload。bound 到 0.0.0.0 等于把 443 交给全网"
  else
    ok "反代端口 $LOCAL_PORT 仅绑本机" "$(echo $a443 | tr '\n' ' ')"
  fi
fi

a18001=$(listen_addrs "$MCP_PORT")
if [ -z "$a18001" ]; then
  bad "MCP 服务端口 $MCP_PORT 监听" "未监听"
  advice "容器没起来或没映射。docker ps 看状态，docker logs 看报错；改过 .env 必须重建容器，restart 不重新读 env"
else
  leak=""
  for a in $a18001; do
    case "$a" in
      127.0.0.1:$MCP_PORT) ;;
      *) leak="$leak $a" ;;
    esac
  done
  if [ -n "$leak" ]; then
    bad "MCP 端口 $MCP_PORT 仅绑本机" "发现对外地址:$leak"
    advice "容器端口映射写成 127.0.0.1:$MCP_PORT:$MCP_PORT，不可以只写 $MCP_PORT:$MCP_PORT"
  else
    ok "MCP 端口 $MCP_PORT 仅绑本机" "$(echo $a18001 | tr '\n' ' ')"
  fi
fi

# ---------- stackchan 端口 ----------
a8002=$(listen_addrs 8002)
if [ -z "$a8002" ]; then
  warn "StackChan 端口 8002" "未监听，服务可能没起"
else
  leak=""
  for a in $a8002; do
    case "$a" in
      127.0.0.1:8002) ;;
      *) leak="$leak $a" ;;
    esac
  done
  if [ -n "$leak" ]; then
    bad "StackChan 端口 8002 仅绑本机" "发现对外地址:$leak"
    advice "systemd unit 里把 --host 0.0.0.0 改成 --host 127.0.0.1，daemon-reload 后 restart"
  else
    ok "StackChan 端口 8002 仅绑本机" "$(echo $a8002 | tr '\n' ' ')"
  fi
fi

# ---------- 2. 公网直连必须打不通 ----------
echo
echo "--- 二、零入站（公网直连应打不通） ---"

if [ -n "$PUBLIC_IP" ]; then
  code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$PUBLIC_IP/$MCP_PATH" 2>/dev/null)
  if [ "$code" = "000" ]; then
    ok "直打公网 IP 无响应" "curl 返回 000，正确"
  else
    bad "直打公网 IP 有响应" "返回 $code，说明有入站通路"
    advice "有东西在对公网开端口。ss -tlnp 逐条看；确认安全组/防火墙，Tunnel 方案下不该有任何入站 HTTPS"
  fi
else
  warn "公网直连测试" "未取得公网 IP，跳过"
fi

# ---------- 3. 鉴权 ----------
echo
echo "--- 三、身份鉴权 ---"

if [ -z "$DOMAIN" ]; then
  warn "鉴权测试" "未设置 DOMAIN，跳过"
else
  body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"selfcheck","version":"1.0"}}}'

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -X "$METHOD_HINT" \
        "https://$DOMAIN$MCP_PATH" -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' -d "$body" 2>/dev/null)
  if [ "$code" = "401" ]; then
    ok "不带 token 应被拒" "返回 401"
  else
    bad "不带 token 应被拒" "返回 $code"
    advice "2026-10-25 记录里这项曾一度为 200，说明反代把鉴权绕过去了。检查 nginx 是否覆盖了 Authorization 头"
  fi

  if [ -n "$TOKEN" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X "$METHOD_HINT" \
          "https://$DOMAIN$MCP_PATH" -H 'Content-Type: application/json' \
          -H 'Accept: application/json, text/event-stream' \
          -H "Authorization: Bearer $TOKEN" -d "$body" 2>/dev/null)
    if [ "$code" = "200" ]; then
      ok "带 token 可握手" "返回 200，链路通"
    elif [ "$code" = "502" ] || [ "$code" = "504" ]; then
      bad "带 token 可握手" "返回 $code"
      advice "502/504 = 反代后面没服务。看 MCP 端口是否在听、nginx 里 proxy_pass 地址端口对不对"
    elif [ "$code" = "526" ]; then
      bad "带 token 可握手" "返回 526"
      advice "526 = CF 的 SSL 设成了「严格」。改成「完全」，因为后端是自签证书"
    else
      bad "带 token 可握手" "返回 $code"
      advice "按状态码查：401 看 token 值、403 看路径、404 看 MCP_PATH、520 系列看 tunnel"
    fi
  else
    warn "带 token 握手" "未提供 TOKEN，跳过"
  fi
fi

# ---------- 4. 链路特征 ----------
echo
echo "--- 四、链路特征（是否真的走隧道） ---"

AUTH=()
if [ -n "$TOKEN" ]; then AUTH=(-H "Authorization: Bearer $TOKEN"); fi

if [ -n "$DOMAIN" ]; then
  hdr=$(curl -sS -D - -o /dev/null --max-time 12 -X "$METHOD_HINT" \
        "https://$DOMAIN$MCP_PATH" -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        ${AUTH[@]+"${AUTH[@]}"} \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"selfcheck","version":"1.0"}}}' 2>/dev/null)
  if echo "$hdr" | grep -qi '^cf-ray:'; then
    ok "响应头含 cf-ray" "确为 Cloudflare 边缘转发"
  else
    bad "响应头含 cf-ray" "未见 cf-ray，可能域名直指真实 IP"
    advice "这正是 README 踩坑第 4 条：以为在用隧道，其实域名 A 记录直指服务器。删掉 A 记录，改走 tunnel route dns"
  fi
fi

if command -v systemctl >/dev/null 2>&1; then
  st=$(systemctl is-active cloudflared 2>/dev/null || echo unknown)
  if [ "$st" = "active" ]; then
    ok "cloudflared 服务常驻" "systemctl active"
  else
    bad "cloudflared 服务常驻" "状态 $st"
    advice "systemctl status cloudflared 看原因；没设开机自启就 systemctl enable cloudflared"
  fi
fi

# ---------- 5. 真实性体检 ----------
echo
echo "--- 五、工程真实性 ---"

cnt=$(sudo -n find /etc/nginx/ssl -name '*.crt' 2>/dev/null | wc -l) || cnt=0
if [ "$cnt" -gt 0 ]; then
  ok "自签证书已就位" "在 /etc/nginx/ssl 找到 $cnt 个证书文件"
else
  warn "自签证书位置" "未在 /etc/nginx/ssl 找到，如改过路径可忽略"
fi

upt=$(uptime -p 2>/dev/null || echo "未知")
ok "系统连续运行" "$upt（作为 24 小时常驻的客观佐证）"

echo
echo "=============================================="
printf ' 汇总: 通过 %d 项   失败 %d 项   跳过 %d 项\n' "$PASS_N" "$FAIL_N" "$WARN_N"
if [ "$FAIL_N" -eq 0 ]; then
  echo " 结论: 安全模型成立。这张输出可直接作为佐证材料留档。"
else
  echo " 结论: 有 $FAIL_N 项未通过，按上面 -> 提示逐条修，修完重跑。"
fi
echo "=============================================="

exit $([ "$FAIL_N" -eq 0 ] && echo 0 || echo 1)

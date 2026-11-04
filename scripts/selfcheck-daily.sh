#!/bin/bash
# 每日自检包装脚本，配合 ai-access-check.sh 使用
# 挂进 crontab：20 3 * * * /bin/bash /home/ubuntu/selfcheck-daily.sh

# ===== 按自己的情况改这四行 =====
DOMAIN=your-domain.xyz
PUBLIC_IP=""
MCP_PATH=/mcp

# token 从 env 文件里读，不要把明文写在这个脚本里
ENV_FILE=/home/ubuntu/ombre.env
ENV_KEY=OMBRE_MCP_TOKEN

# 脚本来源：token 在 env 里时用 sudo 读，改成你自己的路径
SUDO="sudo -n"
# ================================

LOG=/home/ubuntu/selfcheck.log
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOKEN=$($SUDO grep "^${ENV_KEY}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2-)

STAMP=$(date "+%Y-%m-%d %H:%M:%S")

DOMAIN="$DOMAIN" PUBLIC_IP="$PUBLIC_IP" MCP_PATH="$MCP_PATH" TOKEN="$TOKEN" \
  bash "$SCRIPT_DIR/ai-access-check.sh" >> "$LOG" 2>&1

RC=$?
echo "----- $STAMP exit=$RC -----" >> "$LOG"

exit $RC
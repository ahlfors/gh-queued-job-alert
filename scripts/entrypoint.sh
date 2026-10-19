#!/bin/bash
###############################################################################
# 容器入口脚本
# 1. 校验必要环境变量
# 2. 导出环境变量供 cron 子进程使用
# 3. 动态生成 crontab
# 4. 首次启动立即执行一次检查
# 5. 前台运行 crond（保持容器存活）
###############################################################################

set -e

echo "============================================="
echo "  GitHub Queued Job Alert Container"
echo "  Starting at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "============================================="

REQUIRED_VARS=("GITHUB_TOKEN" "GITHUB_REPOS" "FEISHU_WEBHOOK_URL")
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "[FATAL] Required environment variable '${var}' is not set!"
    exit 1
  fi
done

echo "[INFO] Repos             : ${GITHUB_REPOS}"
echo "[INFO] Default QUEUED_JOB_NUM (only if a repo has no :N): ${QUEUED_JOB_NUM:-10}"
echo "[INFO] Cooldown          : ${ALERT_COOLDOWN_SECONDS:-600}s"
echo "[INFO] Cron Schedule     : ${CHECK_CRON_SCHEDULE:-*/3 * * * *}"
echo "[INFO] Timezone          : ${TZ:-UTC}"
echo ""

ENV_FILE="/app/state/container.env"
cat > "$ENV_FILE" <<EOF
GITHUB_TOKEN="${GITHUB_TOKEN}"
GITHUB_REPOS="${GITHUB_REPOS}"
QUEUED_JOB_NUM="${QUEUED_JOB_NUM:-10}"
ALERT_COOLDOWN_SECONDS="${ALERT_COOLDOWN_SECONDS:-600}"
FEISHU_WEBHOOK_URL="${FEISHU_WEBHOOK_URL}"
TZ="${TZ:-Asia/Shanghai}"
EOF
chmod 600 "$ENV_FILE"

STATE_FILE="/app/state/alert_state.json"
if [ ! -f "$STATE_FILE" ]; then
  echo '{}' > "$STATE_FILE"
  echo "[INFO] Initialized state file"
fi

mkdir -p /app/logs
touch /app/logs/queued-job-alert.log

CRON_SCHEDULE="${CHECK_CRON_SCHEDULE:-*/3 * * * *}"
CRON_FILE="/etc/crontabs/root"

cat > "$CRON_FILE" <<EOF
# GitHub Queued Job Alert — Schedule: ${CRON_SCHEDULE}
${CRON_SCHEDULE} /bin/bash -c 'source /app/state/container.env && /app/scripts/queued_job_alert.sh >> /app/logs/queued-job-alert.log 2>&1'
EOF

echo "[INFO] Crontab installed:"
cat "$CRON_FILE"
echo ""

echo "[INFO] Running initial check..."
/bin/bash -c "source /app/state/container.env && /app/scripts/queued_job_alert.sh" 2>&1 | tee -a /app/logs/queued-job-alert.log
echo ""
echo "[INFO] Initial check complete. Starting cron daemon..."
echo "============================================="

exec crond -f -l 2

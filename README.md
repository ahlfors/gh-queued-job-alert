# gh-queued-job-alert

Docker Compose 服务：按 `.env` 里的仓库列表，**每个仓库单独**统计排队 GitHub Actions job 数（`QUEUED_JOB_NUM`），超阈值发飞书卡片。

```
gh-queued-job-alert/
├── docker-compose.yml
├── Dockerfile
├── .env.example
├── scripts/
│   ├── entrypoint.sh
│   └── queued_job_alert.sh
└── crontab/
    └── queued-job-alert-cron
```

## 行为

- `GITHUB_REPOS=owner/a:3,owner/b:5`：逗号分隔，**按仓**拉 runs/jobs，**按仓阈值**比较，**按仓**冷却。
- 超阈值发 **一张卡片**（header 带仓库名）。不会把多个仓合成一张。
- 阈值的 2 倍以上用红色 critical，否则橙色 warning。
- 低于阈值只打日志，不发「恢复」卡片（和 load-alert 一样）。

Job 过滤：

1. runs `status=queued|waiting|in_progress`
2. `GET .../jobs?filter=latest`
3. 留下 job status `queued|waiting|pending|requested`

## Deployment

```bash
git clone https://github.com/ahlfors/gh-queued-job-alert.git
cd gh-queued-job-alert
cp .env.example .env
vim .env
docker compose up -d --build
```

`.env` 必填：

```
GITHUB_TOKEN=ghp_...
GITHUB_REPOS=org1/repo1:3,org1/repo2:5
QUEUED_JOB_NUM=10   # 仅当某仓没写 :N 时使用
ALERT_COOLDOWN_SECONDS=600
FEISHU_WEBHOOK_URL=https://open.feishu.cn/open-apis/bot/v2/hook/...
CHECK_CRON_SCHEDULE=*/3 * * * *
TZ=Asia/Shanghai
```

Token 需要对每个仓库 `actions:read`（私有仓还要 `repo`）。

## Maintance Commands

```bash
docker compose ps
docker compose logs -f

docker compose exec queued-job-alert tail -f /app/logs/queued-job-alert.log

docker compose exec queued-job-alert bash -c \
  'source /app/state/container.env && /app/scripts/queued_job_alert.sh'

docker compose exec queued-job-alert cat /app/state/alert_state.json

docker compose exec queued-job-alert bash -c 'echo "{}" > /app/state/alert_state.json'

vim .env && docker compose up -d --build
docker compose down
docker compose down -v
```

`alert_state.json` 按仓库分 key：

```json
{
  "org1/repo1": {
    "last_alert_time": 1760000000,
    "last_queued": 23,
    "consecutive_high_count": 2
  }
}
```

## 和两个参考项目的关系

| | gh-queued-job | self-hosted-runner-load-alert | 本仓库 |
|---|---|---|---|
| 对象 | 单个 repo 的 queued jobs | org 全部 runner 忙闲比 | **多个 repo** 的 queued job 数 |
| 交互 | TUI / CLI | cron + 飞书 | cron + 飞书 |
| 部署 | `gh extension` | `docker compose` | `docker compose` |
| 阈值 | 无 | `ALERT_THRESHOLD` % | 每仓 `owner/repo:N` |

不要用 `--org` 扫全 org。没有「org 级 queued jobs」便宜接口；列表必须显式写在 `GITHUB_REPOS`。

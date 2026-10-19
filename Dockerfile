FROM alpine:3.20

LABEL maintainer="@ahlfors"
LABEL description="GitHub queued-job alert with Feishu notification, per repository"

RUN apk add --no-cache \
    bash \
    curl \
    jq \
    tzdata \
    && rm -rf /var/cache/apk/*

ENV TZ=Asia/Shanghai

RUN mkdir -p /app/scripts /app/state /app/logs /app/crontab

COPY scripts/queued_job_alert.sh /app/scripts/
COPY scripts/entrypoint.sh       /app/scripts/
COPY crontab/queued-job-alert-cron /app/crontab/

RUN chmod +x /app/scripts/*.sh

WORKDIR /app

ENTRYPOINT ["/app/scripts/entrypoint.sh"]

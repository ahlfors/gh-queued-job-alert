#!/bin/bash
###############################################################################
# GitHub Queued Job Alert (Containerized)
#
# 按 .env 里 GITHUB_REPOS 的每个 owner/repo[:N] 独立统计排队 job。
# 阈值按仓：org1/repo1:3,org1/repo2:5
# 没写 :N 才用 QUEUED_JOB_NUM 默认值。超过该仓阈值发一张飞书卡片。冷却按仓库分开。
#
# 排队判定对齐 gh-queued-job：
#   runs:  queued | waiting | in_progress
#   jobs:  queued | waiting | pending | requested
#   jobs filter=latest
###############################################################################

set -euo pipefail

GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
GITHUB_REPOS="${GITHUB_REPOS:?GITHUB_REPOS is required}"
QUEUED_JOB_NUM="${QUEUED_JOB_NUM:-10}"
ALERT_COOLDOWN_SECONDS="${ALERT_COOLDOWN_SECONDS:-600}"
FEISHU_WEBHOOK_URL="${FEISHU_WEBHOOK_URL:?FEISHU_WEBHOOK_URL is required}"

STATE_FILE="/app/state/alert_state.json"
LOG_PREFIX="[$(date -u +%Y-%m-%dT%H:%M:%SZ)]"
API_BASE="https://api.github.com"
PER_PAGE=100

mkdir -p "$(dirname "$STATE_FILE")"
if [ ! -f "$STATE_FILE" ]; then
  echo '{}' > "$STATE_FILE"
fi

gh_get() {
  local path="$1"
  local response http_code body
  response=$(curl -sS -w "\n%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: gh-queued-job-alert" \
    "${API_BASE}/${path}")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')
  if [ "$http_code" -ne 200 ]; then
    echo "${LOG_PREFIX} [ERROR] GET ${path} HTTP ${http_code}" >&2
    echo "$body" | jq . 2>/dev/null >&2 || echo "$body" >&2
    return 1
  fi
  echo "$body"
}

fetch_runs() {
  local owner="$1" repo="$2" status="$3"
  local page=1 all="[]"
  while true; do
    local body
    body=$(gh_get "repos/${owner}/${repo}/actions/runs?status=${status}&per_page=${PER_PAGE}&page=${page}") || return 1
    local runs count
    runs=$(echo "$body" | jq '.workflow_runs // []')
    count=$(echo "$runs" | jq 'length')
    all=$(echo "$all" "$runs" | jq -s 'add')
    if [ "$count" -lt "$PER_PAGE" ]; then
      break
    fi
    page=$((page + 1))
  done
  echo "$all"
}

fetch_jobs() {
  local owner="$1" repo="$2" run_id="$3"
  local page=1 all="[]"
  while true; do
    local body
    body=$(gh_get "repos/${owner}/${repo}/actions/runs/${run_id}/jobs?filter=latest&per_page=${PER_PAGE}&page=${page}") || return 1
    local jobs count
    jobs=$(echo "$body" | jq '.jobs // []')
    count=$(echo "$jobs" | jq 'length')
    all=$(echo "$all" "$jobs" | jq -s 'add')
    if [ "$count" -lt "$PER_PAGE" ]; then
      break
    fi
    page=$((page + 1))
  done
  echo "$all"
}

collect_queued_jobs() {
  local owner="$1" repo="$2"
  local seen_ids="[]"
  local queued="[]"
  local status runs

  for status in queued waiting in_progress; do
    runs=$(fetch_runs "$owner" "$repo" "$status") || return 1
    local n i run_id
    n=$(echo "$runs" | jq 'length')
    for ((i=0; i<n; i++)); do
      run_id=$(echo "$runs" | jq -r ".[$i].id")
      if echo "$seen_ids" | jq -e --argjson id "$run_id" 'index($id) != null' >/dev/null; then
        continue
      fi
      seen_ids=$(echo "$seen_ids" | jq --argjson id "$run_id" '. + [$id]')
      local workflow_name run_url jobs
      workflow_name=$(echo "$runs" | jq -r ".[$i].name // \"-\"")
      run_url=$(echo "$runs" | jq -r ".[$i].html_url // \"\"")
      jobs=$(fetch_jobs "$owner" "$repo" "$run_id") || continue
      local filtered
      filtered=$(echo "$jobs" | jq --arg wf "$workflow_name" --arg ru "$run_url" --arg repo "${owner}/${repo}" '
        [.[] | select(.status == "queued" or .status == "waiting" or .status == "pending" or .status == "requested")
         | {
             id, run_id, name, status, labels,
             workflow_name: $wf,
             repository: $repo,
             created_at,
             html_url,
             run_url: $ru
           }]
      ')
      queued=$(echo "$queued" "$filtered" | jq -s 'add')
    done
  done
  echo "$queued"
}

repo_state() {
  local repo="$1"
  jq -c --arg r "$repo" '.[$r] // {last_alert_time:0, last_queued:0, consecutive_high_count:0}' "$STATE_FILE"
}

write_repo_state() {
  local repo="$1" json="$2"
  jq --arg r "$repo" --argjson s "$json" '.[$r]=$s' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

is_in_cooldown() {
  local repo="$1"
  local last now elapsed remaining
  last=$(repo_state "$repo" | jq -r '.last_alert_time // 0')
  now=$(date +%s)
  elapsed=$((now - last))
  if [ "$elapsed" -lt "$ALERT_COOLDOWN_SECONDS" ]; then
    remaining=$(( (ALERT_COOLDOWN_SECONDS - elapsed) / 60 ))
    echo "${LOG_PREFIX} [COOLDOWN] ${repo} remaining: ${remaining}min"
    return 0
  fi
  return 1
}

send_feishu_alert() {
  local repo="$1"
  local queued_count="$2"
  local threshold="$3"
  local severity="$4"
  local details="$5"
  local status_counts="$6"

  local template_color title_text icon
  if [ "$severity" = "critical" ]; then
    template_color="red"
    title_text="🚨 Queued Job 严重积压"
    icon="🔴"
  else
    template_color="orange"
    title_text="⚠️ Queued Job 积压告警"
    icon="🟠"
  fi

  local bar_filled bar_empty bar_str ratio
  if [ "$threshold" -le 0 ]; then
    ratio=100
  else
    ratio=$(( queued_count * 100 / threshold ))
  fi
  if [ "$ratio" -gt 100 ]; then
    ratio=100
  fi
  bar_filled=$(( ratio / 5 ))
  bar_empty=$(( 20 - bar_filled ))
  bar_str=""
  local i
  for ((i=0; i<bar_filled; i++)); do bar_str+="🟥"; done
  for ((i=0; i<bar_empty; i++)); do bar_str+="⬜"; done

  local repo_url alert_time cooldown_min
  repo_url="https://github.com/${repo}/actions"
  alert_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
  cooldown_min=$((ALERT_COOLDOWN_SECONDS / 60))

  local card_json
  card_json=$(jq -n \
    --arg title "$title_text" \
    --arg subtitle "gh-queued-job-alert | ${repo}" \
    --arg color "$template_color" \
    --arg headline "${icon} **${repo}** 排队 Job 数 **${queued_count}**，超过该仓阈值 **${threshold}**" \
    --arg bar "**相对阈值**:\n${bar_str}  **${queued_count}/${threshold}**" \
    --arg status_md "📊 **按状态**\n\n${status_counts}" \
    --arg details_md "📋 **排队 Job（最多 15 条）**:\n${details}" \
    --arg link_md "🔗 [打开 Actions](${repo_url})" \
    --arg footer "⏰ **告警时间**: ${alert_time}\n📌 **该仓阈值 QUEUED_JOB_NUM**: ${threshold}  |  🔄 **冷却期**: ${cooldown_min} 分钟（按仓库）\n🐳 **运行环境**: Docker Container" \
    '{
      msg_type: "interactive",
      card: {
        schema: "2.0",
        config: {update_multi: true},
        header: {
          title: {tag: "plain_text", content: $title},
          subtitle: {tag: "plain_text", content: $subtitle},
          template: $color,
          padding: "12px 12px 12px 12px"
        },
        body: {
          direction: "vertical",
          padding: "12px 12px 12px 12px",
          elements: [
            {tag: "markdown", content: $headline, text_align: "left", text_size: "normal"},
            {tag: "markdown", content: $bar, text_size: "normal", margin: "8px 0px 0px 0px"},
            {
              tag: "column_set", flex_mode: "none", horizontal_spacing: "default",
              columns: [{tag: "column", width: "weighted", weight: 1, elements: [{tag: "markdown", content: $status_md, text_size: "normal"}]}],
              margin: "8px 0px 0px 0px"
            },
            {
              tag: "column_set", flex_mode: "none", background_style: "grey", horizontal_spacing: "default",
              columns: [{tag: "column", width: "weighted", weight: 1, elements: [{tag: "markdown", content: $details_md, text_size: "notation"}]}],
              margin: "8px 0px 0px 0px"
            },
            {tag: "markdown", content: $link_md, text_size: "notation", margin: "8px 0px 0px 0px"},
            {tag: "hr"},
            {tag: "markdown", content: $footer, text_size: "notation"}
          ]
        }
      }
    }')

  local response resp_code resp_body
  response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "${card_json}" \
    "${FEISHU_WEBHOOK_URL}" 2>&1) || true
  resp_code=$(echo "$response" | tail -n1)
  resp_body=$(echo "$response" | sed '$d')
  if [ "$resp_code" = "200" ]; then
    echo "${LOG_PREFIX} [FEISHU] ${repo} sent (queued=${queued_count}, severity=${severity})"
  else
    echo "${LOG_PREFIX} [FEISHU] ${repo} failed HTTP ${resp_code}: ${resp_body}"
  fi
}

parse_repo_spec() {
  local spec="$1"
  local repo_part threshold
  if [[ "$spec" == *:* ]]; then
    repo_part="${spec%:*}"
    threshold="${spec##*:}"
  else
    repo_part="$spec"
    threshold=""
  fi
  if [[ ! "$repo_part" =~ ^[^/]+/[^/]+$ ]]; then
    echo "${LOG_PREFIX} [ERROR] invalid repo '${spec}', use owner/repo or owner/repo:N"
    return 1
  fi
  if [ -z "$threshold" ]; then
    threshold="${QUEUED_JOB_NUM}"
  fi
  if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
    echo "${LOG_PREFIX} [ERROR] invalid QUEUED_JOB_NUM for '${spec}': '${threshold}'"
    return 1
  fi
  printf '%s %s\n' "$repo_part" "$threshold"
}

check_repo() {
  local spec="$1"
  local parsed owner repo full threshold
  parsed=$(parse_repo_spec "$spec") || return 1
  full="${parsed%% *}"
  threshold="${parsed##* }"
  owner="${full%%/*}"
  repo="${full#*/}"
  echo "${LOG_PREFIX} [INFO] Checking ${full} threshold=${threshold} ..."

  local jobs
  jobs=$(collect_queued_jobs "$owner" "$repo") || {
    echo "${LOG_PREFIX} [ERROR] ${full} fetch failed"
    return 1
  }

  local queued_count
  queued_count=$(echo "$jobs" | jq 'length')
  echo "${LOG_PREFIX} [INFO] ${full} queued=${queued_count} threshold=${threshold}"

  local status_counts
  status_counts=$(echo "$jobs" | jq -r '
    (group_by(.status) | map("- \(. [0].status): **\(length)**") | join("\n"))
    as $g | if $g == "" then "- (none)" else $g end
  ')

  local details now_ts
  now_ts=$(date +%s)
  details=$(echo "$jobs" | jq -r --argjson now "$now_ts" '
    def wait:
      (try (.created_at | fromdateiso8601) catch $now) as $c
      | ([$now - $c, 0] | max) as $d
      | if $d >= 3600 then
          "\((($d/3600)|floor)|tostring|if length<2 then "0"+. else . end):\(((($d%3600)/60)|floor)|tostring|if length<2 then "0"+. else . end):\((($d%60)|floor)|tostring|if length<2 then "0"+. else . end)"
        else
          "\(((($d%3600)/60)|floor)|tostring|if length<2 then "0"+. else . end):\((($d%60)|floor)|tostring|if length<2 then "0"+. else . end)"
        end;
    sort_by(.created_at) | .[:15][] |
    "• \(wait)  \(.status)  \(.workflow_name) / \(.name)  [\((.labels // []) | join(","))]"
  ')
  local extra
  extra=$((queued_count - 15))
  if [ "$extra" -gt 0 ]; then
    details+=$'\n'"... 还有 ${extra} 个排队 Job"
  fi
  if [ -z "$details" ]; then
    details="(none)"
  fi

  local now state consecutive
  now=$(date +%s)
  state=$(repo_state "$full")

  if [ "$queued_count" -ge "$threshold" ]; then
    echo "${LOG_PREFIX} [ALERT] ${full} ${queued_count} >= ${threshold}"
    consecutive=$(echo "$state" | jq -r '.consecutive_high_count // 0')
    consecutive=$((consecutive + 1))
    local severity="warning"
    if [ "$queued_count" -ge $((threshold * 2)) ]; then
      severity="critical"
    fi
    if is_in_cooldown "$full"; then
      echo "${LOG_PREFIX} [INFO] ${full} suppressed, consecutive=${consecutive}"
      state=$(echo "$state" | jq --argjson c "$consecutive" --argjson q "$queued_count" --argjson t "$threshold" '.consecutive_high_count=$c | .last_queued=$q | .threshold=$t')
      write_repo_state "$full" "$state"
    else
      send_feishu_alert "$full" "$queued_count" "$threshold" "$severity" "$details" "$status_counts"
      state=$(echo "$state" | jq --argjson ts "$now" --argjson q "$queued_count" --argjson c "$consecutive" --argjson t "$threshold" \
        '.last_alert_time=$ts | .last_queued=$q | .consecutive_high_count=$c | .threshold=$t')
      write_repo_state "$full" "$state"
    fi
  else
    echo "${LOG_PREFIX} [OK] ${full} ${queued_count} < ${threshold}"
    consecutive=$(echo "$state" | jq -r '.consecutive_high_count // 0')
    if [ "$consecutive" -gt 0 ] || [ "$(echo "$state" | jq -r '.last_queued // 0')" != "0" ]; then
      echo "${LOG_PREFIX} [INFO] ${full} cleared (was consecutive ${consecutive})"
    fi
    state=$(echo "$state" | jq --argjson q "$queued_count" --argjson t "$threshold" '.consecutive_high_count=0 | .last_queued=$q | .threshold=$t')
    write_repo_state "$full" "$state"
  fi
}

main() {
  echo ""
  echo "=========================================="
  echo "${LOG_PREFIX} Queued Job Alert Check"
  echo "${LOG_PREFIX} repos=${GITHUB_REPOS} default_threshold=${QUEUED_JOB_NUM}"
  echo "=========================================="

  local raw spec
  raw="${GITHUB_REPOS//,/ }"
  for spec in $raw; do
    spec="${spec// /}"
    [ -z "$spec" ] && continue
    check_repo "$spec" || true
  done

  echo "${LOG_PREFIX} [DONE] Check complete"
}

main "$@"

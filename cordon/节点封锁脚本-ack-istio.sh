#!/bin/bash
# 此脚本运行在ansible控制节点上，主要用于在k8s集群中进行节点封锁操作
# 没有实时封锁节点功能，脚本功能相对粗糙，颗粒度和指标获取准确率低
# ==============================================================================
# dev-node-crond.sh — K8s 节点动态封锁（单次执行版）
# 功能: 检查 eng 节点内存，MEM>=50% 封锁，MEM<=40% 解封
# 运行方式: 由 crontab 调度，执行完即退出（不是常驻进程）
#   cron: */10 6-11 * * * root /opt/scripts/k8s/dev-node-crond.sh >> /var/log/node-cordon.log 2>&1
# ==============================================================================

set -uo pipefail

KUBECTL_CMD="/usr/local/bin/kubectl --kubeconfig=/home/wuser/.kube/config-istio-prod-ack"
NODE_FILTER="eng"
MEM_CORDON_THRESHOLD=75
#封锁阈值
MEM_UNCORDON_THRESHOLD=50
#解锁阈值
CORDON_LIMIT=4
#封锁节点上限
LOG="/home/wuser/crontab/log/prod-node-cordon.log"
ALERT_WEBHOOK="https://oapi.dingtalk.com/robot/send?access_token=90c3748f572eb49493e8667d884e545eede72a6134cbc6d2ee35799cabcfe030"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

send_alert() {
  [ -z "$ALERT_WEBHOOK" ] && return
  local msg="$1"
  local json_msg
  json_msg=$(echo "$msg" | sed 's/"/\\"/g')
  curl -s -X POST "$ALERT_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"${json_msg}\"}}" &>/dev/null
}

# ========== 获取节点内存指标 ==========
NODE_METRICS_FILE=$(mktemp)
${KUBECTL_CMD} top node 2>/dev/null | grep "$NODE_FILTER" | awk '{
  gsub(/%/,"",$5);
  if (NF >= 5) print $1, $5
}' | sort -k2 -rn > "$NODE_METRICS_FILE"
#节点排序逻辑

if [ ! -s "$NODE_METRICS_FILE" ]; then
  log "WARN: 未获取到节点指标，跳过"
  rm -f "$NODE_METRICS_FILE"
  exit 0
fi

# ========== 统计已封锁节点数 ==========
ALREADY_CORDONED=$(${KUBECTL_CMD} get nodes --no-headers 2>/dev/null \
  | grep "$NODE_FILTER" | grep "SchedulingDisabled" | wc -l)

# ========== 阶段1: 超阈值 → 封锁 ==========
CORDONED_LIST=""

while read -r node mem_pct; do
  [ -z "$node" ] && continue
  mem_int=${mem_pct%.*}

  STATUS=$(${KUBECTL_CMD} get node "$node" --no-headers 2>/dev/null | awk '{print $2}')
  echo "$STATUS" | grep -q "SchedulingDisabled" && continue

  if [ "$mem_int" -ge "$MEM_CORDON_THRESHOLD" ]; then
    if [ "$ALREADY_CORDONED" -ge "$CORDON_LIMIT" ]; then
      log "WARN: $node MEM=${mem_pct}% 超阈值，但已达封锁上限($CORDON_LIMIT)，跳过"
      continue
    fi
    ${KUBECTL_CMD} cordon "$node" 2>/dev/null && {
      ALREADY_CORDONED=$((ALREADY_CORDONED + 1))
      CORDONED_LIST="${CORDONED_LIST}${node}(MEM:${mem_pct}%) "
      log "CORDON: $node (MEM=${mem_pct}%)"
    } || {
      log "ERR: $node 封锁失败"
    }
  fi
done < "$NODE_METRICS_FILE"
rm -f "$NODE_METRICS_FILE"

# ========== 阶段2: 已封锁且内存恢复 → 解封 ==========
UNCORDONED_LIST=""

CORDONED_NODES=$(${KUBECTL_CMD} get nodes --no-headers 2>/dev/null \
  | grep "$NODE_FILTER" | grep "SchedulingDisabled" | awk '{print $1}')

for node in $CORDONED_NODES; do
  node_mem=$(${KUBECTL_CMD} top node "$node" --no-headers 2>/dev/null | awk '{gsub(/%/,"",$5); print $5}')
  [ -z "$node_mem" ] && { log "WARN: 无法获取 $node 内存指标，跳过"; continue; }
  node_mem_int=${node_mem%.*}
  if [ "$node_mem_int" -le "$MEM_UNCORDON_THRESHOLD" ]; then
    ${KUBECTL_CMD} uncordon "$node" 2>/dev/null && {
      UNCORDONED_LIST="${UNCORDONED_LIST}${node}(MEM:${node_mem}%) "
      log "UNCORDON: $node (MEM=${node_mem}% 已恢复)"
    } || {
      log "ERR: $node 解封失败"
    }
  fi
done

# ========== 统一发送一次告警 ==========
if [ -n "$CORDONED_LIST" ] || [ -n "$UNCORDONED_LIST" ]; then
  TOP_DATA=$(${KUBECTL_CMD} top node --no-headers 2>/dev/null | grep "$NODE_FILTER" | awk '{
    printf "%s CPU:%s MEM:%s\n", $1, $3, $5
  }')
  CORDON_DATA=$(${KUBECTL_CMD} get nodes --no-headers 2>/dev/null | grep "$NODE_FILTER" | awk '{
    if ($2 ~ /SchedulingDisabled/) status="已封锁"; else status="正常"
    print $1, status
  }')
  CLUSTER_STATUS=$(echo "$TOP_DATA" | while read -r line; do
    n=$(echo "$line" | awk '{print $1}')
    s=$(echo "$CORDON_DATA" | grep "$n" | awk '{print $2}')
    echo "${line}  ${s}"
  done)
  CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')

  ALERT_MSG=""
  [ -n "$CORDONED_LIST" ] && ALERT_MSG="${ALERT_MSG}[K8s节点封锁] 封锁数: ${ALREADY_CORDONED}/${CORDON_LIMIT} | ${CORDONED_LIST}
"
  [ -n "$UNCORDONED_LIST" ] && ALERT_MSG="${ALERT_MSG}[K8s节点解封锁] 解封: ${UNCORDONED_LIST}
"
  ALERT_MSG="${ALERT_MSG}--- 当前集群状态 ${CURRENT_TIME} ---
${CLUSTER_STATUS}"

  send_alert "$ALERT_MSG"
fi

log "--- 巡检完成 (已封锁: ${ALREADY_CORDONED}/${CORDON_LIMIT}) ---"
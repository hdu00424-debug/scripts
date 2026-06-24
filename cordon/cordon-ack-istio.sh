#!/bin/bash
# 实现功能：
# 耦合在k8s中进行实时检测封锁
# 每10min检查内存使用率然后进行检查，封锁达到阈值的节点
# 如果有半数以上的节点达到封锁的阈值，则触发报警
set -euo pipefail
KUBECTL_CMD=''
NODE
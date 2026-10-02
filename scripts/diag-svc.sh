#!/usr/bin/env bash
# diag-svc.sh — Kubernetes Service 连不通时的四步排障
#
# 用法: ./scripts/diag-svc.sh <service> [namespace] [client-pod]
#   client-pod 可选：提供后会从该 Pod 内实测 DNS 与 HTTP
#
# 设计原则：每一步只回答一个问题，且顺序不可换——
#   1 Service 在不在、selector 是什么
#   2 EndpointSlice 里有没有 Ready 的后端   ← 信息密度最高，所以放前面
#   3 匹配 selector 的 Pod 处于什么状态
#   4 DNS 与 NetworkPolicy 这两个"隔了一层"的元凶

set -uo pipefail

SVC="${1:?用法: $0 <service> [namespace] [client-pod]}"
NS="${2:-default}"
CLIENT="${3:-}"

ok()   { printf '  \033[32mOK \033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mNG \033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }
step() { printf '\n\033[1m=== [%s] %s ===\033[0m\n' "$1" "$2"; }

printf '\n诊断目标: service/%s  namespace/%s\n' "$SVC" "$NS"

# ---------- 第 1 步 ----------
step 1 "Service 对象与 selector"
if ! kubectl -n "$NS" get svc "$SVC" >/dev/null 2>&1; then
  bad "Service $NS/$SVC 不存在 —— 名字或命名空间写错了"
  exit 1
fi
CIP=$(kubectl -n "$NS" get svc "$SVC" -o jsonpath='{.spec.clusterIP}')
TYPE=$(kubectl -n "$NS" get svc "$SVC" -o jsonpath='{.spec.type}')
PORTS=$(kubectl -n "$NS" get svc "$SVC" -o jsonpath='{range .spec.ports[*]}{.port}->{.targetPort}/{.protocol} {end}')
ok "type=$TYPE  clusterIP=$CIP  ports=[ $PORTS]"
[ "$CIP" = "None" ] && info "Headless Service：DNS 直接返回 Pod IP，没有 iptables 转发"

SEL=$(kubectl -n "$NS" get svc "$SVC" \
      -o go-template='{{range $k,$v := .spec.selector}}{{$k}}={{$v}},{{end}}' | sed 's/,$//')
if [ -z "$SEL" ]; then
  info "无 selector（ExternalName 或手工维护 Endpoints），跳过第 3 步"
else
  ok "selector = $SEL"
fi

# ---------- 第 2 步 ----------
step 2 "EndpointSlice —— 谁真正在后面接流量"
if [ -z "$(kubectl -n "$NS" get endpointslice -l kubernetes.io/service-name="$SVC" -o name 2>/dev/null)" ]; then
  bad "没有任何 EndpointSlice：名字能解析，但后面一个人都没有"
  info "→ 典型表现是 curl 立刻 connection refused (exit 7)"
else
  READY=$(kubectl -n "$NS" get endpointslice -l kubernetes.io/service-name="$SVC" \
          -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]} {end}')
  NOTREADY=$(kubectl -n "$NS" get endpointslice -l kubernetes.io/service-name="$SVC" \
          -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==false)]}{.addresses[0]} {end}')
  if [ -n "${READY// /}" ]; then ok "Ready 后端: $READY"
  else bad "Ready 后端数为 0"; fi
  if [ -n "${NOTREADY// /}" ]; then
    bad "NotReady 后端: $NOTREADY"
    info "→ readinessProbe 没过，已被摘流量。查: kubectl -n $NS describe pod <name>"
  fi
fi

# ---------- 第 3 步 ----------
step 3 "匹配 selector 的 Pod"
if [ -n "$SEL" ]; then
  if [ -z "$(kubectl -n "$NS" get pods -l "$SEL" -o name 2>/dev/null)" ]; then
    bad "没有 Pod 匹配 [$SEL] —— 绝大多数是 selector 和 Pod label 对不上"
    info "对照实际 label: kubectl -n $NS get pods --show-labels"
  else
    kubectl -n "$NS" get pods -l "$SEL" \
      -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,PHASE:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount,IP:.status.podIP,NODE:.spec.nodeName'
  fi
fi

# ---------- 第 4 步 ----------
step 4 "DNS 与 NetworkPolicy（两个隔了一层的元凶）"
if kubectl -n kube-system get svc kube-dns >/dev/null 2>&1; then
  ok "kube-dns Service 存在 ($(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}'))"
else
  bad "kube-system 里没有 kube-dns Service"
fi
DNSUP=$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c ' Running ')
if [ "${DNSUP:-0}" -gt 0 ]; then ok "CoreDNS Running x$DNSUP"; else bad "没有 Running 的 CoreDNS Pod"; fi

if [ -n "$(kubectl -n "$NS" get networkpolicy -o name 2>/dev/null)" ]; then
  bad "本命名空间存在 NetworkPolicy —— 重点检查 egress 是否放行了 UDP/TCP 53"
  kubectl -n "$NS" get networkpolicy
else
  ok "本命名空间无 NetworkPolicy"
fi

# ---------- 实测 ----------
if [ -n "$CLIENT" ]; then
  step 5 "从 $CLIENT 内部实测"
  kubectl -n "$NS" exec "$CLIENT" -- sh -c \
    "nslookup $SVC.$NS.svc.cluster.local >/dev/null 2>&1 && echo '  OK  DNS 解析成功' || echo '  NG  DNS 解析失败 → 看第 4 步'"
  kubectl -n "$NS" exec "$CLIENT" -- sh -c \
    "curl -s -m5 -o /dev/null -w '  HTTP %{http_code}  耗时 %{time_total}s\n' http://$SVC.$NS.svc.cluster.local; echo \"  curl exit=\$?\""
fi

cat <<'LEGEND'

--- curl 退出码速查 ---
   6  Couldn't resolve host  → DNS 层（CoreDNS / 名字错 / egress 未放行 53）
   7  Connection refused     → 立刻被拒：EndpointSlice 空，kube-proxy 插了 REJECT
  28  Timed out              → 包被静默丢弃：NetworkPolicy DROP，或后端不响应
LEGEND

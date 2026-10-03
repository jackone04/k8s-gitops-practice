# Ingress 链路与状态码定位（D12）

## 请求链路
curl → 127.0.0.1:80/443 (K3s ServiceLB) → Traefik Pod
  → EntryPoint(web/websecure) → TLS 终止(按 SNI 选证书)
  → Router(Host+Path) → Middleware(stripPrefix/redirect)
  → Service → EndpointSlice → Pod

## 状态码 → 链路位置（实测）
| 码 | 注入的故障 | 根因位置 | 定位命令 |
|---|---|---|---|
| 404 | Ingress 引用不存在的 Service（webz） | Router 层：规则存在但找不到后端 Service | logs deploy/traefik 直接报 "service not found" |
| 503 | Service selector 写错（app=webx） | EndpointSlice 为空（ENDPOINTS: <unset>） | get endpointslice -l kubernetes.io/service-name=<svc> |
| 502 | targetPort 写错（9999） | EndpointSlice 有 IP，但容器没监听该端口 | 对比 Service targetPort 与容器 containerPort |

三者关键区别：404 是 Router 层问题（规则/服务名错），503 是端点为空，502 是端点存在但连不上。
get svc / get ingress 本身都显示正常，必须结合状态码 + EndpointSlice 才能分辨。

## 四个坑（实测，和计划原文有出入的地方标注了）

1. shell 里的 http_proxy 会劫持 curl 到 127.0.0.1 的请求 → 用 --noproxy '*'

2. ingress-nginx 的注解对 Traefik 无效，而且不报错 → 改用 Middleware + router.middlewares 注解

3. 【与计划原文不符】pathType: Prefix 在 Traefik 里是按"字符串前缀"匹配，不是 K8s 规范定义的"路径段"匹配。
   实测：/api 规则会命中 /apix、/apiabc，只有 /ap（比 /api 短）才落回 / 规则。
   生产含义：/api 可能误伤 /apikey 这类路径，需要更精确的匹配（如 Exact 或额外校验）。

4. -H Host 不改变 TLS SNI，测 TLS 必须用 --resolve。
   实测：curl -k -H "Host:" 能"通"是因为 -k 跳过了证书校验，掩盖了问题；
   不加 -k 时报错 exit=60（unable to get local issuer certificate），
   因为 TLS 握手发生在 HTTP 请求头发送之前，服务端按 SNI 选证书时根本没看到 -H 改的 Host。

## 本日故障排查素材：Docker Hub 429 限流 + registries.yaml 隐藏字符
- 现象：两个 Pod 卡在 ImagePullBackOff
- 定位：describe pod 的 Events 直接给出 429 Too Many Requests
- 根因：Docker Hub 匿名拉取限流；K3s containerd 的拉取凭据与 Docker Engine 的 docker login 互相独立，不会继承
- 弯路：配置 registries.yaml 时粘贴 token 混入不可见字符，破坏 YAML 格式，导致 K3s 启动失败，
  kubectl get nodes 报 ServiceUnavailable，表面现象和真实根因完全不相关
- 修复：用 read -rs 读入 shell 变量再 heredoc 写文件，避免粘贴/编辑器引入特殊字符

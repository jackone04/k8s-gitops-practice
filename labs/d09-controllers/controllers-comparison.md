# 四控制器对比

| 维度 | Deployment | StatefulSet | DaemonSet | Job |
|---|---|---|---|---|
| 管理对象 | 无状态副本集 | 有状态副本集 | 每节点一个副本 | 一次性/批处理任务 |
| Pod 命名 | 随机哈希+后缀,删了就变 | 按序号 -0/-1/-2,删了保留原名 | 每节点一个,名字带节点信息 | 随机后缀,跑完即退出 |
| 创建顺序 | 并行起 | 顺序起(等前一个 Ready) | 每节点独立起 | 按 parallelism 分批并行 |
| 副本数由谁定 | replicas 字段手动指定 | replicas 字段手动指定 | 等于节点数,不能手动指定 | 无"副本"概念,由 completions/parallelism 控制 |
| 网络/存储身份 | 无固定身份,Pod 可互换 | 配 headless Service 给稳定 DNS,可配 volumeClaimTemplates 给独立 PVC | 常用 hostNetwork/hostPath 访问节点本身资源 | 无持久身份,一次性执行 |
| restartPolicy | Always(默认) | Always(默认) | Always(默认) | 必须是 Never 或 OnFailure |
| 失败/重试机制 | ReplicaSet 维持期望数量 | 按序号维持期望数量 | 节点故障/排出时自动增删 | backoffLimit 控制**累计失败**上限,超过判 Failed |
| 典型场景 | Web 服务、API | 数据库、消息队列 | 日志采集、监控 agent、CNI | 数据迁移、批处理(配 CronJob 做定时) |

## 今日实测记录
- Deployment 删除 Pod 后新 Pod 用全新随机后缀(旧名字 NotFound)
- StatefulSet 删除 sts-1 后新 Pod 仍叫 sts-1,身份不变
- Job(completions:3, parallelism:2, backoffLimit:1)第一批 2 个 Pod 同时失败即耗尽 backoffLimit,直接 Failed,未触发第三次尝试

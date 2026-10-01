
## 附：ConfigMap 热更新延迟实测
- 实测：patch 后 <2 秒生效（非预期的 60-90s）
- 原因：kubelet 默认用 Watch 策略监听变更（K8s 1.12+ 默认值），不是 TTL 轮询缓存
- 对照：TTL Cache 策略下才会有固定延迟窗口


## 实验二：OOMKilled 与 QoS

- 现象：容器内 Python 脚本死循环追加 1MB 字符串，`limits.memory: 64Mi` → 17s 左右即被杀，
  进入 OOMKilled → CrashLoopBackOff 循环（因为脚本没变，重启后还是会再次撞限）
- 定位：`kubectl describe pod | grep -A 6 "Last State"` → `Reason: OOMKilled`，`Exit Code: 137`
  （137 = 128 + 9，9 是 SIGKILL 信号）
- 认知陷阱：只设了 memory 的 requests==limits，QoS 却是 `Burstable` 不是 `Guaranteed`——
  **Guaranteed 要求 CPU 和内存都设置 requests==limits，缺一不可**
- 验证：补上 `cpu: "100m"`（requests==limits）后，`qosClass` 变成 `Guaranteed`
- 提醒：调大 limits 不等于"修好"死循环脚本，只是延长了撑爆前的时间——
  这个实验里"修复"指的是理解 OOM 机制和 QoS 判定条件，不是让脚本停止吃内存

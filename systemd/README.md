# systemd 生命周期托管

## 为什么需要它

单节点 Kubernetes 上，GPU Deployment 的开机顺序容易出问题：

- kubelet / containerd 还没就绪，Pod 已经被调度
- NVIDIA device plugin 还没注册 GPU，Pod 卡在 `UnexpectedAdmissionError`
- GPU 刚重启后处于 unhealthy，但 `allocatable` 仍报告 2，调度器会放行
- 关机时 Deployment 还在 etcd 里，kubelet 拆解过程中反复拉起僵尸 Pod

这个单元用 `Type=oneshot + RemainAfterExit=yes` 把“启动/停止”做成一次性编排：

- **stop**：从 etcd 删除 Deployment/Service，避免关机时重建
- **start**：幂等清理 → 等 apiserver → 等 device plugin → 金丝雀 GPU 准入 → 按序 apply（先 vLLM 后 embedding）
- **restart**：`kubectl delete --wait` + 轮询确认旧 Pod 全部终止（GPU 真释放）后再重新 apply，新旧实例永不并存
- **canary**：申请 1 张 GPU 的 Pod，`Running` 才说明调度、设备健康、运行时注入都通过

## 安装

```bash
kubectl create namespace llm-serving
sudo mkdir -p /opt/llm-inference-platform
sudo cp -r yaml systemd docs eval README.md /opt/llm-inference-platform/
sudo cp systemd/platfrom.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now platfrom.service
```

按你的环境修改：

- `REPO_DIR`：仓库部署路径
- `NAMESPACE`：默认 `llm-serving`
- `LLM_GPU_UUIDS` / `EMBED_GPU_UUID`：GPU 钉卡（见下），留空则回退设备插件分配
- `GPU_NODE_NAME`：留空时自动查找带 `nvidia.com/gpu.present=true` 标签的节点
- `EXPECTED_GPUS`：默认 2
- `DEVICE_PLUGIN_NAMESPACE` / `DEVICE_PLUGIN_DS`：默认 `kube-system` / `nvidia-device-plugin`
- `CANARY_IMAGE`：默认与 vLLM 镜像一致

## GPU 钉卡（防漂移）

多 GPU 共享时设备插件的随机分配会在重启后漂移。用 `NVIDIA_VISIBLE_DEVICES=<UUID>` 钉卡可根治：

- 走 nvidia container toolkit 注入，**不经过设备插件**，UUID 跟物理卡走
- `LLM_GPU_UUIDS` 给 vLLM（tensor-parallel 卡，逗号分隔），`EMBED_GPU_UUID` 给检索管线
- 查 UUID：`nvidia-smi --query-gpu=index,uuid,pci.bus_id --format=csv`
- 用钉卡后 YAML 里**不再声明 `nvidia.com/gpu`**；`platfrom-manage.sh` 用 `envsubst` 替换占位符

## 设计取舍

### 为什么 stop 要删除资源

如果只在关机时 `systemctl stop kubelet`，Deployment 仍在 etcd 中，kubelet 可能在退出前反复拉起 Pod，留下僵尸资源。先把 Deployment/Service 从 etcd 摘除，才能保证关机干净。

### 为什么 start 先清理

断电、强制重启、上一次 stop 失败等场景不会走正常关闭流程。start 开头的幂等清理可以兜底这些残留。

### 为什么用金丝雀，而不是只看 allocatable

`nvidia.com/gpu: 2` 只表示 device plugin 上报了资源，不表示 GPU 真的健康。参考环境遇到过 GPU 重启后约 5 分钟 unhealthy、但 allocatable 仍为 2 的情况，调度放行后 kubelet 拒绝分配，短时间内刷出大量重试 Pod。

金丝雀 Pod 真正申请 1 张 GPU，`Running` 才放行，能同时验证：

- 调度器认为资源可分配
- device plugin 正常
- NVIDIA runtime 注入正常
- GPU 没有处于不可用状态

### 为什么不给 kubelet 加反向依赖

`After=kubelet.service` 是单向依赖。如果再加 `kubelet` 对 `qwen3-35b.service` 的依赖，会形成循环，systemd 在关机拆解时可能乱序。apiserver 的可达性由 `manage.sh` 运行时等待，不放进 systemd 依赖图。

## 常用命令

```bash
sudo systemctl start platfrom      # 开机/手动拉起（= restart，幂等）
sudo systemctl stop platfrom       # 停止并摘除
sudo systemctl restart platfrom    # 阻塞式重启（delete --wait + 确认释放 + 拉起）
sudo systemctl status platfrom
journalctl -u platfrom -b

# 或直接用脚本
/opt/llm-inference-platform/systemd/platfrom-manage.sh start|stop|restart|verify-stopped
```

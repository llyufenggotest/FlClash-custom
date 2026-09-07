# FlClash iOS 五协议长期维护基线

> 本文件描述代码维护入口；真机测试记录和历史证据详见 `F:/js_study/.hermes/memory/tasks/flclash-ios-custom-integration.md`。

## 固定基线

- 父仓：`llyufenggotest/FlClash-custom`
- 长期维护分支：`maintenance/ios-five-protocol-stable`
- 真机验证代码提交：`dd725800f5d01de61acf4414e76444426564f2d9`
- 真机验证标签：`ios-five-protocol-stable-20260907`
- mihomo：`llyufenggotest/Clash.Meta-custom@09f57e3105c24baa48bee208cfa1d5d44309e8b1`
- mihomo维护分支/标签：`maintenance/ios-five-protocol-stable` / `ios-five-protocol-stable-20260907`
- sing-shadowsocks2：`llyufeng/sing-shadowsocks2-meta@98c4afa30d95f4af5bdaa18abf8ff6cc6d3ed8d7`
- 构建：Actions run `34063971544`，artifact `9998537661`
- IPA SHA-256：`749ad2e28707d05e7fb9aa11f369c1021878c37d45d1757761e6889c0254df22`
- 用户验收：普通重签/实际使用场景由测试者确认稳定使用（2026-09-07）。

以后所有功能、协议和上游同步必须从本维护分支继续；禁止从旧`five-protocol-ios`、`fastup-integration`、`experiment/*`或上游main覆盖本基线。旧分支仅作历史来源和回滚证据。

## 不可丢失的协议产品面

最终产品面固定为五类，`#sl`明确删除且CI有反向门禁：

1. **ViewTurbo / `#VT`**：位于`core/sing-shadowsocks2`的iOS安全实现；父`core/go.mod`必须继续用本地replace，否则会错误链接纯净上游。
2. **`#x365`**：VLESS自定义模式；必须与普通VLESS隔离，普通VLESS行为不可改变。
3. **`#fastup`**：Trojan密码/`mpw`与h2mux定制；必须与标准Trojan隔离。
4. **BLACKSTONE / XHTTP**：独立动态配置与数据通道；不得覆盖标准`network: xhttp`命名空间。
5. **Oppa**：独立native类型，保留TCP首包、响应校验、UDP session/packet封装、IPv4/IPv6/域名路径及配置密码边界。

协议相关共享注册点、parser、outbound、transport和marker测试必须整体审计；不得以“上游文件更新”为由整文件覆盖。任何协议修改必须同时跑自定义模式与标准模式对照，并做真实端点流量测试。

## iOS Runner / NECore 生命周期

以下逻辑是稳定性组成部分，不得拆除：

- Runner↔NECore RPC具有session/request ID、deadline、取消域、in-flight合并、有界结果缓存和exactly-once语义。
- App请求与NE请求的取消域分离；stop不能取消仍由Go回调持有的setup。
- Provider Message具备原生通道与App Group mailbox fallback，事件驱动唤醒，不使用20ms轮询；请求忙/拆除错误分型明确。
- `quickSetup`单实例不可并发；生命周期generation防止迟到回调复活旧状态。
- `CoreShutdownCleanupGate`把系统completion deadline与真实资源清理分离；迟到setup仍只执行一次stopTun/退休。
- Runner bbolt缓存固定在私有`Application Support/RunnerCore`，不得同步进App Group与NE争锁。
- DNS listener、cache、runtime状态保持进程隔离；iOS MTU解码继续钳制安全范围。
- 前后台切换、重复start、profile切换不得触发无意义的完整reload；已应用配置指纹必须持久化并校验磁盘内容。

关键文件：`ios/Runner/{ServiceChannel.swift,Core/CoreMessageRouter.swift,Tunnel/*,Storage/SharedStateStore.swift}`、`ios/NECore/{PacketTunnelProvider.swift,ProviderMessageMailbox.swift,PacketTunnelSharedStateStore.swift}`、`core/{common.go,hub.go,method.go,runner_cache_path.go}`。

## 规则预热与原子激活

固定链路：

```text
订阅导入/更新
→ 生成最终effective YAML
→ SHA-256 generation
→ 32 MiB上限的流式provider下载到隔离staging
→ Go prewarmRuleProvider编译/验证MRS
→ 校验所有文件和摘要
→ 原子发布不可变generation+manifest（保留current/previous）
→ setupConfigAtPath验收候选
→ 原子提交正式config.yaml
→ 启动或事务切换NECore
```

不变量：

- 下载执行Content-Length预检、累计大小限制、增量SHA-256、超限立即取消并删除半文件；不得把完整规则留在Dart内存。
- manifest缺失、版本错误、路径逃逸、digest不符、非普通文件、prewarm root内部symlink/reparse一律fail closed。
- macOS可信系统路径别名先规范化，但App Group/prewarm root自身和内部链接仍拒绝。
- 候选验收成功前不得覆盖正式配置；start/switch失败恢复旧配置字节、旧完整generation和旧隧道。
- `prewarmConfig→config.Parse→PrepareConfig`旧路线禁止恢复，因为会污染全局运行时。
- iOS low-memory启动只消费本地完整MRS，不在线构建大型matcher或静默丢规则。

关键文件：`lib/core/{rule_generation_preparer.dart,rule_preparation_scheduler.dart,controller.dart}`、`lib/common/{request.dart,task.dart,ios_config_activation.dart}`、`lib/providers/actions/{profiles.dart,setup.dart}`、`core/{rule_generation.go,candidate_config.go}`、`core/mihomo/hub/executor/rule_preflight.go`。

## mihomo规则、资源与并发安全

- `RuleSnapshotLease`覆盖整个规则匹配及provider lookup；旧provider只在所有旧读者释放后关闭。
- `RuleSet.Match`使用现有`RuleMatchHelper`，禁止再次获取`configMux.RLock`，避免writer等待时嵌套读锁死锁。
- 异步回调只携带稳定值`RuleUpdate{Name, Strategy}`，不得持有可能已关闭的provider对象。
- reload/retire必须关闭被替换或删除的provider；禁止用“跳过Close”掩盖竞态。
- MRS sidecar必须校验源摘要、格式和完整性；失效sidecar不可复用。
- iOS测速/健康检查采用全局准入、取消、有界历史和低内存并发预算；不能为提速恢复50路NE内并发。
- 代理服务器地址继续钉到DIRECT以避免TUN路由回环；ASN.mmdb在低内存extension中不映射。
- 自动GLOBAL组默认第一个真实节点，不得回退DIRECT；瞬时空provider结果不得清空代理页状态。

关键文件：`core/mihomo/{tunnel/tunnel.go,rules/provider/*,listener/sing_tun/server.go,hub/executor/*,common/probelimit/*,config/*,component/mmdb/*}`。

## 诊断、内存与侧载兼容

- Runner/NECore原生日志写入App Group，跨进程安全、敏感字段脱敏；内存缓冲最多128条/256 KiB，单次drain 64 KiB，滚动尾读2 MiB。
- 日志页面导出必须附加native section；显式清理同时清内存与两个native文件。
- 心跳和内存回收是诊断/兜底，不能把`0xdead10cc`直接宣称为OOM；需要IPS/jetsam证据。
- `Tg_@HelloWorld_1024.dylib`必须同时嵌入Runner和NECore并由各自进程`dlopen(RTLD_NOW|RTLD_LOCAL)`。
- dylib固定SHA-256：`cd903ea15657cbd356398adcb60c8872c41c29b69acc1a5dfb78a49d6e75dea5`，arm64、Mach-O MH_DYLIB、Git/IPA权限`0755`；严禁同名替换。

## 构建与依赖不变量

- `.github/workflows/ios-five-protocol.yaml`是iOS/macOS契约与产物入口；子模块必须先推送，再推父仓指针。
- `window_manager`固定到`f0b9f1b93a717108412a0f9565ef4319b79fbdac`，包含`packages/window_manager`；禁止恢复moving-main或CI动态改lock fallback。
- `pubspec.lock`与Flutter 3.44.4/Dart 3.12.2兼容；`yaml`是运行时依赖。
- iOS构建优先`macos-15`，资源不足时回退可分配runner；不要重复克隆Flutter/Go到C盘。
- 产物验收必须包含ZIP、Runner、NECore、Widget、双dylib路径/哈希/0755、协议marker；构建成功不能替代真机流量。

## 每次修改的最低门禁

1. 确认从`maintenance/ios-five-protocol-stable`及其后继提交开始，子模块祖先关系正确。
2. 修改前创建安全标签/分支；共享parser/registry手工融合。
3. Flutter全量及相关专项；父core默认/`with_low_memory`；mihomo定向、低内存、vet、规则并发测试。
4. `scripts/verify_ios_contracts.py`、mutation test、dylib contract、`git diff --check`。
5. macOS Actions编译Swift生命周期harness，下载F盘并审计IPA。
6. 普通重签与TrollStore真实流量、首次导入预热、切换、失败回滚、测速、前后台、长时连接验收。

## 回滚点

- 最终真机稳定：`ios-five-protocol-stable-20260907`
- 预热前：`backup/ios-before-rule-prewarm-22e6b250`
- 审计修复前：`backup/ios-pre-audit-fix-56c2e3e8`
- dylib集成前：`verified-ios-dylib-preintegration-d6a69ec9`

不要删除这些标签或强推维护分支。

# iOS RPC audit repair — validation boundary

Run on macOS CI before packaging:

```sh
python3 test/ios_rpc/run.py
```

This compiles the **production** `ProviderMessageMailbox.swift`, injects a counter-based core invoker, uses real temporary directories and Darwin filesystem notifications, and exercises cross-transport in-flight merging, completed reply caching, lease cancellation, deadline rejection, actual outstanding core admission, stop/late callback isolation and stale-session rejection. It also compiles the actual native VPN options decoder for legacy MTU fallback/clamping. It does not simulate results in Python.

Windows verification: tree-sitter Swift parsed all seven modified production Swift files and `main.swift` without syntax errors; scoped `git diff --check` passed. `swiftc` was not installed and `run.py` explicitly exits BLOCKED on this host. **No successful Swift compilation or behavior-test execution is claimed.** Strict executed RED/GREEN could not be completed locally.

## Remaining device/CI gates

- Xcode build of Runner and NECore (Swift 5 mode, iOS 15 deployment); check actor-isolation/concurrency diagnostics.
- Inject stop during network-settings and quickSetup; old callbacks must not call startTun/saveRunTime/start heartbeat. New starts while old quickSetup is outstanding intentionally fail closed instead of overlapping global Go setup.
- Cancel ninth queued request, native wait and mailbox wait; no later fallback/side effect. Runner enforces a 16-second overall Task deadline; Dart's own shorter timeout does not send a cancellation signal in the current Dart API.
- Go operations already invoked cannot be cancelled by this Swift repair. Their receiver slots remain occupied until real callbacks; a permanently hung core fails closed rather than allocating replacement operations.
- EventQueue overflow → mailbox RPC → new events. Actual event queue integration (beyond injected responsiveness callback) requires device testing.
- Lock/unlock, re-sign compatibility and Energy/System Trace: request/response waiting now uses directory vnode events, with only a 5-second receiver recovery/GC timer. Device notification delivery/energy is not measured here.
- Client death and response/cancel publication race: stale files are collected after 30 seconds; stop removes the entire generation directory and serializes against late publications.
- Versioned transport envelope requires matching Runner/NECore deployment. The inner Go JSON request and response are unchanged. Old unversioned RPC is rejected rather than replayed unsafely.
- Receiver size/cache/slot admission may return busy/oversize errors on extreme configurations. It does not remove rules or modify native proxy protocols.

`test/ios_provider_message_mailbox_test.dart` now runs the real Swift behavior harness on macOS and explicitly skips on unsupported hosts; it no longer asserts source strings. No Go, heartbeat, database or transport protocol implementation files were changed by this work. MTU decoder edit was separately delegated explicitly.

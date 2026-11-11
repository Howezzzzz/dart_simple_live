import 'dart:async';

/// 串行任务队列：任务按入队顺序**依次**执行（前一个完成才跑下一个）。
///
/// 关键约束（P0，ISS-281）：**在某个任务体内再次 [run] 会在当前任务内「内联」执行**，
/// 而不是排到队尾——否则会形成「内层任务等外层完成、外层又 `await` 内层」的嵌套
/// 自死锁，整条队列永久冻结。
///
/// 背景：音量均衡的首帧钩子曾在队列任务内 `await _syncVolumeNorm()`，而后者就是
/// 「入队」→ 进房首个 playing 事件即冻结队列，此后房内所有热切换全部失效
/// （真机 2026-11-11 证据：拨开关后 af 零变化，重进房才恢复）。
///
/// 重入判定用 Zone 标记：只对**运行在当前任务异步上下文内**的 [run] 生效，
/// 不会把并发到达的正常入队误判成重入（误判会破坏串行语义）。
///
/// ⚠️ Dart 的 Zone 值会**传播进**任务体内 `Future.delayed` / `Timer` 的回调——那类
/// 回调里若 [run] 仍应视为「队列外」，需先用 `Zone.root.bindCallback(...)`（或
/// `Zone.root.run(...)`）转义，否则会被误判为重入而内联。
class SerialTaskQueue {
  Future<void> _tail = Future<void>.value();
  static final Object _zoneKey = Object();

  /// 入队执行 [task]，返回其完成 Future。
  ///
  /// 异常交给 [onError] 消化（默认吞掉，避免 fire-and-forget 产生未处理异步异常，
  /// 且**不阻断**后续任务）。
  Future<void> run(
    Future<void> Function() task, {
    void Function(Object error, StackTrace stack)? onError,
  }) {
    void handle(Object e, StackTrace s) => onError?.call(e, s);

    // 重入（已在某任务体内）：内联执行，绝不排到队尾（会死锁）
    if (Zone.current[_zoneKey] == true) {
      return Future<void>.sync(task).catchError(handle);
    }

    final next = _tail.then((_) {
      return runZoned(
        () async {
          try {
            await task();
          } catch (e, s) {
            handle(e, s);
          }
        },
        zoneValues: {_zoneKey: true},
      );
    });
    _tail = next;
    return next;
  }
}

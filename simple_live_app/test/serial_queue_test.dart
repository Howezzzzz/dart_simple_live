import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/serial_queue.dart';

void main() {
  group('SerialTaskQueue', () {
    test('队列任务内再次 run 不死锁，且内联有序（P0 回归，ISS-281）', () async {
      final q = SerialTaskQueue();
      final order = <String>[];
      await q.run(() async {
        order.add('outer-start');
        await q.run(() async {
          order.add('inner');
        });
        order.add('outer-end');
      }).timeout(const Duration(seconds: 5));
      expect(order, ['outer-start', 'inner', 'outer-end']);
    });

    test('并发入队保持先进先出、任务不交叠', () async {
      final q = SerialTaskQueue();
      final events = <String>[];
      Future<void> job(String id) => q.run(() async {
            events.add('$id-start');
            await Future<void>.delayed(const Duration(milliseconds: 20));
            events.add('$id-end');
          });
      await Future.wait([job('a'), job('b'), job('c')]);
      expect(events, [
        'a-start', 'a-end',
        'b-start', 'b-end',
        'c-start', 'c-end',
      ]);
    });

    test('任务抛异常不阻断后续任务，且交给 onError 消化', () async {
      final q = SerialTaskQueue();
      final done = <String>[];
      final errors = <Object>[];
      await q.run(() async => throw StateError('boom'),
          onError: (e, _) => errors.add(e));
      await q.run(() async => done.add('after'));
      expect(done, ['after']);
      expect(errors, hasLength(1));
    });

    test('未提供 onError 时异常被吞掉、队列仍可继续', () async {
      final q = SerialTaskQueue();
      final done = <String>[];
      await q.run(() async => throw StateError('boom'));
      await q.run(() async => done.add('after'));
      expect(done, ['after']);
    });

    test('任务内定时器经 Zone.root 转义后再入队=走队列（不内联）【阶段4 加固】', () async {
      final q = SerialTaskQueue();
      final ev = <String>[];
      // A：任务内调度短延时定时器，回调经 Zone.root 转义后再入队
      await q.run(() async {
        ev.add('A');
        Future.delayed(const Duration(milliseconds: 30),
            Zone.root.bindCallback(() async {
          await q.run(() async => ev.add('escaped'));
        }));
      });
      // C：紧接 A 入队的长任务，覆盖定时器触发时刻
      await q.run(() async {
        ev.add('C-start');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        ev.add('C-end');
      }).timeout(const Duration(seconds: 5));
      // 让「已入队」的 escaped 有机会执行
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // 转义正确 → escaped 排在 C 之后；若漏转义会被误判重入而内联（插在 C 中间）
      expect(ev, ['A', 'C-start', 'C-end', 'escaped']);
    });
  });
}

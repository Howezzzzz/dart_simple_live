import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/ready_gate.dart';

void main() {
  group('就绪门判定 readyGateCanFinish（方案 §三 B1；阶段4 复核 B/C）', () {
    test('四项全满足 → 放行', () {
      expect(
        readyGateCanFinish(
            pending: true, playIssued: true, restartSeen: true, pipelineBusy: 0),
        isTrue,
      );
    });

    test('缺「play 已发」→ 不放行（防热拨 VSR / seek 误判为进房就绪）', () {
      expect(
        readyGateCanFinish(
            pending: true, playIssued: false, restartSeen: true, pipelineBusy: 0),
        isFalse,
      );
    });

    test('缺「restart 完成」→ 不放行', () {
      expect(
        readyGateCanFinish(
            pending: true, playIssued: true, restartSeen: false, pipelineBusy: 0),
        isFalse,
      );
    });

    test('门控未在途 → 不放行', () {
      expect(
        readyGateCanFinish(
            pending: false, playIssued: true, restartSeen: true, pipelineBusy: 0),
        isFalse,
      );
    });

    test('有在途管线写入 → 不放行（等写链完成后复检）', () {
      expect(
        readyGateCanFinish(
            pending: true, playIssued: true, restartSeen: true, pipelineBusy: 1),
        isFalse,
      );
    });
  });
}

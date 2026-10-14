import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/follow_sync_service.dart';

enum FollowSyncState { loading, ready, error }

/// 「从账号同步关注的主播」页面控制器。
class FollowSyncController extends GetxController {
  FollowSyncController(this.siteId);

  final String siteId;

  final state = FollowSyncState.loading.obs;
  final error = ''.obs;
  /// 拉取过程中已获得的条数（供加载态显示进度）
  final fetched = 0.obs;
  final candidates = <FollowSyncCandidate>[].obs;
  final selected = <String>{}.obs;
  final onlyLive = false.obs;
  final importing = false.obs;

  @override
  void onInit() {
    super.onInit();
    fetch();
  }

  /// 当前可见（受「只看在播」过滤）
  List<FollowSyncCandidate> get visible => onlyLive.value
      ? candidates.where((c) => c.live).toList()
      : candidates.toList();

  int get newCount => candidates.where((c) => !c.existing).length;
  int get existCount => candidates.where((c) => c.existing).length;

  Future<void> fetch() async {
    state.value = FollowSyncState.loading;
    error.value = '';
    fetched.value = 0;
    try {
      final list = await FollowSyncService.fetch(
        siteId: siteId,
        onProgress: (n) => fetched.value = n,
      );
      candidates.assignAll(list);
      // 安全默认：只勾「未关注且正在直播」的，避免一次导入几百条触发平台风控
      selected
        ..clear()
        ..addAll(
            list.where((c) => !c.existing && c.live).map((c) => c.id));
      state.value = FollowSyncState.ready;
    } catch (e, s) {
      Log.e('同步关注失败: $e', s);
      error.value = e.toString();
      state.value = FollowSyncState.error;
    }
  }

  void toggle(String id, bool value) {
    if (value) {
      selected.add(id);
    } else {
      selected.remove(id);
    }
  }

  void selectAll(bool value) {
    final ids = visible.map((c) => c.id);
    if (value) {
      selected.addAll(ids);
    } else {
      selected.removeAll(ids);
    }
  }

  /// 导入选中项，返回新增数量
  Future<int> doImport() async {
    if (importing.value) {
      return 0;
    }
    importing.value = true;
    try {
      final chosen =
          candidates.where((c) => selected.contains(c.id)).toList();
      return await FollowSyncService.import(chosen);
    } finally {
      importing.value = false;
    }
  }
}

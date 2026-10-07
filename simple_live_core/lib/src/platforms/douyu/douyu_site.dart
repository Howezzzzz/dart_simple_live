import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:html_unescape/html_unescape.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/platforms/douyu/douyu_utils.dart';

class DouyuSite implements LiveSite {
  @override
  String id = "douyu";

  @override
  String name = "斗鱼直播";

  String _cookie = '';

  String _dy_did = '';

  String _ltp0 = '';

  @override
  LiveDanmaku getDanmaku() => DouyuDanmaku();

  @override
  Future<List<LiveCategory>> getCategories() async {
    List<LiveCategory> categories = [];
    var result =
        await HttpClient.instance.getJson("https://m.douyu.com/api/cate/list");
    var subCateList = result["data"]["cate2Info"] as List;
    for (var item in result["data"]["cate1Info"]) {
      var cate1Id = item["cate1Id"];
      var cate1Name = item["cate1Name"];
      List<LiveSubCategory> subCategories = [];
      subCateList.where((x) => x["cate1Id"] == cate1Id).forEach((element) {
        subCategories.add(LiveSubCategory(
          pic: element["icon"],
          id: element["cate2Id"].toString(),
          parentId: cate1Id.toString(),
          name: element["cate2Name"].toString(),
        ));
      });
      categories.add(
        LiveCategory(
          id: cate1Id.toString(),
          name: cate1Name.toString(),
          children: subCategories,
        ),
      );
    }
    // 根据ID排序
    categories.sort((a, b) => int.parse(a.id).compareTo(int.parse(b.id)));

    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(LiveSubCategory category,
      {int page = 1}) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/gapi/rkc/directory/mixList/2_${category.id}/$page",
      queryParameters: {},
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualities(
      {required LiveRoomDetail detail}) async {
    // 优先网页接口：免登录即可拿到全部档位（原画/蓝光/超清/高清）。
    // 微信小程序接口（roomPlayer）服务端只发 720p 且忽略 rate，故仅作兜底。
    try {
      var data = await DouyuUtils.sign(detail.roomId, cookie: _cookie);
      var result = await HttpClient.instance.postJson(
        "https://www.douyu.com/lapi/live/getH5PlayV1/${detail.roomId}",
        data: data,
        formUrlEncoded: true,
        header:
            DouyuUtils.requestHeader(roomId: detail.roomId, cookie: _cookie),
      );

      var cdns = <String>[];
      for (var item in result["data"]["cdnsWithName"]) {
        cdns.add(item["cdn"].toString());
      }

      // 如果cdn以scdn开头，将其放到最后
      cdns.sort((a, b) {
        if (a.startsWith("scdn") && !b.startsWith("scdn")) {
          return 1;
        } else if (!a.startsWith("scdn") && b.startsWith("scdn")) {
          return -1;
        }
        return 0;
      });

      List<LivePlayQuality> qualities = [];
      for (var item in result["data"]["multirates"]) {
        qualities.add(LivePlayQuality(
          quality: item["name"].toString(),
          data: DouyuPlayData(item["rate"], cdns),
        ));
      }
      if (qualities.isNotEmpty) {
        return qualities;
      }
    } catch (_) {
      // 网页接口失败（签名/风控/网络），回退微信小程序接口
    }

    // 兜底：微信小程序接口（免登录、无需 cookie、流地址长时效，但仅 720p）
    try {
      final miniData = await DouyuUtils.miniRoomPlayer(detail.roomId);
      final rateList = miniData['rate_list'] as List? ?? const [];
      final qualities = <LivePlayQuality>[];
      for (final item in rateList) {
        qualities.add(LivePlayQuality(
          quality: item['name'].toString(),
          data: DouyuMiniPlayData(int.tryParse(item['rate'].toString()) ?? 0),
        ));
      }
      return qualities;
    } catch (e) {
      // 兜底也失败：归一化为可读错误，避免原始类型异常冒泡
      throw Exception("获取斗鱼清晰度失败（网页/小程序接口均不可用）: $e");
    }
  }

  @override
  Future<LivePlayUrl> getPlayUrls(
      {required LiveRoomDetail detail,
      required LivePlayQuality quality}) async {
    // 小程序接口路径：直接按所选码率请求，返回单条长时效 FLV 地址
    final q = quality.data;
    if (q is DouyuMiniPlayData) {
      try {
        final miniData =
            await DouyuUtils.miniRoomPlayer(detail.roomId, rate: q.rate);
        final url = miniData['live_url']?.toString() ?? '';
        return LivePlayUrl(urls: url.isEmpty ? const [] : [url]);
      } catch (e) {
        throw Exception("获取斗鱼播放地址失败（小程序接口异常）: $e");
      }
    }
    var data = quality.data as DouyuPlayData;

    List<String> urls = [];
    for (var item in data.cdns) {
      var url = await getPlayUrl(detail.roomId, data.rate, item);
      if (url.isNotEmpty) {
        // if expire=300 and cdn is ws then add &expire=0
        // user must be live in oversea
        // cookie is better, cookie needs refreshed every 7 days
        if (url.contains('expire=300') && url.contains('fcdn=ws')) {
          url = '$url&expire=0';
        }
        urls.add(url);
      }
    }
    return LivePlayUrl(urls: urls);
  }

  Future<String> getPlayUrl(String roomId, int rate, String cdn) async {
    var sign =
        await DouyuUtils.sign(roomId, rate: rate, cdn: cdn, cookie: _cookie);
    var result = await HttpClient.instance.postJson(
      "https://www.douyu.com/lapi/live/getH5PlayV1/$roomId",
      data: sign,
      formUrlEncoded: true,
      header: DouyuUtils.requestHeader(roomId: roomId, cookie: _cookie),
    );

    return "${result["data"]["rtmp_url"]}/${HtmlUnescape().convert(result["data"]["rtmp_live"].toString())}";
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/weblist/apinc/allpage/6/$page",
      queryParameters: {},
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    Map roomInfo = await _getRoomInfo(roomId);

    return LiveRoomDetail(
      cover: roomInfo["room_pic"].toString(),
      online: int.tryParse(roomInfo["room_biz_all"]["hot"].toString()) ?? 0,
      roomId: roomInfo["room_id"].toString(),
      title: roomInfo["room_name"].toString(),
      userName: roomInfo["owner_name"].toString(),
      userAvatar: roomInfo["owner_avatar"].toString(),
      introduction: roomInfo["show_details"].toString(),
      notice: "",
      status: roomInfo["show_status"] == 1 &&
          roomInfo["videoLoop"] != 1 &&
          !roomInfo["room_name"].startsWith("【回放】"),
      danmakuData: roomInfo["room_id"].toString(),
      data: "",
      url: "https://www.douyu.com/$roomId",
      isRecord: roomInfo["videoLoop"] == 1,
    );
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword,
      {int page = 1}) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchShow",
      queryParameters: {
        "kw": keyword,
        "page": page,
        "pageSize": 20,
      },
      header: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.51',
        'referer': 'https://www.douyu.com/search/',
        'Cookie': 'dy_did=$did;acf_did=$did'
      },
    );
    if (result['error'] != 0) {
      throw Exception(result['msg']);
    }
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["relateShow"]) {
      var roomItem = LiveRoomItem(
        roomId: item["rid"].toString(),
        title: item["roomName"].toString(),
        cover: item["roomSrc"].toString(),
        userName: item["nickName"].toString(),
        online: parseHotNum(item["hot"].toString()),
      );
      items.add(roomItem);
    }
    var hasMore = result["data"]["relateShow"].isNotEmpty;
    return LiveSearchRoomResult(hasMore: hasMore, items: items);
  }

  Future<Map> _getRoomInfo(String roomId) async {
    var result = await HttpClient.instance.getJson(
        "https://www.douyu.com/betard/$roomId",
        queryParameters: {},
        header: {
          'referer': 'https://www.douyu.com/$roomId',
          'user-agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43',
        });
    Map roomInfo;
    if (result is String) {
      roomInfo = json.decode(result)["room"];
    } else {
      roomInfo = result["room"];
    }
    return roomInfo;
  }

  //生成指定长度的16进制随机字符串
  String generateRandomString(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(16));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item.toRadixString(16));
    }
    return stringBuffer.toString();
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword,
      {int page = 1}) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchUser",
      queryParameters: {
        "kw": keyword,
        "page": page,
        "pageSize": 20,
        "filterType": 1,
      },
      header: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.51',
        'referer': 'https://www.douyu.com/search/',
        'Cookie': 'dy_did=$did;acf_did=$did'
      },
    );

    var items = <LiveAnchorItem>[];
    for (var item in result["data"]["relateUser"]) {
      var liveStatus =
          (int.tryParse(item["anchorInfo"]["isLive"].toString()) ?? 0) == 1;
      var roomType =
          (int.tryParse(item["anchorInfo"]["roomType"].toString()) ?? 0);
      var roomItem = LiveAnchorItem(
        roomId: item["anchorInfo"]["rid"].toString(),
        avatar: item["anchorInfo"]["avatar"].toString(),
        userName: item["anchorInfo"]["nickName"].toString(),
        liveStatus: liveStatus && roomType == 0,
      );
      items.add(roomItem);
    }
    var hasMore = result["data"]["relateUser"].isNotEmpty;
    return LiveSearchAnchorResult(hasMore: hasMore, items: items);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var roomInfo = await _getRoomInfo(roomId);
    return roomInfo["show_status"] == 1 &&
        roomInfo["videoLoop"] != 1 &&
        !roomInfo["room_name"].startsWith("【回放】");
  }

  int parseHotNum(String hn) {
    try {
      var num = double.parse(hn.replaceAll("万", ""));
      if (hn.contains("万")) {
        num *= 10000;
      }
      return num.round();
    } catch (_) {
      return -999;
    }
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage(
      {required String roomId}) {
    //尚不支持
    return Future.value([]);
  }

  Future<String> refreshCookie(String dy_did, String ltp0) async {
    var newCookie = await DouyuUtils.refreshCookie(
        did: dy_did, ltp0: ltp0, cookie: _cookie);
    // 刷新失败返回空串时保留旧值，避免 core 内部 cookie 被清空但持久层仍认为“已登录”
    if (newCookie.isNotEmpty) {
      _cookie = newCookie;
    }
    return newCookie;
  }

  @override
  Future<void> setSiteAttrs(Map<String, dynamic> data) async {
    if (data.containsKey('cookie')) {
      _cookie = data['cookie'] as String;
      DouyuUtils.setDyDid(_cookie);
    }
  }
}

class DouyuPlayData {
  final int rate;
  final List<String> cdns;

  DouyuPlayData(this.rate, this.cdns);
}

/// 小程序接口码率载荷（rate 为 roomPlayer 的 rate 参数）
class DouyuMiniPlayData {
  final int rate;

  DouyuMiniPlayData(this.rate);
}

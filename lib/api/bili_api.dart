import '../core/http.dart';
import '../models/comment.dart';
import '../models/feed_item.dart';
import '../models/play_info.dart';
import '../models/space.dart';
import '../models/video_detail.dart';

/// bilibili 业务接口封装。所有方法都返回已解析好的模型。
class BiliApi {
  BiliApi._();
  static final BiliApi instance = BiliApi._();

  final BiliClient _client = BiliClient();

  Future<void> bootstrap() => _client.bootstrap();

  /// 首页推荐流
  ///
  /// [freshIdx] 递增可获得新内容；返回的列表已过滤掉广告 / 直播等不可播放项。
  Future<List<FeedItem>> recommendFeed({required int freshIdx, int ps = 12}) async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd',
      query: {
        'fresh_type': 4,
        'feed_version': 'V8',
        'fresh_idx': freshIdx,
        'fresh_idx_1h': freshIdx,
        'homepage_ver': 1,
        'brush': freshIdx - 1,
        'ps': ps,
        'scrl_mid': 0,
        'last_y_num': 0,
        'y_num': 4,
      },
    );
    final data = json['data'];
    if (data is! Map) return const [];
    final items = data['item'];
    if (items is! List) return const [];
    final out = <FeedItem>[];
    for (final raw in items) {
      if (raw is! Map<String, dynamic>) continue;
      // 过滤广告 / 直播 / 番剧等非普通视频
      final goto = raw['goto']?.toString();
      if (goto != null && goto != 'av' && goto != 'BV') continue;
      final item = FeedItem.fromJson(raw);
      if (item.isPlayable) out.add(item);
    }
    return out;
  }

  /// 热门视频（不需要 WBI）
  Future<List<FeedItem>> popular({int page = 1, int ps = 20}) async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/web-interface/popular',
      query: {'ps': ps, 'pn': page},
      withWbi: false,
    );
    final data = json['data'];
    if (data is! Map) return const [];
    final list = data['list'];
    if (list is! List) return const [];
    final out = <FeedItem>[];
    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      final item = FeedItem.fromJson(raw);
      if (item.bvid.isNotEmpty) out.add(item);
    }
    return out;
  }

  /// 视频详情
  Future<VideoDetail> videoDetail(String bvid) async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/web-interface/view',
      query: {'bvid': bvid},
      withWbi: false,
    );
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw BiliException('视频信息解析失败');
    }
    return VideoDetail.fromJson(data);
  }

  /// 分 P 列表（详情接口通常已包含，这里用于兜底）
  Future<List<VideoPage>> pageList(String bvid) async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/player/pagelist',
      query: {'bvid': bvid},
      withWbi: false,
    );
    final data = json['data'];
    if (data is! List) return const [];
    return [
      for (final p in data)
        if (p is Map<String, dynamic>) VideoPage.fromJson(p),
    ];
  }

  /// 相关推荐
  Future<List<FeedItem>> related(String bvid) async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/web-interface/archive/related',
      query: {'bvid': bvid},
      withWbi: false,
    );
    final data = json['data'];
    if (data is! List) return const [];
    final out = <FeedItem>[];
    for (final raw in data) {
      if (raw is! Map<String, dynamic>) continue;
      final item = FeedItem.fromJson(raw);
      if (item.bvid.isNotEmpty) out.add(item);
    }
    return out;
  }

  /// 取播放地址
  ///
  /// 关键点：`fnval` 位掩码决定返回形态
  /// - `1`  → 整段 mp4（`durl`），可直接交给 AVPlayer
  /// - `16` → 同上的另一种组合，部分视频只有这个能给 durl
  /// - `4048` → DASH 音视频分离（`dash`），**单实例播放器无法直接播放**
  ///
  /// 因此默认走 mp4，保证开箱可播。未登录清晰度上限 720P（qn=64）。
  Future<PlayInfo> playUrl({
    required String bvid,
    required int cid,
    int qn = 64,
    bool preferDash = false,
  }) async {
    final info = await _requestPlayUrl(
      bvid: bvid,
      cid: cid,
      qn: qn,
      fnval: preferDash ? 4048 : 1,
    );
    if (preferDash || info.urls.isNotEmpty) return info;

    // 兜底：换成 fnval=16 再试一次
    final retry = await _requestPlayUrl(
      bvid: bvid,
      cid: cid,
      qn: qn,
      fnval: 16,
    );
    return retry.isPlayable ? retry : info;
  }

  Future<PlayInfo> _requestPlayUrl({
    required String bvid,
    required int cid,
    required int qn,
    required int fnval,
  }) async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/player/wbi/playurl',
      query: {
        'bvid': bvid,
        'cid': cid,
        'qn': qn,
        'fnver': 0,
        'fnval': fnval,
        'fourk': 1,
        'platform': 'html5',
      },
    );
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw BiliException('播放地址解析失败');
    }
    return PlayInfo.fromJson(data);
  }

  /// 二维码登录：第一步，获取二维码
  Future<QrLoginSession> qrLoginGenerate() async {
    final json = await _client.getJson(
      'https://passport.bilibili.com/x/passport-login/web/qrcode/generate',
      withWbi: false,
    );
    final data = json['data'];
    if (data is! Map) throw BiliException('二维码获取失败');
    return QrLoginSession(
      url: data['url']?.toString() ?? '',
      key: data['qrcode_key']?.toString() ?? '',
    );
  }

  /// 二维码登录：轮询状态
  Future<QrLoginResult> qrLoginPoll(String key) async {
    final json = await _client.getJson(
      'https://passport.bilibili.com/x/passport-login/web/qrcode/poll',
      query: {'qrcode_key': key},
      withWbi: false,
    );
    final data = json['data'];
    if (data is! Map) return const QrLoginResult(status: QrLoginStatus.pending);
    final code = data['code'];
    final statusCode = code is int ? code : 0;
    switch (statusCode) {
      case 0:
        // 登录成功，cookies 会被拦截器自动吸收；url 里也带着，兜底再解析一次
        final url = data['url']?.toString() ?? '';
        if (url.isNotEmpty) _client.jar.absorbCookiesFromUrl(url);
        return const QrLoginResult(status: QrLoginStatus.success);
      case 86101:
        return const QrLoginResult(status: QrLoginStatus.pending);
      case 86090:
        return const QrLoginResult(status: QrLoginStatus.scanned);
      case 86038:
        return const QrLoginResult(status: QrLoginStatus.expired);
      default:
        return QrLoginResult(
          status: QrLoginStatus.pending,
          message: data['message']?.toString(),
        );
    }
  }

  /// 当前登录用户信息（未登录时 isLogin=false）
  ///
  /// 未登录时该接口返回 code=-101（账号未登录），这里放行，
  /// 让「我的」页面正常显示未登录状态和扫码登录入口。
  Future<Map<String, dynamic>> navInfo() async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/web-interface/nav',
      withWbi: false,
      acceptCodes: const {-101},
    );
    final data = json['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  Future<void> logout() => _client.jar.clear();

  /// 是否具备写操作能力（已登录 + 有 csrf）
  Future<bool> canWrite() async => _client.jar.canWrite;

  // ---------------------------------------------------------------- 评论

  /// 拉取评论（sort: 2=按热度，0=按时间）
  Future<CommentPage> comments({
    required int aid,
    int page = 1,
    int ps = 20,
    int sort = 2,
  }) async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/v2/reply',
      query: {
        'type': 1,
        'oid': aid,
        'pn': page,
        'ps': ps,
        'sort': sort,
      },
      withWbi: false,
    );
    final data = json['data'];
    if (data is! Map) {
      return const CommentPage(comments: [], total: 0, hasMore: false);
    }
    final pageInfo = data['page'];
    final total = pageInfo is Map ? _asInt(pageInfo['count']) : 0;
    final replies = data['replies'];
    final out = <Comment>[];
    if (replies is List) {
      for (final raw in replies) {
        if (raw is Map<String, dynamic>) out.add(Comment.fromJson(raw));
      }
    }
    return CommentPage(
      comments: out,
      total: total,
      hasMore: out.isNotEmpty && (page * ps) < total,
    );
  }

  // ------------------------------------------------------------ 三连相关

  /// 是否已点赞
  Future<bool> hasLike(String bvid) async {
    if (!_client.jar.isLoggedIn) return false;
    try {
      final json = await _client.getJson(
        'https://api.bilibili.com/x/web-interface/archive/has/like',
        query: {'bvid': bvid},
        withWbi: false,
      );
      return _asInt(json['data']) == 1;
    } catch (_) {
      return false;
    }
  }

  /// 已投币数（0/1/2）
  Future<int> coinCount(String bvid) async {
    if (!_client.jar.isLoggedIn) return 0;
    try {
      final json = await _client.getJson(
        'https://api.bilibili.com/x/web-interface/archive/coins',
        query: {'bvid': bvid},
        withWbi: false,
      );
      final data = json['data'];
      if (data is Map) return _asInt(data['multiply']);
      return 0;
    } catch (_) {
      return 0;
    }
  }

  /// 是否已收藏
  Future<bool> hasFav(int aid) async {
    if (!_client.jar.isLoggedIn) return false;
    try {
      final json = await _client.getJson(
        'https://api.bilibili.com/x/v2/fav/video/favoured',
        query: {'aid': aid},
        withWbi: false,
      );
      final data = json['data'];
      if (data is Map) return data['favoured'] == true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 点赞 / 取消点赞
  ///
  /// 需要登录且带 csrf（bili_jct）。返回 (成功, 提示语)。
  Future<ActionResult> like(String bvid, {required bool liked, required int aid}) async {
    return _postAction(
      'https://api.bilibili.com/x/web-interface/archive/like',
      {'bvid': bvid, 'like': liked ? 2 : 1},
    );
  }

  /// 投币（multiply: 1 或 2，是否同时点赞）
  Future<ActionResult> coin(
    String bvid, {
    int multiply = 1,
    bool alsoLike = false,
  }) async {
    return _postAction(
      'https://api.bilibili.com/x/web-interface/coin/add',
      {
        'bvid': bvid,
        'multiply': multiply,
        'select_like': alsoLike ? 1 : 0,
      },
    );
  }

  /// 收藏到默认收藏夹
  Future<ActionResult> favorite(int aid) async {
    // 先找默认收藏夹
    final mid = _client.jar.userId ?? '';
    if (mid.isEmpty) {
      return const ActionResult(ok: false, message: '请先登录');
    }
    int folderId = 0;
    try {
      final list = await _client.getJson(
        'https://api.bilibili.com/x/v3/fav/folder/created/list-all',
        query: {'up_mid': mid},
        withWbi: false,
        acceptCodes: const {-101, -400},
      );
      final data = list['data'];
      if (data is Map) {
        final arr = data['list'];
        if (arr is List && arr.isNotEmpty) {
          folderId = _asInt((arr.first as Map)['id']);
        }
      }
    } catch (_) {}

    return _postAction(
      'https://api.bilibili.com/x/v3/fav/resource/deal',
      {
        'rid': aid,
        'type': 2,
        'add_media_ids': folderId > 0 ? '$folderId' : '',
        'del_media_ids': '',
      },
    );
  }

  /// 统一处理需要 csrf 的写操作
  Future<ActionResult> _postAction(String url, Map<String, dynamic> body) async {
    final csrf = _client.jar['bili_jct'] ?? '';
    if (!_client.jar.isLoggedIn || csrf.isEmpty) {
      return const ActionResult(ok: false, message: '请先登录');
    }
    try {
      final json = await _client.postForm(
        url,
        {...body, 'csrf': csrf},
        acceptCodes: const {-101, -111},
      );
      final code = _asInt(json['code']);
      if (code == 0) return const ActionResult(ok: true);
      return ActionResult(
        ok: false,
        message: json['message']?.toString() ?? '操作失败',
      );
    } catch (e) {
      return ActionResult(ok: false, message: e.toString());
    }
  }

  // ------------------------------------------------------------ UP 空间

  /// UP 主空间信息
  Future<UpProfile> upProfile(int mid) async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/space/wbi/acc/info',
      query: {
        'mid': mid,
        'platform': 'web',
        'web_location': 1550101,
      },
    );
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw BiliException('UP 主信息解析失败');
    }
    return UpProfile.fromJson(data);
  }

  /// UP 主投稿列表
  Future<List<SpaceVideo>> upVideos(
    int mid, {
    int page = 1,
    int ps = 20,
    String keyword = '',
  }) async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/space/wbi/arc/search',
      query: {
        'mid': mid,
        'pn': page,
        'ps': ps,
        'order': 'pubdate',
        'platform': 'web',
        'web_location': 1550101,
        'keyword': keyword,
      },
    );
    final data = json['data'];
    if (data is! Map) return const [];
    final list = data['list'];
    if (list is! Map) return const [];
    final vlist = list['vlist'];
    if (vlist is! List) return const [];
    final out = <SpaceVideo>[];
    for (final raw in vlist) {
      if (raw is Map<String, dynamic>) out.add(SpaceVideo.fromJson(raw));
    }
    return out;
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

/// 写操作结果
class ActionResult {
  const ActionResult({required this.ok, this.message});
  final bool ok;
  final String? message;
}

class QrLoginSession {
  const QrLoginSession({required this.url, required this.key});
  final String url;
  final String key;
}

enum QrLoginStatus { pending, scanned, success, expired }

class QrLoginResult {
  const QrLoginResult({required this.status, this.message});
  final QrLoginStatus status;
  final String? message;
}

/// 从登录回调 URL 中提取 cookie 并写入罐子
extension on CookieJar {
  void absorbCookiesFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final patch = <String, String>{};
    uri.queryParameters.forEach((k, v) {
      if (k == 'SESSDATA' || k == 'DedeUserID' || k == 'DedeUserID__ckMd5' || k == 'bili_jct') {
        if (v.isNotEmpty) patch[k] = v;
      }
    });
    if (patch.isNotEmpty) setAll(patch);
  }
}

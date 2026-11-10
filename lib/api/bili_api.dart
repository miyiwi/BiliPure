import '../core/http.dart';
import '../models/feed_item.dart';
import '../models/play_info.dart';
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
  Future<Map<String, dynamic>> navInfo() async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/web-interface/nav',
      withWbi: false,
    );
    final data = json['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  Future<void> logout() => _client.jar.clear();

  /// 评论（第一版仅只读展示）
  Future<List<CommentItem>> comments({
    required int aid,
    int page = 1,
    int ps = 20,
  }) async {
    final json = await _client.getJson(
      'https://api.bilibili.com/x/v2/reply',
      query: {
        'type': 1,
        'oid': aid,
        'pn': page,
        'ps': ps,
        'sort': 2, // 2=按热度
      },
      withWbi: false,
    );
    final data = json['data'];
    if (data is! Map) return const [];
    final replies = data['replies'];
    if (replies is! List) return const [];
    final out = <CommentItem>[];
    for (final raw in replies) {
      if (raw is! Map<String, dynamic>) continue;
      out.add(CommentItem.fromJson(raw));
    }
    return out;
  }
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

class CommentItem {
  const CommentItem({
    required this.rpid,
    required this.author,
    required this.avatar,
    required this.content,
    required this.like,
    required this.ctime,
    required this.replyCount,
  });

  final int rpid;
  final String author;
  final String avatar;
  final String content;
  final int like;
  final int ctime;
  final int replyCount;

  factory CommentItem.fromJson(Map<String, dynamic> json) {
    final member = json['member'];
    final content = json['content'];
    final ctime = json['ctime'];
    final like = json['like'];
    final rcount = json['rcount'];
    return CommentItem(
      rpid: _i(json['rpid']),
      author: member is Map ? (member['uname']?.toString() ?? '') : '',
      avatar: member is Map ? FeedItem.httpsUrl(member['avatar']?.toString() ?? '') : '',
      content: content is Map ? (content['message']?.toString() ?? '') : '',
      like: _i(like),
      ctime: _i(ctime),
      replyCount: _i(rcount),
    );
  }

  static int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
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

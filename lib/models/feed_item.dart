/// 视频卡片数据（首页推荐 / 热门 / 相关推荐共用）
class FeedItem {
  const FeedItem({
    required this.bvid,
    required this.aid,
    required this.cid,
    required this.title,
    required this.cover,
    required this.duration,
    this.ownerName = '',
    this.ownerFace = '',
    this.ownerMid = 0,
    this.view = 0,
    this.danmakuCount = 0,
    this.reason = '',
    this.desc = '',
    this.pubdate = 0,
  });

  final String bvid;
  final int aid;
  final int cid;
  final String title;
  final String cover;
  final int duration;
  final String ownerName;
  final String ownerFace;
  final int ownerMid;
  final int view;
  final int danmakuCount;

  /// 推荐理由，例如 "1万点赞"
  final String reason;
  final String desc;
  final int pubdate;

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static String _asString(dynamic v) => v?.toString() ?? '';

  /// https 化：接口偶尔返回 http 图片，iOS ATS 会拦截
  static String httpsUrl(String url) {
    if (url.isEmpty) return url;
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('http://')) return 'https://${url.substring(7)}';
    return url;
  }

  factory FeedItem.fromJson(Map<String, dynamic> json) {
    final owner = json['owner'];
    final stat = json['stat'];
    final reason = json['rcmd_reason'];
    return FeedItem(
      bvid: _asString(json['bvid']),
      aid: _asInt(json['id'] ?? json['aid']),
      cid: _asInt(json['cid']),
      title: _asString(json['title']),
      cover: httpsUrl(_asString(json['pic'])),
      duration: _asInt(json['duration']),
      ownerName: owner is Map ? _asString(owner['name']) : '',
      ownerFace: owner is Map ? httpsUrl(_asString(owner['face'])) : '',
      ownerMid: owner is Map ? _asInt(owner['mid']) : 0,
      view: stat is Map ? _asInt(stat['view']) : 0,
      danmakuCount: stat is Map ? _asInt(stat['danmaku']) : 0,
      reason: reason is Map ? _asString(reason['content']) : '',
      desc: _asString(json['desc']),
      pubdate: _asInt(json['pubdate']),
    );
  }

  /// 推荐流里混着广告/直播/番剧，只保留普通视频
  bool get isPlayable => bvid.isNotEmpty && cid > 0;

  Map<String, String> toJson() => {
    'bvid': bvid,
    'aid': '$aid',
    'cid': '$cid',
    'title': title,
    'cover': cover,
    'duration': '$duration',
  };
}

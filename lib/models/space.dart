import 'feed_item.dart';

/// UP 主空间信息
class UpProfile {
  const UpProfile({
    required this.mid,
    required this.name,
    required this.face,
    required this.sign,
    required this.level,
    required this.fans,
    required this.archives,
    required this.likes,
    required this.banner,
  });

  final int mid;
  final String name;
  final String face;
  final String sign;
  final int level;
  final int fans;
  final int archives;
  final int likes;
  final String banner;

  factory UpProfile.fromJson(Map<String, dynamic> json) {
    final relation = json['relation'];
    final banner = json['top_photo']?.toString() ?? '';
    return UpProfile(
      mid: _i(json['mid']),
      name: json['name']?.toString() ?? '',
      face: FeedItem.httpsUrl(json['face']?.toString() ?? ''),
      sign: json['sign']?.toString() ?? '',
      level: _i(json['level']),
      // 部分接口把粉丝数放在 follower，部分是 relation.follower
      fans: _i(json['follower'] ?? (relation is Map ? relation['follower'] : null)),
      archives: _i(json['archive_count']),
      likes: _i(json['like_num']),
      banner: FeedItem.httpsUrl(banner),
    );
  }

  static int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

/// 空间的一个视频条目（space/arc/search 返回的 vlist 与首页 item 结构不同）
class SpaceVideo {
  const SpaceVideo({
    required this.bvid,
    required this.aid,
    required this.title,
    required this.cover,
    required this.duration,
    required this.play,
    required this.danmaku,
    required this.pubdate,
    required this.created,
  });

  final String bvid;
  final int aid;
  final String title;
  final String cover;

  /// space 接口的 length 是 "mm:ss" 字符串
  final String duration;
  final int play;
  final int danmaku;
  final int pubdate;
  final int created;

  int get durationSeconds {
    final parts = duration.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]) ?? 0;
      final s = int.tryParse(parts[1]) ?? 0;
      return m * 60 + s;
    }
    if (parts.length == 3) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      final s = int.tryParse(parts[2]) ?? 0;
      return h * 3600 + m * 60 + s;
    }
    return int.tryParse(duration) ?? 0;
  }

  /// 转成通用卡片模型
  FeedItem toFeedItem({String ownerName = '', String ownerFace = '', int ownerMid = 0}) {
    return FeedItem(
      bvid: bvid,
      aid: aid,
      cid: 0, // 由详情接口补齐
      title: title,
      cover: cover,
      duration: durationSeconds,
      ownerName: ownerName,
      ownerFace: ownerFace,
      ownerMid: ownerMid,
      view: play,
      danmakuCount: danmaku,
      pubdate: pubdate > 0 ? pubdate : created,
    );
  }

  factory SpaceVideo.fromJson(Map<String, dynamic> json) {
    return SpaceVideo(
      bvid: json['bvid']?.toString() ?? '',
      aid: _i(json['aid']),
      title: json['title']?.toString() ?? '',
      cover: FeedItem.httpsUrl(json['pic']?.toString() ?? ''),
      duration: json['length']?.toString() ?? '',
      play: _i(json['play']),
      danmaku: _i(json['video_review']),
      pubdate: _i(json['pubdate']),
      created: _i(json['created']),
    );
  }

  static int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

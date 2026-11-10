import 'feed_item.dart';

/// 视频详情（/x/web-interface/view）
class VideoDetail {
  const VideoDetail({
    required this.bvid,
    required this.aid,
    required this.title,
    required this.cover,
    required this.desc,
    required this.duration,
    required this.ownerName,
    required this.ownerFace,
    required this.ownerMid,
    required this.view,
    required this.danmakuCount,
    required this.reply,
    required this.like,
    required this.coin,
    required this.favorite,
    required this.share,
    required this.pubdate,
    required this.pages,
    required this.tname,
  });

  final String bvid;
  final int aid;
  final String title;
  final String cover;
  final String desc;
  final int duration;
  final String ownerName;
  final String ownerFace;
  final int ownerMid;
  final int view;
  final int danmakuCount;
  final int reply;
  final int like;
  final int coin;
  final int favorite;
  final int share;
  final int pubdate;
  final List<VideoPage> pages;
  final String tname;

  VideoPage get firstPage => pages.isEmpty
      ? const VideoPage(cid: 0, page: 1, part: '', duration: 0)
      : pages.first;

  factory VideoDetail.fromJson(Map<String, dynamic> json) {
    final owner = json['owner'];
    final stat = json['stat'];
    final rawPages = json['pages'];
    final pages = <VideoPage>[];
    if (rawPages is List) {
      for (final p in rawPages) {
        if (p is Map<String, dynamic>) pages.add(VideoPage.fromJson(p));
      }
    }
    return VideoDetail(
      bvid: _s(json['bvid']),
      aid: _i(json['aid']),
      title: _s(json['title']),
      cover: FeedItem.httpsUrl(_s(json['pic'])),
      desc: _s(json['desc']),
      duration: _i(json['duration']),
      ownerName: owner is Map ? _s(owner['name']) : '',
      ownerFace: owner is Map ? FeedItem.httpsUrl(_s(owner['face'])) : '',
      ownerMid: owner is Map ? _i(owner['mid']) : 0,
      view: stat is Map ? _i(stat['view']) : 0,
      danmakuCount: stat is Map ? _i(stat['danmaku']) : 0,
      reply: stat is Map ? _i(stat['reply']) : 0,
      like: stat is Map ? _i(stat['like']) : 0,
      coin: stat is Map ? _i(stat['coin']) : 0,
      favorite: stat is Map ? _i(stat['favorite']) : 0,
      share: stat is Map ? _i(stat['share']) : 0,
      pubdate: _i(json['pubdate']),
      pages: pages,
      tname: _s(json['tname']),
    );
  }

  static int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static String _s(dynamic v) => v?.toString() ?? '';
}

/// 分 P 信息
class VideoPage {
  const VideoPage({
    required this.cid,
    required this.page,
    required this.part,
    required this.duration,
  });

  final int cid;
  final int page;
  final String part;
  final int duration;

  factory VideoPage.fromJson(Map<String, dynamic> json) => VideoPage(
    cid: VideoDetail._i(json['cid']),
    page: VideoDetail._i(json['page']),
    part: VideoDetail._s(json['part']),
    duration: VideoDetail._i(json['duration']),
  );

  String get label => page <= 1 && part.isEmpty ? 'P1' : 'P$page $part'.trim();
}

/// 播放地址与清晰度
class PlayInfo {
  const PlayInfo({
    required this.urls,
    required this.quality,
    required this.acceptQuality,
    required this.acceptDescription,
    required this.backupUrls,
    this.isDash = false,
    this.dashVideoUrl = '',
    this.dashAudioUrl = '',
  });

  /// 逐段播放地址（durl）
  final List<String> urls;

  /// 备用地址（每个分段的 backup_url）
  final List<String> backupUrls;

  final int quality;
  final List<int> acceptQuality;
  final List<String> acceptDescription;
  final bool isDash;
  final String dashVideoUrl;
  final String dashAudioUrl;

  bool get isPlayable => urls.isNotEmpty || (isDash && dashVideoUrl.isNotEmpty);

  /// 清晰度 id -> 中文名
  static const Map<int, String> qualityNames = {
    127: '8K 超高清',
    126: '杜比视界',
    125: 'HDR 真彩',
    120: '4K 超清',
    116: '1080P60',
    112: '1080P+',
    80: '1080P 高清',
    74: '720P60',
    64: '720P 高清',
    32: '480P 清晰',
    16: '360P 流畅',
    6: '240P 极速',
  };

  static String nameOf(int q) => qualityNames[q] ?? '${q}P';

  factory PlayInfo.fromJson(Map<String, dynamic> data) {
    final urls = <String>[];
    final backups = <String>[];
    final accept = <int>[];
    final acceptDesc = <String>[];

    final dash = data['dash'];
    var isDash = false;
    var dashVideo = '';
    var dashAudio = '';

    final rawAccept = data['accept_quality'];
    final rawDesc = data['accept_description'];
    if (rawAccept is List) {
      for (final q in rawAccept) {
        if (q is int) accept.add(q);
      }
    }
    if (rawDesc is List) {
      for (final d in rawDesc) {
        acceptDesc.add(d?.toString() ?? '');
      }
    }

    final durl = data['durl'];
    if (durl is List) {
      for (final seg in durl) {
        if (seg is Map) {
          final u = seg['url']?.toString() ?? '';
          if (u.isNotEmpty) urls.add(u);
          final bu = seg['backup_url'];
          if (bu is List) {
            for (final b in bu) {
              final s = b?.toString() ?? '';
              if (s.isNotEmpty) backups.add(s);
            }
          }
        }
      }
    }

    // DASH：音视频分离，很多视频没有 durl，只能走 dash
    if (urls.isEmpty && dash is Map) {
      final videos = dash['video'];
      final audios = dash['audio'];
      if (videos is List && videos.isNotEmpty) {
        final v = videos.first;
        if (v is Map) {
          dashVideo = (v['baseUrl'] ?? v['base_url'] ?? '').toString();
          if (dashVideo.isEmpty) {
            final bu = v['backupUrl'] ?? v['backup_url'];
            if (bu is List && bu.isNotEmpty) dashVideo = bu.first.toString();
          }
        }
      }
      if (audios is List && audios.isNotEmpty) {
        final a = audios.first;
        if (a is Map) {
          dashAudio = (a['baseUrl'] ?? a['base_url'] ?? '').toString();
          if (dashAudio.isEmpty) {
            final bu = a['backupUrl'] ?? a['backup_url'];
            if (bu is List && bu.isNotEmpty) dashAudio = bu.first.toString();
          }
        }
      }
      isDash = dashVideo.isNotEmpty;
    }

    return PlayInfo(
      urls: urls,
      backupUrls: backups,
      quality: _i(data['quality']),
      acceptQuality: accept,
      acceptDescription: acceptDesc,
      isDash: isDash,
      dashVideoUrl: dashVideo,
      dashAudioUrl: dashAudio,
    );
  }

  static int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

/// 评论
class Comment {
  const Comment({
    required this.rpid,
    required this.author,
    required this.avatar,
    required this.content,
    required this.like,
    required this.ctime,
    required this.replyCount,
    required this.level,
  });

  final int rpid;
  final String author;
  final String avatar;
  final String content;
  final int like;
  final int ctime;
  final int replyCount;
  final int level;

  factory Comment.fromJson(Map<String, dynamic> json) {
    final member = json['member'];
    final content = json['content'];
    final levelInfo = member is Map ? member['level_info'] : null;
    return Comment(
      rpid: _i(json['rpid']),
      author: member is Map ? (member['uname']?.toString() ?? '') : '',
      avatar: member is Map ? _https(member['avatar']?.toString() ?? '') : '',
      content: content is Map ? (content['message']?.toString() ?? '') : '',
      like: _i(json['like']),
      ctime: _i(json['ctime']),
      replyCount: _i(json['rcount']),
      level: levelInfo is Map ? _i(levelInfo['current_level']) : 0,
    );
  }

  static int _i(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static String _https(String url) {
    if (url.startsWith('http://')) return 'https://${url.substring(7)}';
    return url;
  }
}

/// 一页评论
class CommentPage {
  const CommentPage({
    required this.comments,
    required this.total,
    required this.hasMore,
  });

  final List<Comment> comments;
  final int total;
  final bool hasMore;
}

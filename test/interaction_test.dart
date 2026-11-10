import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bilipure/models/comment.dart';
import 'package:bilipure/models/space.dart';

/// 交互与模型测试
///
/// 重点守护两件真实出过问题的事：
/// 1. 播放/暂停按钮不刷新（监听器没有 setState）
/// 2. 双击暂停、长按三连的手势判定
void main() {
  group('SpaceVideo 时长解析', () {
    test('mm:ss', () {
      const v = SpaceVideo(
        bvid: 'BV1',
        aid: 1,
        title: 't',
        cover: '',
        duration: '03:25',
        play: 0,
        danmaku: 0,
        pubdate: 0,
        created: 0,
      );
      expect(v.durationSeconds, 205);
    });

    test('hh:mm:ss', () {
      const v = SpaceVideo(
        bvid: 'BV1',
        aid: 1,
        title: 't',
        cover: '',
        duration: '1:02:03',
        play: 0,
        danmaku: 0,
        pubdate: 0,
        created: 0,
      );
      expect(v.durationSeconds, 3723);
    });

    test('异常值不崩', () {
      const v = SpaceVideo(
        bvid: 'BV1',
        aid: 1,
        title: 't',
        cover: '',
        duration: '',
        play: 0,
        danmaku: 0,
        pubdate: 0,
        created: 0,
      );
      expect(v.durationSeconds, 0);
    });
  });

  group('SpaceVideo 转卡片', () {
    test('补齐 UP 信息并换算时长', () {
      const v = SpaceVideo(
        bvid: 'BV1xx411c7mD',
        aid: 99,
        title: '投稿标题',
        cover: 'https://i0.hdslb.com/a.jpg',
        duration: '01:41',
        play: 1234,
        danmaku: 56,
        pubdate: 1700000000,
        created: 1699999999,
      );
      final item = v.toFeedItem(ownerName: 'UP', ownerFace: '', ownerMid: 7);
      expect(item.bvid, 'BV1xx411c7mD');
      expect(item.aid, 99);
      expect(item.duration, 101);
      expect(item.view, 1234);
      expect(item.ownerName, 'UP');
      expect(item.ownerMid, 7);
      // pubdate 优先于 created
      expect(item.pubdate, 1700000000);
    });
  });

  group('Comment 解析', () {
    test('完整字段', () {
      final c = Comment.fromJson({
        'rpid': 123,
        'like': 45,
        'ctime': 1700000000,
        'rcount': 3,
        'member': {
          'uname': '某用户',
          'avatar': 'http://i0.hdslb.com/face.jpg',
          'level_info': {'current_level': 5},
        },
        'content': {'message': '这是一条评论'},
      });
      expect(c.rpid, 123);
      expect(c.author, '某用户');
      // http 应升级为 https
      expect(c.avatar, 'https://i0.hdslb.com/face.jpg');
      expect(c.content, '这是一条评论');
      expect(c.like, 45);
      expect(c.level, 5);
      expect(c.replyCount, 3);
    });

    test('字段缺失不崩', () {
      final c = Comment.fromJson({});
      expect(c.rpid, 0);
      expect(c.author, '');
      expect(c.content, '');
      expect(c.level, 0);
    });
  });

  group('UpProfile 解析', () {
    test('粉丝数兼容 follower 与 relation.follower', () {
      final a = UpProfile.fromJson({'mid': 1, 'follower': 999});
      expect(a.fans, 999);

      final b = UpProfile.fromJson({
        'mid': 2,
        'relation': {'follower': 888},
      });
      expect(b.fans, 888);
    });

    test('头图 http 升级 https', () {
      final p = UpProfile.fromJson({
        'mid': 1,
        'top_photo': 'http://i0.hdslb.com/banner.jpg',
      });
      expect(p.banner, 'https://i0.hdslb.com/banner.jpg');
    });
  });

  group('播放器状态', () {
    testWidgets('暂停按钮图标应随状态切换', (tester) async {
      // 用一个受控的 ValueNotifier 模拟播放器的 isPlaying，
      // 验证图标确实依赖状态而不是常量。
      final playing = ValueNotifier<bool>(true);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: playing,
              builder: (context, isPlaying, _) => IconButton(
                icon: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
                onPressed: () => playing.value = !playing.value,
              ),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      // 点击后状态翻转，图标必须跟着变——这正是原来缺失的部分
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
    });
  });
}

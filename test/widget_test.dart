import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bilipure/models/feed_item.dart';
import 'package:bilipure/widgets/error_view.dart';
import 'package:bilipure/widgets/video_card.dart';

/// 纯 UI 组件测试：不触发任何网络请求。
void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: SizedBox(width: 360, child: child))),
  );

  testWidgets('ErrorView 展示错误信息并响应重试', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      wrap(ErrorView(message: '网络不可用', onRetry: () => retried = true)),
    );
    expect(find.text('网络不可用'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, isTrue);
  });

  testWidgets('ErrorView 无回调时不显示重试按钮', (tester) async {
    await tester.pumpWidget(wrap(const ErrorView(message: '出错了')));
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('VideoCard 展示标题、时长与播放量', (tester) async {
    const item = FeedItem(
      bvid: 'BV1xx411c7mD',
      aid: 1,
      cid: 2,
      title: '测试视频标题',
      cover: '',
      duration: 101,
      ownerName: '某个UP主',
      view: 1076798,
    );

    await tester.pumpWidget(wrap(VideoCard(item: item)));
    await tester.pump();

    expect(find.text('测试视频标题'), findsOneWidget);
    expect(find.text('01:41'), findsOneWidget);
    expect(find.text('107.7万'), findsOneWidget);
    expect(find.text('某个UP主'), findsOneWidget);
  });

  testWidgets('VideoCard 点击触发回调', (tester) async {
    const item = FeedItem(
      bvid: 'BV1',
      aid: 1,
      cid: 2,
      title: '标题',
      cover: '',
      duration: 10,
    );
    var tapped = false;
    await tester.pumpWidget(wrap(VideoCard(item: item, onTap: () => tapped = true)));
    await tester.pump();
    await tester.tap(find.text('标题'));
    expect(tapped, isTrue);
  });

  testWidgets('VideoTile 展示播放与弹幕数', (tester) async {
    const item = FeedItem(
      bvid: 'BV1',
      aid: 1,
      cid: 2,
      title: '相关视频',
      cover: '',
      duration: 65,
      ownerName: 'UP',
      view: 12345,
      danmakuCount: 678,
    );
    await tester.pumpWidget(wrap(VideoTile(item: item)));
    await tester.pump();
    expect(find.text('相关视频'), findsOneWidget);
    expect(find.text('1.2万 播放 · 678 弹幕'), findsOneWidget);
    expect(find.text('01:05'), findsOneWidget);
  });
}

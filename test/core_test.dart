import 'package:flutter_test/flutter_test.dart';

import 'package:bilipure/core/format.dart';
import 'package:bilipure/core/wbi.dart';
import 'package:bilipure/models/danmaku.dart';
import 'package:bilipure/models/feed_item.dart';
import 'package:bilipure/models/play_info.dart';
import 'package:bilipure/services/danmaku_service.dart';

void main() {
  group('格式化', () {
    test('播放量', () {
      expect(formatCount(999), '999');
      expect(formatCount(10000), '1万');
      expect(formatCount(1076798), '107.7万');
      expect(formatCount(123456789), '1.2亿');
    });

    test('时长', () {
      expect(formatDuration(0), '00:00');
      expect(formatDuration(101), '01:41');
      expect(formatDuration(3725), '1:02:05');
    });

    test('相对时间', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(formatRelativeTime(now - 30), '刚刚');
      expect(formatRelativeTime(now - 120), '2分钟前');
      expect(formatRelativeTime(now - 7200), '2小时前');
      expect(formatRelativeTime(0), '');
    });
  });

  group('WBI 签名', () {
    test('从 URL 提取 key', () {
      expect(
        WbiSigner.keyFromUrl(
          'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
        ),
        '7cd084941338484aae1ad9425b84077c',
      );
    });

    test('mixinKey 长度为 32 且由重排表生成', () {
      const imgKey = '7cd084941338484aae1ad9425b84077c';
      const subKey = '4932caff0ff746eab6f01bf08b70ac45';
      final mixin = WbiSigner.mixinKeyOf(imgKey, subKey);
      expect(mixin.length, 32);
      // 混排表第一位是 46，所以首字符应等于 (imgKey+subKey)[46]
      expect(mixin[0], (imgKey + subKey)[46]);
    });

    test('签名查询串包含 wts 与 w_rid', () {
      final signer = WbiSigner(
        imgKey: '7cd084941338484aae1ad9425b84077c',
        subKey: '4932caff0ff746eab6f01bf08b70ac45',
      );
      final q = signer.signQuery({'bvid': 'BV1GJ411x7h7', 'cid': 123});
      expect(q, contains('wts='));
      expect(q, contains('w_rid='));
      expect(q, contains('bvid=BV1GJ411x7h7'));
      // 参数必须按 key 升序
      final keys = q.split('&').map((e) => e.split('=').first).toList();
      final withoutRid = keys.where((k) => k != 'w_rid').toList();
      final sorted = [...withoutRid]..sort();
      expect(withoutRid, sorted);
    });

    test('过滤 value 中的特殊字符', () {
      final signer = WbiSigner(imgKey: 'a' * 32, subKey: 'b' * 32);
      final q = signer.signQuery({'keyword': "key社!'()*"});
      final decoded = Uri.decodeComponent(
        q.split('&').firstWhere((e) => e.startsWith('keyword=')).split('=').skip(1).join('='),
      );
      expect(decoded, 'key社');
    });
  });

  group('弹幕解析', () {
    test('解析 p 属性', () {
      final dm = Danmaku.tryParse('1.234,1,25,16777215,1604742895,0,abc123,1', '你好世界');
      expect(dm, isNotNull);
      expect(dm!.time, 1.234);
      expect(dm.mode, 1);
      expect(dm.fontSize, 25);
      expect(dm.color, 0xFFFFFF);
      expect(dm.text, '你好世界');
      expect(dm.isScroll, isTrue);
    });

    test('p 属性不足时返回 null', () {
      expect(Danmaku.tryParse('1.0,1', 'x'), isNull);
      expect(Danmaku.tryParse('abc,1,25,16777215,0,0,h', 'x'), isNull);
    });

    test('模式分类', () {
      expect(Danmaku.tryParse('0,4,25,0,0,0,h', 'x')!.isBottom, isTrue);
      expect(Danmaku.tryParse('0,5,25,0,0,0,h', 'x')!.isTop, isTrue);
      expect(Danmaku.tryParse('0,1,25,0,0,0,h', 'x')!.isScroll, isTrue);
    });

    test('解析完整 XML 并反转义', () {
      const xml = '<?xml version="1.0"?><i>'
          '<d p="1.5,1,25,16777215,1604742895,0,hash1,1">前&lt;方&gt;高能</d>'
          '<d p="2.5,5,25,16711680,1604742896,0,hash2,2">顶部弹幕</d>'
          '</i>';
      final list = DanmakuService.parseXml(xml);
      expect(list.length, 2);
      expect(list[0].text, '前<方>高能');
      expect(list[1].isTop, isTrue);
      expect(list[1].color, 0xFF0000);
    });

    test('忽略空文本弹幕', () {
      const xml = '<i><d p="1.0,1,25,0,0,0,h,1"></d><d p="2.0,1,25,0,0,0,h,2">ok</d></i>';
      expect(DanmakuService.parseXml(xml).length, 1);
    });
  });

  group('数据模型', () {
    test('FeedItem 会过滤类型并解析字段', () {
      final item = FeedItem.fromJson({
        'bvid': 'BV1xx411c7mD',
        'cid': 123,
        'id': 456,
        'title': '标题',
        'pic': 'http://i0.hdslb.com/a.jpg',
        'duration': 100,
        'owner': {'name': 'UP主', 'face': 'http://i1.hdslb.com/f.jpg', 'mid': 789},
        'stat': {'view': 1234, 'danmaku': 56},
        'rcmd_reason': {'content': '1万点赞'},
      });
      expect(item.bvid, 'BV1xx411c7mD');
      expect(item.cid, 123);
      expect(item.isPlayable, isTrue);
      // http 应被升级为 https
      expect(item.cover, 'https://i0.hdslb.com/a.jpg');
      expect(item.ownerName, 'UP主');
      expect(item.view, 1234);
      expect(item.reason, '1万点赞');
    });

    test('cid 缺失时不可播放', () {
      final item = FeedItem.fromJson({'bvid': 'BV1', 'cid': 0});
      expect(item.isPlayable, isFalse);
    });

    test('PlayInfo 解析 durl', () {
      final info = PlayInfo.fromJson({
        'quality': 64,
        'accept_quality': [64, 32, 16],
        'accept_description': ['720P 高清', '480P 清晰', '360P 流畅'],
        'durl': [
          {'url': 'https://a.mp4', 'order': 1},
          {'url': 'https://b.mp4', 'order': 2},
        ],
      });
      expect(info.urls.length, 2);
      expect(info.quality, 64);
      expect(info.acceptQuality, [64, 32, 16]);
      expect(info.isPlayable, isTrue);
      expect(info.isDash, isFalse);
    });

    test('PlayInfo 解析 dash 兜底', () {
      final info = PlayInfo.fromJson({
        'quality': 80,
        'dash': {
          'video': [
            {'baseUrl': 'https://v.m4s'},
          ],
          'audio': [
            {'baseUrl': 'https://a.m4s'},
          ],
        },
      });
      expect(info.isDash, isTrue);
      expect(info.dashVideoUrl, 'https://v.m4s');
      expect(info.dashAudioUrl, 'https://a.m4s');
      expect(info.isPlayable, isTrue);
    });

    test('清晰度名称', () {
      expect(PlayInfo.nameOf(80), '1080P 高清');
      expect(PlayInfo.nameOf(999), '999P');
    });
  });
}

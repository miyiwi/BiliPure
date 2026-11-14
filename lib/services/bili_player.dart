import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 哔哩哔哩的 CDN 会按 UA 判断，不带浏览器 UA 直接 403
const String kBiliUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

const Map<String, String> kBiliHeaders = {
  'Referer': 'https://www.bilibili.com/',
  'User-Agent': kBiliUserAgent,
};

/// 播放器封装
///
/// 用 media_kit（libmpv）替代 video_player。核心理由：它支持 **DASH 分离流**，
/// 可以用 `AudioTrack.uri()` 把独立音轨挂到视频上（内部走 mpv 的 audio-add），
/// 这是 video_player/AVPlayer 单实例做不到的，也是清晰度卡在 720P 的原因。
class BiliPlayer {
  BiliPlayer() {
    _player = Player(
      configuration: const PlayerConfiguration(
        // 降低日志噪音
        logLevel: MPVLogLevel.error,
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
  }

  late final Player _player;
  late final VideoController _controller;

  Player get player => _player;
  VideoController get controller => _controller;

  bool get isPlaying => _player.state.playing;
  bool get isBuffering => _player.state.buffering;
  Duration get position => _player.state.position;
  Duration get duration => _player.state.duration;

  Stream<Duration> get positionStream => _player.stream.position;
  Stream<Duration> get durationStream => _player.stream.duration;
  Stream<bool> get playingStream => _player.stream.playing;
  Stream<bool> get bufferingStream => _player.stream.buffering;
  Stream<bool> get completedStream => _player.stream.completed;

  /// 打开媒体
  ///
  /// [audioUrl] 非空时走 DASH：先开视频轨，再用 [AudioTrack.uri] 挂音轨。
  Future<void> open({
    required String videoUrl,
    String? audioUrl,
    Duration startAt = Duration.zero,
  }) async {
    await _player.open(
      Media(videoUrl, httpHeaders: kBiliHeaders),
      play: false,
    );

    final hasAudio = audioUrl != null && audioUrl.isNotEmpty;
    if (hasAudio) {
      // AudioTrack.uri 会走 mpv 的 `audio-add <url> select`，
      // 这是 media_kit 为外挂音轨提供的公开方式。
      try {
        await _player.setAudioTrack(
          AudioTrack.uri(
            audioUrl,
            title: 'bilibili',
            language: 'zh',
          ),
        );
      } catch (_) {
        // 挂载失败就只播视频轨（无声），不阻塞
      }
    }

    if (startAt > Duration.zero) {
      await _player.seek(startAt);
    }
    await _player.play();
  }

  Future<void> playOrPause() => _player.playOrPause();
  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> seek(Duration p) => _player.seek(p);
  Future<void> setRate(double rate) => _player.setRate(rate);

  Future<void> dispose() => _player.dispose();
}

/// 全局初始化，main 里调用一次
void ensureMediaKitInitialized() {
  if (_initialized) return;
  MediaKit.ensureInitialized();
  _initialized = true;
}

bool _initialized = false;

/// 播放速率选项
const List<double> kPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

String rateLabel(double r) {
  if (r == r.roundToDouble()) return '${r.toInt()}x';
  return '${r}x';
}

@visibleForTesting
bool get mediaKitReady => _initialized;

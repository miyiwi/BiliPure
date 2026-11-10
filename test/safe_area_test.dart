import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 安全区测试：验证在带刘海 / home indicator 的机型上，
/// 顶部内容不会被状态栏遮挡，底部标签栏不会被 home indicator 压住。
///
/// 注意：这里不启动整个 App（会触发真实网络请求），
/// 而是复刻 RootShell 的布局结构做隔离测试。
void main() {
  const topInset = 59.0; // iPhone 14 Pro 状态栏
  const bottomInset = 34.0; // home indicator

  /// 复刻 RootShell 的 Scaffold 布局
  Widget buildShell() {
    return MediaQuery(
      data: const MediaQueryData(
        size: Size(393, 852),
        devicePixelRatio: 3,
      ).copyWith(
        padding: const EdgeInsets.only(top: topInset, bottom: bottomInset),
        viewPadding: const EdgeInsets.only(top: topInset, bottom: bottomInset),
        viewInsets: EdgeInsets.zero,
      ),
      child: Builder(
        builder: (context) {
          final bottom = MediaQuery.viewPaddingOf(context).bottom;
          return MaterialApp(
            home: Scaffold(
              body: SafeArea(
                top: true,
                bottom: false,
                child: ListView(
                  children: const [
                    SizedBox(height: 40, child: Text('内容')),
                  ],
                ),
              ),
              bottomNavigationBar: Padding(
                padding: EdgeInsets.only(bottom: bottom),
                child: NavigationBar(
                  selectedIndex: 0,
                  height: 58,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.home_outlined),
                      label: '推荐',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.local_fire_department_outlined),
                      label: '热门',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.person_outline_rounded),
                      label: '我的',
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  testWidgets('底部标签栏为 home indicator 预留 34pt 空间', (tester) async {
    await tester.pumpWidget(buildShell());
    await tester.pumpAndSettle();

    // NavigationBar 外面必须有一层 bottom=34 的 Padding
    final wrapper = tester.widgetList<Padding>(
      find.ancestor(
        of: find.byType(NavigationBar),
        matching: find.byType(Padding),
      ),
    );
    expect(
      wrapper.any((p) {
        final insets = p.padding;
        return insets is EdgeInsets && insets.bottom == bottomInset;
      }),
      isTrue,
      reason: 'NavigationBar 底部必须留出 home indicator 空间，否则标签会被遮挡',
    );
  });

  testWidgets('主体内容被 SafeArea 包住并避开状态栏', (tester) async {
    await tester.pumpWidget(buildShell());
    await tester.pumpAndSettle();

    expect(find.byType(SafeArea), findsWidgets);

    // 内容实际顶部坐标应 >= 状态栏高度
    final contentTop = tester.getTopLeft(find.text('内容')).dy;
    expect(
      contentTop,
      greaterThanOrEqualTo(topInset),
      reason: '内容不能跑到状态栏下面',
    );
  });

  testWidgets('标签栏顶部不会被内容遮住', (tester) async {
    await tester.pumpWidget(buildShell());
    await tester.pumpAndSettle();

    final navTop = tester.getTopLeft(find.byType(NavigationBar)).dy;
    final screenHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(navTop, lessThan(screenHeight));

    // 标签栏底部应给 home indicator 让位
    final navBottom = tester.getBottomLeft(find.byType(NavigationBar)).dy;
    expect(
      navBottom,
      lessThanOrEqualTo(screenHeight - bottomInset + 0.5),
      reason: '标签栏不能盖住 home indicator 区域',
    );
  });
}

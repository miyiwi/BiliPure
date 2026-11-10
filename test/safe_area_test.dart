import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 安全区测试
///
/// 关键点：Flutter 的 NavigationBar 内部已经自带 SafeArea
/// （见 material/navigation_bar.dart），所以**不要**在外面再包 Padding，
/// 否则底栏会重复加高、多出一条空白。这里专门守住这一点。
void main() {
  const topInset = 59.0; // iPhone 14 Pro 状态栏
  const bottomInset = 34.0; // home indicator

  /// 复刻 RootShell 的布局：body 用 SafeArea(top)，底栏保持原样
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
      child: MaterialApp(
        home: Scaffold(
          body: SafeArea(
            top: true,
            bottom: false,
            child: ListView(
              children: const [SizedBox(height: 40, child: Text('内容'))],
            ),
          ),
          bottomNavigationBar: NavigationBar(
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
  }

  testWidgets('底栏外面不要重复包 Padding（NavigationBar 自带 SafeArea）', (tester) async {
    await tester.pumpWidget(buildShell());
    await tester.pumpAndSettle();

    // 找 NavigationBar 的祖先 Padding，不该有 bottom=34 的那一层
    final wrapper = tester.widgetList<Padding>(
      find.ancestor(
        of: find.byType(NavigationBar),
        matching: find.byType(Padding),
      ),
    );
    final hasInjectedInset = wrapper.any((p) {
      final insets = p.padding;
      return insets is EdgeInsets && insets.bottom == bottomInset;
    });
    expect(
      hasInjectedInset,
      isFalse,
      reason: 'NavigationBar 内部已有 SafeArea，外面再加 bottom padding 会导致底栏过高',
    );
  });

  testWidgets('NavigationBar 内部确实带了 SafeArea', (tester) async {
    await tester.pumpWidget(buildShell());
    await tester.pumpAndSettle();

    final inner = find.descendant(
      of: find.byType(NavigationBar),
      matching: find.byType(SafeArea),
    );
    expect(inner, findsWidgets);
  });

  testWidgets('主体内容避开状态栏', (tester) async {
    await tester.pumpWidget(buildShell());
    await tester.pumpAndSettle();

    final contentTop = tester.getTopLeft(find.text('内容')).dy;
    expect(
      contentTop,
      greaterThanOrEqualTo(topInset),
      reason: '内容不能跑到状态栏下面',
    );
  });

  testWidgets('主题体 SafeArea 开启 top', (tester) async {
    await tester.pumpWidget(buildShell());
    await tester.pumpAndSettle();

    final areas = tester.widgetList<SafeArea>(find.byType(SafeArea));
    expect(areas.any((s) => s.top == true), isTrue);
  });
}

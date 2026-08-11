import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/navigation/back_dispatch_hold.dart';
import 'package:fluxdo/widgets/common/predictive_back_cupertino_transitions.dart'
    show predictiveBackGestureActive;

/// BackDispatchHold:退场动画窗口内 setFrameworkHandlesBack 不得翻
/// false(翻了=引擎注销 OnBackInvokedCallback,第二划被系统当「关
/// Activity」接管,整窗缩小黑边);resumed 重发对齐引擎注册态。
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late List<bool> sentValues;
  late BackDispatchHold hold;

  setUp(() {
    sentValues = [];
    hold = BackDispatchHold();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
          sentValues.add(call.arguments as bool);
        }
        return null;
      },
    );
  });

  tearDown(() {
    predictiveBackGestureActive.value = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Widget buildApp() {
    return MaterialApp(
      navigatorObservers: [hold],
      onNavigationNotification: hold.onNavigationNotification,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('page B')),
              ),
            ),
            child: const Text('page A'),
          ),
        ),
      ),
    );
  }

  testWidgets('退场动画窗口内不下发 false,窗口结束回写真实值',
      (tester) async {
    // 测试环境 lifecycleState 默认 null,_push 会按「app 未就绪」跳过
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(buildApp());
    await tester.tap(find.text('page A'));
    await tester.pumpAndSettle();
    // 栈深 2:最后一次上报应为 true
    expect(sentValues.isNotEmpty, isTrue);
    expect(sentValues.last, isTrue);

    sentValues.clear();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    // pop 同帧 canPop 已翻 false,但退场动画进行中:不得下发 false
    await tester.pump(const Duration(milliseconds: 100));
    expect(sentValues.contains(false), isFalse,
        reason: '退场窗口内下发 false = 引擎注销回调 = 连划黑边');

    // 动画播完:按真实值(根路由 canPop=false → canHandlePop 视配置)
    await tester.pumpAndSettle();
    await tester.pump(); // postFrame 回写
    expect(sentValues.isNotEmpty, isTrue);
    expect(sentValues.last, isFalse, reason: '窗口结束应回写真实值');
  });

  testWidgets('resumed 重发当前值,对齐引擎注册态', (tester) async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(buildApp());
    await tester.tap(find.text('page A'));
    await tester.pumpAndSettle();

    sentValues.clear();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(sentValues, contains(true),
        reason: '回前台必须重发,修锁屏后引擎注册态失联');
  });

  testWidgets('预测返回手势进行中不撤注册(即使 canPop 已翻 false)',
      (tester) async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(buildApp());
    await tester.tap(find.text('page A'));
    await tester.pumpAndSettle();

    sentValues.clear();
    // 模拟手势活跃(detector 认领时置位;含静默认领)
    predictiveBackGestureActive.value = true;
    // 手势中路由态变化把 canPop 翻 false(如静默认领 commit 的排队
    // pop、退场收尾),默认实现会立刻注销回调把手势拦腰截断
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(sentValues.contains(false), isFalse,
        reason: '手势进行中下发 false = 注销回调 = 手势被系统接管出黑底');

    // 手势结束:按真实值回写
    predictiveBackGestureActive.value = false;
    await tester.pump();
    expect(sentValues.isNotEmpty, isTrue);
    expect(sentValues.last, isFalse, reason: '手势结束后应回写真实值');
  });
}

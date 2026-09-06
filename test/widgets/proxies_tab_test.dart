import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/proxies/list.dart';
import 'package:fl_clash/views/proxies/tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

void main() {
  late ProviderContainer globalContainer;
  late ProviderSubscription<Profile?> currentProfileSubscription;
  late _MockCoreHandlerInterface coreHandler;

  setUpAll(() {
    registerFallbackValue(
      const ChangeProxyParams(groupName: '', proxyName: ''),
    );
  });

  setUp(() {
    coreHandler = _MockCoreHandlerInterface();
    CoreController.resetInstance();
    CoreController.test(coreHandler);
    when(
      () => coreHandler.changeProxy(
        any(),
        closeConnections: any(named: 'closeConnections'),
      ),
    ).thenAnswer((_) async => '');
    when(
      () => coreHandler.getProxies(),
    ).thenAnswer((_) async => _proxiesData());
    final profile = Profile.normal().copyWith(
      currentGroupName: 'B',
      selectedMap: {'A': 'Node A', 'B': 'Node B'},
    );
    globalContainer = ProviderContainer(
      overrides: [
        currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
        profilesProvider.overrideWith(() => _TestProfiles([profile])),
        currentGroupsStateProvider.overrideWithValue(
          GroupsState(value: [_group('A'), _group('B'), _group('C')]),
        ),
      ],
    );
    globalState.container = globalContainer;
    currentProfileSubscription = globalContainer.listen(
      currentProfileProvider,
      (_, _) {},
    );
  });

  tearDown(() {
    debouncer.cancel(FunctionTag.changeProxy);
    debouncer.cancel(FunctionTag.updateGroups);
    currentProfileSubscription.close();
    globalContainer.dispose();
    CoreController.resetInstance();
  });

  testWidgets('current group follows the rendered tab list', (tester) async {
    final key = GlobalKey<ProxiesTabViewState>();
    final renderedGroups = [_group('B'), _group('C')];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          proxiesTabStateProvider.overrideWithValue(
            ProxiesTabState(
              groups: renderedGroups,
              currentGroupName: 'B',
              proxyCardType: ProxyCardType.standard,
            ),
          ),
        ],
        child: _TestApp(child: ProxiesTabView(key: key)),
      ),
    );
    await tester.pump();

    expect(key.currentState?.currentGroup?.name, 'B');

    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    tabBar.controller?.animateTo(1);
    await tester.pumpAndSettle();

    expect(key.currentState?.currentGroup?.name, 'C');
    expect(globalContainer.read(currentProfileProvider)?.currentGroupName, 'C');
  });

  testWidgets('long pressing a tab resets its proxy selection', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          proxiesTabStateProvider.overrideWithValue(
            ProxiesTabState(
              groups: [_group('A'), _group('B')],
              currentGroupName: 'B',
              proxyCardType: ProxyCardType.standard,
            ),
          ),
        ],
        child: const _TestApp(child: ProxiesTabView()),
      ),
    );
    await tester.pump();

    await tester.longPress(find.byKey(const ValueKey('proxy-group-tab-B')));
    await _pumpUntilSelectionReset(tester, globalContainer, 'B');

    expect(globalContainer.read(currentProfileProvider)?.selectedMap['B'], '');

    verify(
      () => coreHandler.changeProxy(
        const ChangeProxyParams(groupName: 'B', proxyName: ''),
        closeConnections: false,
      ),
    ).called(1);
    expect(
      find.text('Close connections using the previous proxy?'),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Close'));
    await tester.pump();

    verify(
      () => coreHandler.changeProxy(
        const ChangeProxyParams(groupName: 'B', proxyName: ''),
        closeConnections: true,
      ),
    ).called(1);
    verifyNever(() => coreHandler.closeConnections());
    verify(() => coreHandler.getProxies()).called(1);
  });

  testWidgets('long pressing a list header resets its proxy selection', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          proxiesListStateProvider.overrideWithValue(
            ProxiesListState(
              groups: [_group('A')],
              currentUnfoldSet: {},
              proxyCardType: ProxyCardType.standard,
            ),
          ),
          currentProfileProvider.overrideWithValue(
            globalContainer.read(currentProfileProvider),
          ),
        ],
        child: const _TestApp(child: ProxiesListView()),
      ),
    );
    await tester.pump();

    await tester.longPress(find.byKey(const Key('A')).first);
    await _pumpUntilSelectionReset(tester, globalContainer, 'A');

    expect(globalContainer.read(currentProfileProvider)?.selectedMap['A'], '');

    verify(
      () => coreHandler.changeProxy(
        const ChangeProxyParams(groupName: 'A', proxyName: ''),
        closeConnections: false,
      ),
    ).called(1);
    expect(
      find.text('Close connections using the previous proxy?'),
      findsOneWidget,
    );
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).persist, false);
    verifyNever(
      () => coreHandler.changeProxy(
        const ChangeProxyParams(groupName: 'A', proxyName: ''),
        closeConnections: true,
      ),
    );
    verifyNever(() => coreHandler.closeConnections());
    verify(() => coreHandler.getProxies()).called(1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('disabled connection prompt does not show a snackbar', (
    tester,
  ) async {
    final appSettingSubscription = globalContainer.listen(
      appSettingProvider,
      (_, _) {},
    );
    addTearDown(appSettingSubscription.close);
    globalContainer
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(promptCloseConnections: false));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          proxiesListStateProvider.overrideWithValue(
            ProxiesListState(
              groups: [_group('A')],
              currentUnfoldSet: {},
              proxyCardType: ProxyCardType.standard,
            ),
          ),
          currentProfileProvider.overrideWithValue(
            globalContainer.read(currentProfileProvider),
          ),
        ],
        child: const _TestApp(child: ProxiesListView()),
      ),
    );
    await tester.pump();

    await tester.longPress(find.byKey(const Key('A')).first);
    await _pumpUntilSelectionReset(tester, globalContainer, 'A');

    verify(
      () => coreHandler.changeProxy(
        const ChangeProxyParams(groupName: 'A', proxyName: ''),
        closeConnections: false,
      ),
    ).called(1);
    expect(
      find.text('Close connections using the previous proxy?'),
      findsNothing,
    );
    verifyNever(
      () => coreHandler.changeProxy(
        const ChangeProxyParams(groupName: 'A', proxyName: ''),
        closeConnections: true,
      ),
    );
  });

  testWidgets('selecting the current proxy does not show a close prompt', (
    tester,
  ) async {
    globalContainer.read(groupsProvider.notifier).value = [
      const Group(type: GroupType.Selector, name: 'A', now: 'Node A'),
    ];

    await tester.pumpWidget(const _TestApp(child: SizedBox()));
    await tester.pump();

    await globalContainer
        .read(proxiesActionProvider.notifier)
        .changeProxy(groupName: 'A', proxyName: 'Node A');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    verify(
      () => coreHandler.changeProxy(
        const ChangeProxyParams(groupName: 'A', proxyName: 'Node A'),
        closeConnections: false,
      ),
    ).called(1);
    expect(
      find.text('Close connections using the previous proxy?'),
      findsNothing,
    );
  });

  testWidgets('list delay test deduplicates nodes shared by expanded groups', (
    tester,
  ) async {
    const testUrl = 'https://example.com/generate_204';
    const proxy = Proxy(name: 'Node A', type: 'Shadowsocks');
    const groups = [
      Group(
        type: GroupType.Selector,
        name: 'A',
        all: [proxy],
        testUrl: testUrl,
      ),
      Group(
        type: GroupType.Selector,
        name: 'B',
        all: [proxy],
        testUrl: testUrl,
      ),
    ];
    final profile = Profile.normal().copyWith(unfoldSet: {'A', 'B'});
    final response = Completer<Delay>();
    when(
      () => coreHandler.asyncTestDelay(testUrl, proxy.name),
    ).thenAnswer((_) => response.future);
    currentProfileSubscription.close();
    globalContainer.dispose();
    globalContainer = ProviderContainer(
      overrides: [
        currentProfileProvider.overrideWithValue(profile),
        groupsProvider.overrideWithBuild((_, _) => groups),
        proxiesListStateProvider.overrideWithValue(
          const ProxiesListState(
            groups: groups,
            currentUnfoldSet: {'A', 'B'},
            proxyCardType: ProxyCardType.standard,
          ),
        ),
      ],
    );
    globalState.container = globalContainer;
    currentProfileSubscription = globalContainer.listen(
      currentProfileProvider,
      (_, _) {},
    );
    final key = GlobalKey<ProxiesListViewState>();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: globalContainer,
        child: _TestApp(child: ProxiesListView(key: key)),
      ),
    );
    await tester.pump();

    final delayTestFuture = key.currentState!.delayTestUnfoldedGroups();
    response.complete(const Delay(url: testUrl, name: 'Node A', value: 42));
    await delayTestFuture;

    verify(() => coreHandler.asyncTestDelay(testUrl, proxy.name)).called(1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

Future<void> _pumpUntilSelectionReset(
  WidgetTester tester,
  ProviderContainer container,
  String groupName,
) async {
  for (var i = 0; i < 100; i++) {
    if (container.read(currentProfileProvider)?.selectedMap[groupName] == '') {
      return;
    }
    await tester.pump(const Duration(milliseconds: 10));
  }
}

ProxiesData _proxiesData() {
  return ProxiesData(
    all: ['A', 'B', 'Node A', 'Node B'],
    proxies: Map<String, dynamic>.from({
      'A': {
        'name': 'A',
        'type': 'Selector',
        'all': ['Node A'],
        'now': 'Node A',
      },
      'B': {
        'name': 'B',
        'type': 'Selector',
        'all': ['Node B'],
        'now': 'Node B',
      },
      'Node A': {'name': 'Node A', 'type': 'Shadowsocks'},
      'Node B': {'name': 'Node B', 'type': 'Shadowsocks'},
    }),
  );
}

Group _group(String name) {
  return Group(type: GroupType.Selector, name: name);
}

class _TestProfiles extends Profiles {
  final List<Profile> initial;

  _TestProfiles(this.initial);

  @override
  List<Profile> build() => initial;

  @override
  void put(Profile profile) {
    final next = List<Profile>.from(state);
    final index = next.indexWhere((item) => item.id == profile.id);
    if (index == -1) {
      next.add(profile);
    } else {
      next[index] = profile;
    }
    state = next;
  }
}

class _TestApp extends StatelessWidget {
  final Widget child;

  const _TestApp({required this.child});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: globalState.navigatorKey,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.delegate.supportedLocales,
      builder: (context, child) {
        globalState.measure = Measure.of(context, 1);
        globalState.theme = CommonTheme.of(context, 1);
        return child!;
      },
      home: Scaffold(body: child),
    );
  }
}

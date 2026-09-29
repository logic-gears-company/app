import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/axis_auth_service.dart';
import 'package:Kelivo/core/services/axis_cloud_service.dart';
import 'package:Kelivo/features/settings/pages/axis_cloud_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/business_test_harness.dart';

class _FakeAuth extends AxisAuthService {
  _FakeAuth({this.session = true});

  final bool session;
  bool loggedOut = false;

  @override
  Future<bool> hasSession() async => session;

  @override
  Future<void> logout() async => loggedOut = true;
}

class _FakeCloud extends AxisCloudService {
  _FakeCloud(super.auth, {this.entries = const [], this.failWith});

  final List<AxisCloudEntry> entries;
  final Object? failWith;
  final List<String> listedPaths = [];
  final List<String> deletedPaths = [];

  @override
  Future<List<AxisCloudEntry>> list([String path = '']) async {
    listedPaths.add(path);
    if (failWith != null) throw failWith!;
    return entries;
  }

  @override
  Future<http.Response> delete(String path) async {
    deletedPaths.add(path);
    return http.Response('', 204);
  }
}

const _folder = AxisCloudEntry(
  name: 'notas',
  path: '/notas',
  isDirectory: true,
);

const _file = AxisCloudEntry(
  name: 'hola.txt',
  path: '/hola.txt',
  isDirectory: false,
  size: 12,
);

/// IosNavRow resolves SettingsProvider for press feedback, so the page needs it
/// even though it never reads settings itself.
Future<SettingsProvider> _createSettings() async {
  SharedPreferences.setMockInitialValues({});
  final harness = await createBusinessTestHarness();
  final settings = SettingsProvider(harness.preferences);
  await settings.loaded;
  return settings;
}

Future<void> _pumpPage(
  WidgetTester tester,
  AxisAuthService auth,
  AxisCloudService cloud,
) async {
  final settings = await _createSettings();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        Provider<AxisAuthService>.value(value: auth),
        Provider<AxisCloudService>.value(value: cloud),
      ],
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AxisCloudPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists the remote files', (tester) async {
    final cloud = _FakeCloud(_FakeAuth(), entries: [_folder, _file]);
    await _pumpPage(tester, _FakeAuth(), cloud);

    expect(find.text('notas'), findsOneWidget);
    expect(find.text('hola.txt'), findsOneWidget);
    expect(cloud.listedPaths, ['']);
  });

  testWidgets('says so when the account has no files', (tester) async {
    final cloud = _FakeCloud(_FakeAuth());
    await _pumpPage(tester, _FakeAuth(), cloud);

    expect(find.text('No files yet in this folder'), findsOneWidget);
  });

  testWidgets('descends into a folder and comes back up', (tester) async {
    final cloud = _FakeCloud(_FakeAuth(), entries: [_folder]);
    await _pumpPage(tester, _FakeAuth(), cloud);

    await tester.tap(find.text('notas'));
    await tester.pumpAndSettle();
    expect(cloud.listedPaths, ['', '/notas']);

    await tester.tap(find.byTooltip('Up one level'));
    await tester.pumpAndSettle();
    expect(cloud.listedPaths, ['', '/notas', '']);
  });

  testWidgets('deletes a file after confirming', (tester) async {
    final cloud = _FakeCloud(_FakeAuth(), entries: [_file]);
    await _pumpPage(tester, _FakeAuth(), cloud);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete from AXIS Cloud?'), findsOneWidget);

    // Cancelling must not touch the cloud.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cloud.deletedPaths, isEmpty);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(cloud.deletedPaths, ['/hola.txt']);
  });

  testWidgets('surfaces a failure with a retry that re-lists', (tester) async {
    final cloud = _FakeCloud(_FakeAuth(), failWith: 'connection refused');
    await _pumpPage(tester, _FakeAuth(), cloud);

    expect(find.text('connection refused'), findsOneWidget);
    expect(cloud.listedPaths, ['']);

    // Retrying re-issues the listing; the fake still fails, so the error stays.
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(cloud.listedPaths, ['', '']);
  });

  testWidgets('shows the signed-in endpoint and offers sign out', (
    tester,
  ) async {
    final auth = _FakeAuth();
    final cloud = _FakeCloud(auth);
    await _pumpPage(tester, auth, cloud);

    expect(find.text(AxisAuthService.baseUrl), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(auth.loggedOut, isTrue);
  });

  testWidgets('prompts to sign in when there is no session', (tester) async {
    final auth = _FakeAuth(session: false);
    final cloud = _FakeCloud(auth);
    await _pumpPage(tester, auth, cloud);

    expect(find.text('Sign in to AXIS to use AXIS Cloud'), findsOneWidget);
    expect(find.text('Sign out'), findsNothing);
  });
}

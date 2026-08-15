import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCurrentUserNotifier extends CurrentUserNotifier {
  _FakeCurrentUserNotifier(this._user);

  final User _user;

  @override
  Future<User?> build() async => _user;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('combines local blocked names with Discourse ignored names', () async {
    SharedPreferences.setMockInitialValues({
      'pref_blocked_usernames': ['local'],
    });
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentUserProvider.overrideWith(
          () => _FakeCurrentUserNotifier(
            User(
              id: 1,
              username: 'me',
              trustLevel: 2,
              ignoredUsernames: const ['IgnoredUser'],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(currentUserProvider.future);

    expect(container.read(effectiveBlockedUsernamesProvider), {
      'local',
      'ignoreduser',
    });

    final currentUser = container.read(currentUserProvider.notifier);
    currentUser.updateIgnoredUsername('NewUser', ignored: true);
    expect(
      container.read(effectiveBlockedUsernamesProvider),
      contains('newuser'),
    );

    currentUser.updateIgnoredUsername('NewUser', ignored: false);
    expect(
      container.read(effectiveBlockedUsernamesProvider),
      isNot(contains('newuser')),
    );
  });
}

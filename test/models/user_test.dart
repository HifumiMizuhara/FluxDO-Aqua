import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';

void main() {
  test('parses and caches the current user ignored usernames', () {
    final user = User.fromJson({
      'id': 1,
      'username': 'me',
      'trust_level': 2,
      'ignored_usernames': ['Alice', 'bob'],
    });

    expect(user.ignoredUsernames, ['Alice', 'bob']);
    expect(User.fromCacheJson(user.toCacheJson()).ignoredUsernames, [
      'Alice',
      'bob',
    ]);
  });
}

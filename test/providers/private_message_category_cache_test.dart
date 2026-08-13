import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/private_message_category_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

Topic _topic(int id) => Topic(
  id: id,
  title: 'Message $id',
  slug: 'message-$id',
  postsCount: 1,
  replyCount: 0,
  views: 0,
  likeCount: 0,
  categoryId: '0',
  participants: [
    TopicPoster(
      userId: 10,
      description: '',
      extras: '',
      user: TopicUser(id: 10, username: 'alice', avatarTemplate: ''),
    ),
  ],
  lastPostedAt: DateTime(2026, 8, 13, 10),
);

void main() {
  test('分類スナップショットをアカウントとタブ単位で保存・復元する', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cache = PrivateMessageCategoryCache(prefs);

    await cache.write(username: 'alice', filter: 'inbox', topics: [_topic(1)]);

    final restored = cache.read(username: 'alice', filter: 'inbox');
    expect(restored, hasLength(1));
    expect(restored!.single.id, 1);
    expect(restored.single.participants.single.user?.username, 'alice');
    expect(cache.read(username: 'alice', filter: 'sent'), isNull);
    expect(cache.read(username: 'bob', filter: 'inbox'), isNull);
  });

  test('壊れたキャッシュは無視する', () async {
    SharedPreferences.setMockInitialValues({
      'private_message_category_snapshot_v4_https://linux.do_alice_inbox':
          '{broken',
    });
    final prefs = await SharedPreferences.getInstance();
    final cache = PrivateMessageCategoryCache(prefs);

    expect(cache.read(username: 'alice', filter: 'inbox'), isNull);
  });
}

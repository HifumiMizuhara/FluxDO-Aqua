import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/private_message_category.dart';
import 'package:fluxdo/models/topic.dart';

TopicUser _user(int id, String username) => TopicUser(
  id: id,
  username: username,
  avatarTemplate: '/user/$username/{size}.png',
);

Topic _topic(
  int id, {
  List<TopicPoster> participants = const [],
  DateTime? lastPostedAt,
  bool hasParticipantGroups = false,
}) {
  return Topic(
    id: id,
    title: 'Message $id',
    slug: 'message-$id',
    postsCount: 1,
    replyCount: 0,
    views: 0,
    likeCount: 0,
    categoryId: '0',
    participants: participants,
    hasParticipantGroups: hasParticipantGroups,
    lastPostedAt: lastPostedAt,
  );
}

TopicPoster _participant(TopicUser user) =>
    TopicPoster(userId: user.id, description: '', extras: '', user: user);

void main() {
  test('同じ相手の私信をユーザーID単位でまとめる', () {
    final alice = _user(10, 'alice');

    final categories = groupPrivateMessages([
      _topic(1, participants: [_participant(alice)]),
      _topic(2, participants: [_participant(alice)]),
    ]);

    expect(categories, hasLength(1));
    expect(categories.single.peer?.username, 'alice');
    expect(categories.single.topics.map((topic) => topic.id), [1, 2]);
  });

  test('複数相手の私信をグループチャットにまとめる', () {
    final categories = groupPrivateMessages([
      _topic(
        1,
        participants: [
          _participant(_user(10, 'alice')),
          _participant(_user(11, 'bob')),
        ],
      ),
      _topic(
        2,
        participants: [_participant(_user(12, 'carol'))],
        hasParticipantGroups: true,
      ),
    ]);

    expect(categories, hasLength(1));
    expect(categories.single.isGroupChat, isTrue);
    expect(categories.single.topics.map((topic) => topic.id), [1, 2]);
  });

  test('カテゴリは最新メッセージ順になる', () {
    final categories = groupPrivateMessages([
      _topic(
        1,
        participants: [_participant(_user(10, 'alice'))],
        lastPostedAt: DateTime.utc(2026, 1, 1),
      ),
      _topic(
        2,
        participants: [_participant(_user(11, 'bob'))],
        lastPostedAt: DateTime.utc(2026, 2, 1),
      ),
    ]);

    expect(categories.map((category) => category.peer?.username), [
      'bob',
      'alice',
    ]);
  });

  test('相手情報が欠落した私信はトピック単位のフォールバックになる', () {
    final categories = groupPrivateMessages([
      _topic(
        1,
        participants: [TopicPoster(userId: 10, description: '', extras: '')],
      ),
      _topic(
        2,
        participants: [TopicPoster(userId: 10, description: '', extras: '')],
      ),
    ]);

    expect(categories, hasLength(2));
    expect(categories.every((category) => category.peer == null), isTrue);
  });
}

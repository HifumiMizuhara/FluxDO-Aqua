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

  test('同じ参加者集合のグループチャットをまとめる', () {
    final alice = _user(10, 'alice');
    final bob = _user(11, 'bob');
    final categories = groupPrivateMessages([
      _topic(1, participants: [_participant(alice), _participant(bob)]),
      _topic(2, participants: [_participant(bob), _participant(alice)]),
    ]);

    expect(categories, hasLength(1));
    expect(categories.single.isGroupChat, isTrue);
    expect(categories.single.topics.map((topic) => topic.id), [1, 2]);
  });

  test('異なる参加者集合のグループチャットも一つにまとめる', () {
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
        participants: [
          _participant(_user(10, 'alice')),
          _participant(_user(12, 'carol')),
        ],
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

  test('未解決の参加者を含む私信はsystemカテゴリになる', () {
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

    expect(categories, hasLength(1));
    expect(categories.single.isSystemMessage, isTrue);
    expect(categories.single.topics.map((topic) => topic.id), [1, 2]);
  });

  test('参加者のない私信はsystemカテゴリにまとめる', () {
    final categories = groupPrivateMessages([_topic(1), _topic(2)]);

    expect(categories, hasLength(1));
    expect(categories.single.isSystemMessage, isTrue);
    expect(categories.single.topics.map((topic) => topic.id), [1, 2]);
  });

  test('Discourseの非人間ユーザー指定はsystemカテゴリになる', () {
    final categories = groupPrivateMessages([
      Topic(
        id: 1,
        title: 'Message 1',
        slug: 'message-1',
        postsCount: 1,
        replyCount: 0,
        views: 0,
        likeCount: 0,
        categoryId: '0',
        isSystemMessage: true,
        participants: [TopicPoster(userId: 10, description: '', extras: '')],
      ),
    ]);

    expect(categories.single.isSystemMessage, isTrue);
  });

  test('通報結果PMのis_warningは参加者数より優先してsystemになる', () {
    final topic = Topic.fromJson(
      {
        'id': 1,
        'title': '',
        'slug': 'message-1',
        'posts_count': 1,
        'participants': [
          {'user_id': 10},
          {'user_id': 11},
        ],
        'is_warning': true,
      },
      userMap: {10: _user(10, 'alice'), 11: _user(11, 'bob')},
    );

    final categories = groupPrivateMessages([topic]);

    expect(categories, hasLength(1));
    expect(categories.single.isSystemMessage, isTrue);
  });

  test('通報結果PMのsubtypeはsystemになる', () {
    final topic = Topic.fromJson(
      {
        'id': 1,
        'title': '',
        'slug': 'message-1',
        'posts_count': 1,
        'participants': [
          {'user_id': 10},
          {'user_id': 11},
        ],
        'subtype': 'notify_moderators',
      },
      userMap: {10: _user(10, 'alice'), 11: _user(11, 'bob')},
    );

    final categories = groupPrivateMessages([topic]);

    expect(categories.single.isSystemMessage, isTrue);
  });

  test('通報結果PMの抜粋もsystemとして認識する', () {
    final topic = Topic.fromJson(
      {
        'id': 1,
        'title': '',
        'slug': 'message-1',
        'posts_count': 1,
        'participants': [
          {'user_id': 10},
          {'user_id': 11},
        ],
        'excerpt': '这个帖子需要管理员注意',
      },
      userMap: {10: _user(10, 'alice'), 11: _user(11, 'bob')},
    );

    final categories = groupPrivateMessages([topic]);

    expect(categories.single.isSystemMessage, isTrue);
  });

  test('通報結果PMはhas_participant_groupsがtrueでもsystemになる', () {
    final topic = Topic.fromJson({
      'id': 2722590,
      'title': '“出两个京东E卡10元，自动发卡，明盘1128LDC”中的一个帖子需要管理人员注意',
      'slug': 'topic',
      'posts_count': 1,
      'participants': const [],
      'participant_groups': const [],
      'has_participant_groups': true,
      'pm_with_non_human_user': false,
    });

    final categories = groupPrivateMessages([topic]);

    expect(categories, hasLength(1));
    expect(categories.single.isSystemMessage, isTrue);
  });

  test('system判定は参加者数より優先される', () {
    final categories = groupPrivateMessages([
      Topic(
        id: 1,
        title: 'Message 1',
        slug: 'message-1',
        postsCount: 1,
        replyCount: 0,
        views: 0,
        likeCount: 0,
        categoryId: '0',
        isSystemMessage: true,
        participants: [
          _participant(_user(10, 'alice')),
          _participant(_user(11, 'bob')),
        ],
      ),
    ]);

    expect(categories.single.isSystemMessage, isTrue);
  });

  test('未解決の参加者を含む複数参加者PMはグループチャットにしない', () {
    final categories = groupPrivateMessages([
      Topic(
        id: 1,
        title: 'Message 1',
        slug: 'message-1',
        postsCount: 1,
        replyCount: 0,
        views: 0,
        likeCount: 0,
        categoryId: '0',
        participants: [
          TopicPoster(userId: 1, description: '', extras: ''),
          _participant(_user(11, 'alice')),
        ],
      ),
    ]);

    expect(categories, hasLength(1));
    expect(categories.single.isSystemMessage, isTrue);
  });

  test('人間の相手を解決できないPMはDMフォールバックを作らずsystemにまとめる', () {
    final categories = groupPrivateMessages([
      Topic(
        id: 1,
        title: 'Message 1',
        slug: 'message-1',
        postsCount: 1,
        replyCount: 0,
        views: 0,
        likeCount: 0,
        categoryId: '0',
        participants: [
          TopicPoster(userId: 10, description: '', extras: ''),
          TopicPoster(userId: 11, description: '', extras: ''),
        ],
      ),
      Topic(
        id: 2,
        title: 'Message 2',
        slug: 'message-2',
        postsCount: 1,
        replyCount: 0,
        views: 0,
        likeCount: 0,
        categoryId: '0',
        participants: const [],
      ),
    ]);

    expect(categories, hasLength(1));
    expect(categories.single.isSystemMessage, isTrue);
    expect(categories.single.topics.map((topic) => topic.id), [1, 2]);
  });
}

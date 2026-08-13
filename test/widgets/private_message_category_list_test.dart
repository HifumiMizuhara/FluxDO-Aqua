import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/widgets/private_message_category_list.dart';

TopicUser _alice() => TopicUser(id: 10, username: 'alice', avatarTemplate: '');

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
    TopicPoster(userId: 10, description: '', extras: '', user: _alice()),
  ],
);

void main() {
  testWidgets('私信カテゴリのもっと見る・折りたたみ・見出し折りたたみ', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('ja'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: PrivateMessageCategoryList(
              topics: [_topic(1), _topic(2), _topic(3), _topic(4)],
              controller: controller,
              selectedTopicId: null,
              enableLongPress: false,
              onTopicTap: (_) {},
              footer: const SizedBox.shrink(),
              topicBuilder: (context, topic) => SizedBox(
                key: ValueKey('topic_${topic.id}'),
                height: 48,
                child: Text(topic.title),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final topicFinder = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey &&
          (widget.key! as ValueKey).value.toString().startsWith('topic_'),
    );

    expect(topicFinder, findsNWidgets(3));
    expect(find.byType(TextButton), findsOneWidget);

    await tester.tap(find.byType(TextButton));
    await tester.pump();
    expect(topicFinder, findsNWidgets(4));
    expect(find.byType(TextButton), findsOneWidget);

    await tester.tap(find.byType(TextButton));
    await tester.pump();
    expect(topicFinder, findsNWidgets(3));

    await tester.tap(find.text('alice'));
    await tester.pump();
    expect(topicFinder, findsNothing);
  });
}

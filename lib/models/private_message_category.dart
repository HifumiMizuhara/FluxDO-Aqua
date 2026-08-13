import 'topic.dart';

/// Category key used for all group private messages.
const privateMessageGroupCategoryKey = 'group-chat';

/// Category key used for system-generated private messages.
const privateMessageSystemCategoryKey = 'system';

/// A display category for the private-message topic list.
///
/// The grouping model deliberately depends only on [Topic] data, so it can be
/// tested without building the private-message page. An unresolved participant
/// is treated as a system recipient, while a normal one-to-one topic with a
/// resolved participant is grouped by that user's ID.
class PrivateMessageCategory {
  final String key;
  final TopicUser? peer;
  final List<Topic> topics;

  const PrivateMessageCategory({
    required this.key,
    required this.peer,
    required this.topics,
  });

  bool get isGroupChat => key == privateMessageGroupCategoryKey;

  bool get isSystemMessage => key == privateMessageSystemCategoryKey;

  DateTime? get latestMessageAt {
    for (final topic in topics) {
      if (topic.lastPostedAt != null) return topic.lastPostedAt;
    }
    return null;
  }
}

/// Groups private-message topics by recipient and sorts categories by their
/// newest message. Topic order inside each category remains the API order.
///
/// Discourse's `participants` summary excludes the current user. One
/// participant is therefore a one-to-one message; two or more participants,
/// or a participant group, is a group message. Missing participant details
/// are kept at topic granularity to avoid accidental cross-user merges,
/// except for the server's system-message shape, which has no human
/// participant and belongs to the system category.
List<PrivateMessageCategory> groupPrivateMessages(Iterable<Topic> topics) {
  final grouped = <String, List<Topic>>{};
  final peers = <String, TopicUser?>{};

  for (final topic in topics) {
    final participants = topic.participants;
    final isGroup = topic.hasParticipantGroups || participants.length >= 2;
    final isSystem = _isSystemTopic(topic);

    late final String key;
    TopicUser? peer;
    if (isSystem) {
      key = privateMessageSystemCategoryKey;
    } else if (isGroup) {
      key = privateMessageGroupCategoryKey;
    } else if (participants.length == 1 && participants.single.user != null) {
      final participant = participants.single.user!;
      peer = participant;
      key = 'user:${participant.id}';
    } else {
      // There is no safe human recipient to display. Do not create a
      // topic-specific fallback such as "DM #...": these are system-style
      // entries from the user's perspective and must be consolidated.
      key = privateMessageSystemCategoryKey;
    }

    grouped.putIfAbsent(key, () => <Topic>[]).add(topic);
    peers[key] = peer;
  }

  final categories = grouped.entries
      .map(
        (entry) => PrivateMessageCategory(
          key: entry.key,
          peer: peers[entry.key],
          topics: List.unmodifiable(entry.value),
        ),
      )
      .toList();

  categories.sort((a, b) {
    final aDate = a.latestMessageAt;
    final bDate = b.latestMessageAt;
    if (aDate == null && bDate == null) return 0;
    if (aDate == null) return 1;
    if (bDate == null) return -1;
    return bDate.compareTo(aDate);
  });
  return categories;
}

bool _isSystemParticipant(TopicPoster participant) {
  final username = participant.user?.username.trim().toLowerCase();
  // The system user is not always included in the response's top-level
  // `users` array. In that shape the participant has a valid-looking ID but
  // no resolved TopicUser, which used to make the topic look like a group
  // chat when another participant was present.
  return participant.user == null ||
      participant.userId <= 0 ||
      username == 'system';
}

bool _isSystemTopic(Topic topic) {
  if (topic.isSystemMessage) return true;

  // A group recipient is authoritative. Do not infer a system topic from
  // missing user hydration in a group-recipient response.
  if (topic.hasParticipantGroups) return false;

  final participants = topic.participants;
  return participants.isEmpty ||
      participants.any(_isSystemParticipant) ||
      topic.lastPosterUsername?.trim().toLowerCase() == 'system';
}

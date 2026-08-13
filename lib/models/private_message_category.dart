import 'topic.dart';

/// Category key used for all multi-recipient private messages.
const privateMessageGroupCategoryKey = 'group-chat';

/// A display category for the private-message topic list.
///
/// The grouping model deliberately depends only on [Topic] data, so it can be
/// tested without building the private-message page. A topic whose recipient
/// data is incomplete gets a topic-specific fallback key and can never merge
/// with another unknown topic.
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
/// are kept at topic granularity to avoid accidental cross-user merges.
List<PrivateMessageCategory> groupPrivateMessages(Iterable<Topic> topics) {
  final grouped = <String, List<Topic>>{};
  final peers = <String, TopicUser?>{};

  for (final topic in topics) {
    final participants = topic.participants;
    final isGroup = topic.hasParticipantGroups || participants.length >= 2;

    late final String key;
    TopicUser? peer;
    if (isGroup) {
      key = privateMessageGroupCategoryKey;
    } else if (participants.length == 1 && participants.single.user != null) {
      final participant = participants.single.user!;
      peer = participant;
      key = 'user:${participant.id}';
    } else {
      // Do not use an empty/unknown participant key: two incomplete topics
      // must remain separate until the server provides participant data.
      key = 'topic:${topic.id}';
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

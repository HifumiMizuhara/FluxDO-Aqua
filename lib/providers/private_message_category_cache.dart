import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/topic.dart';

/// Persistent snapshot used by categorized private-message lists.
///
/// The snapshot is deliberately independent from the normal PM pagination
/// state. A categorized list needs a complete conversation index before it
/// can present stable sections, while the regular list can remain paged.
class PrivateMessageCategoryCache {
  static const _version = 4;
  static const _keyPrefix = 'private_message_category_snapshot_v4';

  final SharedPreferences _prefs;

  const PrivateMessageCategoryCache(this._prefs);

  List<Topic>? read({required String username, required String filter}) {
    final raw = _prefs.getString(_key(username, filter));
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != _version ||
          decoded['topics'] is! List<dynamic>) {
        return null;
      }

      final topics = <Topic>[];
      for (final item in decoded['topics'] as List<dynamic>) {
        if (item is! Map) continue;
        try {
          topics.add(Topic.fromJson(Map<String, dynamic>.from(item)));
        } catch (_) {
          // A single malformed cache entry must not hide the usable entries.
        }
      }
      return List.unmodifiable(topics);
    } catch (_) {
      return null;
    }
  }

  Future<void> write({
    required String username,
    required String filter,
    required Iterable<Topic> topics,
  }) async {
    final payload = {
      'version': _version,
      'topics': topics.map(_topicToJson).toList(growable: false),
    };
    await _prefs.setString(_key(username, filter), jsonEncode(payload));
  }

  String _key(String username, String filter) {
    return '${_keyPrefix}_${AppConstants.baseUrl}_${username}_$filter';
  }
}

Map<String, dynamic> _topicToJson(Topic topic) {
  return {
    'id': topic.id,
    'title': topic.title,
    'slug': topic.slug,
    'posts_count': topic.postsCount,
    'reply_count': topic.replyCount,
    'views': topic.views,
    'like_count': topic.likeCount,
    'excerpt': topic.excerpt,
    'created_at': topic.createdAt?.toUtc().toIso8601String(),
    'last_posted_at': topic.lastPostedAt?.toUtc().toIso8601String(),
    'last_poster_username': topic.lastPosterUsername,
    'category_id': topic.categoryId,
    'pinned': topic.pinned,
    'visible': topic.visible,
    'closed': topic.closed,
    'archived': topic.archived,
    'tags': topic.tags
        .map((tag) => {'id': tag.id, 'name': tag.name, 'slug': tag.slug})
        .toList(growable: false),
    'posters': topic.posters.map(_posterToJson).toList(growable: false),
    'participants': topic.participants
        .map(_posterToJson)
        .toList(growable: false),
    'participant_groups': topic.participantGroupIds
        .map((id) => {'id': id})
        .toList(growable: false),
    'has_participant_groups': topic.hasParticipantGroups,
    'pm_with_non_human_user': topic.isSystemMessage,
    'unseen': topic.unseen,
    'unread_posts': topic.unread,
    'new_posts': topic.newPosts,
    'last_read_post_number': topic.lastReadPostNumber,
    'highest_post_number': topic.highestPostNumber,
  };
}

Map<String, dynamic> _posterToJson(TopicPoster poster) {
  return {
    'user_id': poster.userId,
    'description': poster.description,
    'extras': poster.extras,
    '_username': poster.user?.username,
    '_name': poster.user?.name,
    '_avatar_template': poster.user?.avatarTemplate,
    '_animated_avatar': poster.user?.animatedAvatar,
  };
}

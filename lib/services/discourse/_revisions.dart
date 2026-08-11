part of 'discourse_service.dart';

/// 帖子编辑历史相关 API。对齐 `posts_controller.rb` 中的 revisions 系列 action。
///
/// API 路径（来自 `config/routes.rb`）：
/// - `GET    /posts/:post_id/revisions/latest.json`
/// - `GET    /posts/:post_id/revisions/:revision.json`
/// - `PUT    /posts/:post_id/revisions/:revision/hide`
/// - `PUT    /posts/:post_id/revisions/:revision/show`
/// - `PUT    /posts/:post_id/revisions/:revision/revert`
/// - `DELETE /posts/:post_id/revisions/permanently_delete`
mixin _RevisionsMixin on _DiscourseServiceBase {
  /// 获取指定版本的编辑历史（含 diff、元变化、导航字段）。
  Future<PostRevision> getPostRevision(int postId, int revision) async {
    try {
      final response = await _dio.get(
        '/posts/$postId/revisions/$revision.json',
      );
      return PostRevision.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取最新版本的编辑历史（路径常量 `latest`）。
  Future<PostRevision> getLatestPostRevision(int postId) async {
    try {
      final response = await _dio.get('/posts/$postId/revisions/latest.json');
      return PostRevision.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 隐藏指定版本（staff 操作）。
  Future<void> hidePostRevision(int postId, int revision) async {
    try {
      await _dio.put('/posts/$postId/revisions/$revision/hide');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 显示先前隐藏的版本（staff 操作）。
  Future<void> showPostRevision(int postId, int revision) async {
    try {
      await _dio.put('/posts/$postId/revisions/$revision/show');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 回退到指定版本（staff 操作）。
  ///
  /// 服务端不会覆盖历史，而是把目标版本的差异字段当作一次新编辑写入，
  /// 因此返回的 [Post] 携带递增后的 `version` 与新 `edit_reason`。
  Future<Post> revertPostToRevision(int postId, int revision) async {
    try {
      final response = await _dio.put(
        '/posts/$postId/revisions/$revision/revert',
      );
      final data = response.data;
      if (data is Map && data['post'] != null) {
        return Post.fromJson(data['post'] as Map<String, dynamic>);
      }
      if (data is Map && data['id'] != null) {
        return Post.fromJson(data as Map<String, dynamic>);
      }
      throw Exception(S.current.error_unknownResponseFormat);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 永久删除该帖子的全部编辑历史（staff 操作 + 站点设置开启）。
  Future<void> permanentlyDeletePostRevisions(int postId) async {
    try {
      await _dio.delete('/posts/$postId/revisions/permanently_delete');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }
}

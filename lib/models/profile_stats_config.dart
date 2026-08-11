import 'dart:convert';

/// 统计项类型
enum ProfileStatType {
  // Summary API 字段
  daysVisited,
  postsReadCount,
  likesReceived,
  likesGiven,
  topicCount,
  postCount,
  timeRead,
  recentTimeRead,
  bookmarkCount,
  topicsEntered,
  // connect.linux.do 独有字段
  topicsRepliedTo,
  likesReceivedDays,
  likesReceivedUsers,
}

/// 布局模式
enum StatsLayoutMode { grid, scroll }

/// 数据源
enum StatsDataSource {
  summary, // 全量（Summary API）
  connect, // 信任等级周期（connect.linux.do）
}

/// 各数据源支持的统计项
const Map<StatsDataSource, Set<ProfileStatType>> supportedStatsPerSource = {
  StatsDataSource.summary: {
    ProfileStatType.daysVisited,
    ProfileStatType.postsReadCount,
    ProfileStatType.likesReceived,
    ProfileStatType.likesGiven,
    ProfileStatType.topicCount,
    ProfileStatType.postCount,
    ProfileStatType.timeRead,
    ProfileStatType.recentTimeRead,
    ProfileStatType.bookmarkCount,
    ProfileStatType.topicsEntered,
  },
  StatsDataSource.connect: {
    ProfileStatType.daysVisited,
    ProfileStatType.postsReadCount,
    ProfileStatType.likesReceived,
    ProfileStatType.likesGiven,
    ProfileStatType.topicsEntered,
    ProfileStatType.topicsRepliedTo,
    ProfileStatType.likesReceivedDays,
    ProfileStatType.likesReceivedUsers,
  },
};

/// 判断某统计项是否兼容指定数据源
bool isStatCompatible(ProfileStatType stat, StatsDataSource source) {
  return supportedStatsPerSource[source]?.contains(stat) ?? false;
}

/// 统计卡片配置
class ProfileStatsConfig {
  final List<ProfileStatType> enabledStats;
  final StatsLayoutMode layoutMode;
  final int columnsPerRow; // 网格模式 2/3/4
  final StatsDataSource dataSource;

  const ProfileStatsConfig({
    this.enabledStats = const [
      ProfileStatType.daysVisited,
      ProfileStatType.postsReadCount,
      ProfileStatType.likesReceived,
      ProfileStatType.postCount,
    ],
    this.layoutMode = StatsLayoutMode.grid,
    this.columnsPerRow = 4,
    this.dataSource = StatsDataSource.summary,
  });

  ProfileStatsConfig copyWith({
    List<ProfileStatType>? enabledStats,
    StatsLayoutMode? layoutMode,
    int? columnsPerRow,
    StatsDataSource? dataSource,
  }) {
    return ProfileStatsConfig(
      enabledStats: enabledStats ?? this.enabledStats,
      layoutMode: layoutMode ?? this.layoutMode,
      columnsPerRow: columnsPerRow ?? this.columnsPerRow,
      dataSource: dataSource ?? this.dataSource,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabledStats': enabledStats.map((e) => e.name).toList(),
    'layoutMode': layoutMode.name,
    'columnsPerRow': columnsPerRow,
    'dataSource': dataSource.name,
  };

  factory ProfileStatsConfig.fromJson(Map<String, dynamic> json) {
    return ProfileStatsConfig(
      enabledStats:
          (json['enabledStats'] as List<dynamic>?)
              ?.map(
                (e) => ProfileStatType.values.firstWhere(
                  (v) => v.name == e,
                  orElse: () => ProfileStatType.daysVisited,
                ),
              )
              .toList() ??
          const [
            ProfileStatType.daysVisited,
            ProfileStatType.postsReadCount,
            ProfileStatType.likesReceived,
            ProfileStatType.postCount,
          ],
      layoutMode: StatsLayoutMode.values.firstWhere(
        (v) => v.name == json['layoutMode'],
        orElse: () => StatsLayoutMode.grid,
      ),
      columnsPerRow: json['columnsPerRow'] as int? ?? 4,
      dataSource: StatsDataSource.values.firstWhere(
        (v) => v.name == json['dataSource'],
        orElse: () => StatsDataSource.summary,
      ),
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory ProfileStatsConfig.fromJsonString(String jsonStr) {
    return ProfileStatsConfig.fromJson(
      jsonDecode(jsonStr) as Map<String, dynamic>,
    );
  }
}

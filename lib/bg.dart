/// Workmanager 后台任务：每日自动整理 + 自动 CSV 备份
library;

import 'package:workmanager/workmanager.dart';
import 'csv_io.dart';
import 'db.dart';
import 'dict.dart';
import 'organize.dart';

const kWociDailyTask = 'wociDailyTask';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await DB.instance;
      await Dict.load();
      // 当天整理（幂等）；后台场景常在跨天后跑，强制对"今天"做一次
      await Organize.run(force: true);
      await CsvIo.autoBackup();
      return true;
    } catch (_) {
      return false;
    }
  });
}

/// 注册每日后台任务：对齐每天 22:00（首次延迟到下一个 22:00，此后每 24h）
Future<void> registerBackgroundTask() async {
  try {
    await Workmanager().initialize(callbackDispatcher);
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, 22, 0);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    await Workmanager().registerPeriodicTask(
      kWociDailyTask,
      kWociDailyTask,
      frequency: const Duration(hours: 24),
      initialDelay: next.difference(now),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.notRequired),
    );
  } catch (_) {
    // 注册失败不影响前台使用
  }
}

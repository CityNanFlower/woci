/// 每日复习提醒通知
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class Notify {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    try {
      tz.initializeTimeZones();
      // 中国时区固定偏移
      tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
      const androidInit =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(
          const InitializationSettings(android: androidInit));
      // Android 13+ 运行时通知权限
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      // 每天 19:30 提醒复习；22:00 提醒晚间整理（打开 App 即自动聚类）
      await scheduleDaily(19, 30);
      await scheduleDaily(22, 0,
          id: 2,
          title: '蜗词 · 晚间整理',
          body: '今天的新词该按词义聚类了，点开生成今日词单');
    } catch (_) {
      // 通知失败不阻塞应用
    }
  }

  static Future<void> scheduleDaily(int hour, int minute,
      {int id = 1, String title = '蜗词 · 复习时间到',
      String body = '今天的复习队列已就绪，花 20 分钟清空它吧！'}) async {
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        _nextInstance(hour, minute),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'daily_review',
            '每日复习提醒',
            channelDescription: '每天固定时间提醒复习生词',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexact,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {}
  }

  static tz.TZDateTime _nextInstance(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }
}

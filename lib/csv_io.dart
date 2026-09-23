/// CSV 导入导出：生词本备份 / 恢复
library;

import 'dart:io';
import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'db.dart';
import 'dict.dart';
import 'organize.dart';

class CsvIo {
  static const _headers = [
    'word', 'phonetic', 'translation', 'source', 'tags', 'note',
    'topic', 'sense_group', 'sense_note', 'example',
    'created_at', 'stage', 'due_date', 'lapses',
  ];

  /// 导出全量生词为 CSV 并拉起系统分享；返回导出数量
  static Future<int> exportWords() async {
    final words = await DB.allWords();
    final rows = [
      _headers,
      ...words.map((w) => [
            w.word, w.phonetic, w.translation, w.source, w.tags, w.note,
            w.topic, w.senseGroup, w.senseNote, w.example,
            w.createdAt, w.stage, w.dueDate, w.lapses,
          ]),
    ];
    final csv = const ListToCsvConverter().convert(rows);
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/woci_backup_${DB.today().replaceAll("-", "")}.csv');
    await file.writeAsString('\uFEFF$csv', encoding: utf8); // BOM 便于 Excel 打开
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'text/csv')],
      text: '蜗词生词本备份（${words.length} 词）',
    ));
    return words.length;
  }

  /// 导出结果：'no_file' / 'bad_format' / 'added:N'
  static Future<String> importWords() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'txt'],
      withData: true,
    );
    final path = picked?.files.single.path;
    if (path == null) return 'no_file';
    final raw = await File(path).readAsString();
    var text = raw.codeUnitAt(0) == 0xFEFF ? raw.substring(1) : raw;

    List<List<dynamic>> rows;
    try {
      rows = const CsvToListConverter(shouldParseNumbers: false).convert(text);
    } catch (_) {
      return 'bad_format';
    }
    if (rows.isEmpty) return 'bad_format';
    final header = rows.first.map((h) => h.toString().trim().toLowerCase()).toList();
    if (!header.contains('word')) return 'bad_format';
    final idx = <String, int>{};
    for (var i = 0; i < header.length; i++) {
      idx[header[i]] = i;
    }
    String cell(List r, String col) {
      final i = idx[col];
      if (i == null || i >= r.length) return '';
      final v = r[i];
      return v == null ? '' : v.toString().trim();
    }

    var added = 0;
    for (final r in rows.skip(1)) {
      final word = cell(r, 'word').toLowerCase();
      if (word.isEmpty || !RegExp(r"^[a-z][a-z\-']*$").hasMatch(word)) continue;
      final exists = await DB.wordExists(word);
      if (exists) continue;
      final dictItem = Dict.lookup(word);
      final translation = cell(r, 'translation').isNotEmpty
          ? cell(r, 'translation')
          : (dictItem?.translation ?? '');
      final phonetic = cell(r, 'phonetic').isNotEmpty
          ? cell(r, 'phonetic')
          : (dictItem?.phonetic ?? '');
      final source = kSourcePresets.contains(cell(r, 'source'))
          ? cell(r, 'source')
          : '';
      final topic = cell(r, 'topic').isNotEmpty ? cell(r, 'topic') : '';
      final createdAt = cell(r, 'created_at').isNotEmpty
          ? cell(r, 'created_at')
          : DB.today();
      final dueDate = cell(r, 'due_date').isNotEmpty
          ? cell(r, 'due_date')
          : DB.today();
      final id = await DB.addWord(WordEntry(
        word: word,
        phonetic: phonetic,
        translation: translation,
        tags: cell(r, 'tags'),
        note: cell(r, 'note'),
        createdAt: createdAt,
        stage: int.tryParse(cell(r, 'stage')) ?? 0,
        dueDate: dueDate,
        lapses: int.tryParse(cell(r, 'lapses')) ?? 0,
        topic: topic,
        senseGroup: cell(r, 'sense_group'),
        senseNote: cell(r, 'sense_note'),
        example: cell(r, 'example'),
        source: source,
      ));
      if (id != null) {
        added++;
        // 新增且缺话题/词义群的补规则聚类
        if (topic.isEmpty) {
          final t = Organize.ruleTopic(translation);
          final g = Organize.ruleSenseGroup(word);
          await DB.enrichWord(id, topic: t, senseGroup: g);
        }
      }
    }
    return 'added:$added';
  }

  /// 自动备份（后台任务调用）：写到应用数据目录，保留最近 7 份
  static Future<String?> autoBackup() async {
    try {
      final words = await DB.allWords();
      if (words.isEmpty) return null;
      final rows = [
        _headers,
        ...words.map((w) => [
              w.word, w.phonetic, w.translation, w.source, w.tags, w.note,
              w.topic, w.senseGroup, w.senseNote, w.example,
              w.createdAt, w.stage, w.dueDate, w.lapses,
            ]),
      ];
      final dir = await getApplicationSupportDirectory();
      final backupDir = Directory('${dir.path}/backups');
      if (!await backupDir.exists()) await backupDir.create(recursive: true);
      // 清理旧备份（保留 6 份）
      final old = (await backupDir.list().toList())
          .whereType<File>()
          .where((f) => f.path.endsWith('.csv'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (var i = 6; i < old.length; i++) {
        try { await old[i].delete(); } catch (_) {}
      }
      final file = File(
          '${backupDir.path}/woci_backup_${DB.today().replaceAll("-", "")}.csv');
      await file.writeAsString(
          '\uFEFF${const ListToCsvConverter().convert(rows)}',
          encoding: utf8);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}

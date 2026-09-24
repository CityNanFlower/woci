/// CSV 导入导出：生词本 + 复习记录备份 / 恢复
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

/// 导入结果
class ImportResult {
  final String error; // '' = 成功；'no_file' / 'bad_format'
  final int words;
  final int reviews;
  const ImportResult({this.error = '', this.words = 0, this.reviews = 0});
  bool get ok => error.isEmpty;
}

class CsvIo {
  static const _headers = [
    'word', 'phonetic', 'translation', 'source', 'tags', 'note',
    'topic', 'sense_group', 'sense_note', 'example', 'cloze',
    'created_at', 'stage', 'due_date', 'lapses',
  ];

  /// 复习记录单独一份：只导词表的话，恢复后打卡日历 / 连续天数 /
  /// 复习趋势图会全部归零（它们都依赖 reviews 表）。
  static const _reviewHeaders = ['word', 'result', 'at'];

  static List<dynamic> _wordRow(WordEntry w) => [
        w.word, w.phonetic, w.translation, w.source, w.tags, w.note,
        w.topic, w.senseGroup, w.senseNote, w.example, w.cloze,
        w.createdAt, w.stage, w.dueDate, w.lapses,
      ];

  /// 导出全量生词 + 复习记录为 CSV 并拉起系统分享
  static Future<({int words, int reviews})> exportWords() async {
    final words = await DB.allWords();
    final dir = await getTemporaryDirectory();
    final stamp = DB.today().replaceAll('-', '');
    final files = <XFile>[
      await _writeCsv(dir, 'woci_backup_$stamp.csv',
          [_headers, ...words.map(_wordRow)]),
    ];
    final reviews = await DB.allReviews();
    if (reviews.isNotEmpty) {
      files.add(await _writeCsv(dir, 'woci_reviews_$stamp.csv', [
        _reviewHeaders,
        ...reviews.map((r) => [r['word'], r['result'], r['at']]),
      ]));
    }
    await SharePlus.instance.share(ShareParams(
      files: files,
      text: '蜗词备份（${words.length} 词'
          '${reviews.isEmpty ? '' : ' + ${reviews.length} 条复习记录'}）',
    ));
    return (words: words.length, reviews: reviews.length);
  }

  /// 导入：支持多选；按表头自动区分「生词表」和「复习记录」
  static Future<ImportResult> importWords() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'txt'],
      allowMultiple: true,
      withData: true,
    );
    final files = picked?.files ?? <PlatformFile>[];
    if (files.isEmpty) return const ImportResult(error: 'no_file');

    var added = 0;
    var restored = 0;
    var hit = false;
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      final raw = await File(path).readAsString();
      final text =
          raw.isNotEmpty && raw.codeUnitAt(0) == 0xFEFF ? raw.substring(1) : raw;
      List<List<dynamic>> rows;
      try {
        rows = const CsvToListConverter(shouldParseNumbers: false).convert(text);
      } catch (_) {
        continue;
      }
      if (rows.isEmpty) continue;
      final header =
          rows.first.map((h) => h.toString().trim().toLowerCase()).toList();
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

      if (idx.containsKey('result') && idx.containsKey('at')) {
        hit = true;
        restored += await _importReviews(rows.skip(1), cell);
      } else if (idx.containsKey('word')) {
        hit = true;
        added += await _importWords(rows.skip(1), cell);
      }
    }
    if (!hit) return const ImportResult(error: 'bad_format');
    return ImportResult(words: added, reviews: restored);
  }

  static Future<int> _importWords(
      Iterable<List<dynamic>> rows, String Function(List, String) cell) async {
    var added = 0;
    for (final r in rows) {
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
        cloze: cell(r, 'cloze'),
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
    return added;
  }

  /// 按 (word_id, at) 去重回填复习记录，返回新增条数
  static Future<int> _importReviews(
      Iterable<List<dynamic>> rows, String Function(List, String) cell) async {
    final idMap = await DB.wordIdMap();
    final seen = await DB.reviewKeys();
    var n = 0;
    for (final r in rows) {
      final word = cell(r, 'word').toLowerCase();
      final at = cell(r, 'at');
      if (word.isEmpty || at.isEmpty) continue;
      final id = idMap[word];
      if (id == null) continue;
      final result = int.tryParse(cell(r, 'result')) ?? 0;
      if (await DB.addReviewIfAbsent(id, result, at, seen)) n++;
    }
    return n;
  }

  /// 自动备份（后台任务调用）：写到应用数据目录，按日期保留最近 6 天
  static Future<String?> autoBackup() async {
    try {
      final words = await DB.allWords();
      if (words.isEmpty) return null;
      final dir = await getApplicationSupportDirectory();
      final backupDir = Directory('${dir.path}/backups');
      if (!await backupDir.exists()) await backupDir.create(recursive: true);

      final stamp = DB.today().replaceAll('-', '');
      final reviews = await DB.allReviews();
      final written = <File>[
        await _writeCsvFile(backupDir, 'woci_backup_$stamp.csv',
            [_headers, ...words.map(_wordRow)]),
      ];
      if (reviews.isNotEmpty) {
        written.add(await _writeCsvFile(
            backupDir,
            'woci_reviews_$stamp.csv',
            [
              _reviewHeaders,
              ...reviews.map((r) => [r['word'], r['result'], r['at']]),
            ]));
      }

      // 清理旧备份：按文件名里的日期分组，保留最近 6 天
      final all = (await backupDir.list().toList())
          .whereType<File>()
          .where((f) => f.path.endsWith('.csv'))
          .toList();
      final stamps = all.map(_stampOf).toSet().toList()..sort();
      final drop = stamps.length <= 6
          ? <String>{}
          : stamps.sublist(0, stamps.length - 6).toSet();
      if (drop.isNotEmpty) {
        for (final f in all) {
          if (drop.contains(_stampOf(f))) {
            try {
              await f.delete();
            } catch (_) {}
          }
        }
      }
      return written.first.path;
    } catch (_) {
      return null;
    }
  }

  /// 从文件名里取日期戳，如 woci_backup_20260923.csv → 20260923
  static String _stampOf(File f) {
    final name =
        f.uri.pathSegments.isEmpty ? f.path : f.uri.pathSegments.last;
    final m = RegExp(r'(\d{8})\.csv$').firstMatch(name);
    return m?.group(1) ?? name;
  }

  /// 写 CSV 文件（自动加 BOM，便于 Excel 打开）
  static Future<File> _writeCsvFile(
      Directory dir, String name, List<List<dynamic>> rows) async {
    final file = File('${dir.path}/$name');
    await file.writeAsString(
        '\uFEFF${const ListToCsvConverter().convert(rows)}',
        encoding: utf8);
    return file;
  }

  static Future<XFile> _writeCsv(
      Directory dir, String name, List<List<dynamic>> rows) async {
    final file = await _writeCsvFile(dir, name, rows);
    return XFile(file.path, mimeType: 'text/csv');
  }
}

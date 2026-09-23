/// 本地数据层：生词表 + 复习记录 + 艾宾浩斯调度 + 自定义词书 + 统计
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class WordEntry {
  final int? id;
  final String word;
  final String phonetic;
  final String translation;
  final String tags;
  final String note;
  final String createdAt; // yyyy-MM-dd
  final int stage; // 0..6 艾宾浩斯轮次, 7=长期池
  final String dueDate; // yyyy-MM-dd
  final int lapses;
  final String topic; // 话题组
  final String senseGroup; // 词义群（同义词串）
  final String senseNote; // 一句话辨析
  final String example; // 英文例句
  final String source; // 来源：真题/听力/阅读/写作/翻译，空=未分类

  WordEntry({
    this.id,
    required this.word,
    this.phonetic = '',
    this.translation = '',
    this.tags = '',
    this.note = '',
    required this.createdAt,
    this.stage = 0,
    required this.dueDate,
    this.lapses = 0,
    this.topic = '',
    this.senseGroup = '',
    this.senseNote = '',
    this.example = '',
    this.source = '',
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'word': word,
        'phonetic': phonetic,
        'translation': translation,
        'tags': tags,
        'note': note,
        'created_at': createdAt,
        'stage': stage,
        'due_date': dueDate,
        'lapses': lapses,
        'topic': topic,
        'sense_group': senseGroup,
        'sense_note': senseNote,
        'example': example,
        'source': source,
      };

  static WordEntry fromMap(Map<String, Object?> m) => WordEntry(
        id: m['id'] as int?,
        word: m['word'] as String,
        phonetic: (m['phonetic'] ?? '') as String,
        translation: (m['translation'] ?? '') as String,
        tags: (m['tags'] ?? '') as String,
        note: (m['note'] ?? '') as String,
        createdAt: (m['created_at'] ?? '') as String,
        stage: (m['stage'] ?? 0) as int,
        dueDate: (m['due_date'] ?? '') as String,
        lapses: (m['lapses'] ?? 0) as int,
        topic: (m['topic'] ?? '') as String,
        senseGroup: (m['sense_group'] ?? '') as String,
        senseNote: (m['sense_note'] ?? '') as String,
        example: (m['example'] ?? '') as String,
        source: (m['source'] ?? '') as String,
      );
}

/// 复习结果：2=认识 1=模糊 0=忘了
class ReviewResult {
  static const known = 2;
  static const fuzzy = 1;
  static const forgot = 0;
}

/// 来源预置项（选填，空 = 未分类）
const kSourcePresets = ['真题', '听力', '阅读', '写作', '翻译'];

class DB {
  static Database? _db;

  /// 艾宾浩斯间隔表（天）：当天、1、2、4、7、15、30，之后进长期池每月抽查
  static const schedule = [0, 1, 2, 4, 7, 15, 30];

  static Future<Database> get instance async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(p.join(dir, 'woci.db'), version: 3,
        onCreate: (db, v) async {
      await db.execute('''
        CREATE TABLE words(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          word TEXT UNIQUE NOT NULL,
          phonetic TEXT DEFAULT '',
          translation TEXT DEFAULT '',
          tags TEXT DEFAULT '',
          note TEXT DEFAULT '',
          created_at TEXT NOT NULL,
          stage INTEGER DEFAULT 0,
          due_date TEXT NOT NULL,
          lapses INTEGER DEFAULT 0,
          topic TEXT DEFAULT '',
          sense_group TEXT DEFAULT '',
          sense_note TEXT DEFAULT '',
          example TEXT DEFAULT '',
          source TEXT DEFAULT ''
        )''');
      await db.execute('''
        CREATE TABLE reviews(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          word_id INTEGER NOT NULL,
          result INTEGER NOT NULL,
          at TEXT NOT NULL
        )''');
      await db.execute('CREATE INDEX idx_due ON words(due_date)');
      await db.execute('CREATE INDEX idx_created ON words(created_at)');
      await db.execute('''
        CREATE TABLE books(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          words_json TEXT NOT NULL,
          created_at TEXT NOT NULL
        )''');
    }, onUpgrade: (db, oldV, newV) async {
      if (oldV < 2) {
        await db.execute("ALTER TABLE words ADD COLUMN topic TEXT DEFAULT ''");
        await db
            .execute("ALTER TABLE words ADD COLUMN sense_group TEXT DEFAULT ''");
        await db
            .execute("ALTER TABLE words ADD COLUMN sense_note TEXT DEFAULT ''");
        await db.execute("ALTER TABLE words ADD COLUMN example TEXT DEFAULT ''");
        await db
            .execute('CREATE INDEX IF NOT EXISTS idx_created ON words(created_at)');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS daily_lists(
            date TEXT PRIMARY KEY,
            content TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )''');
      }
      if (oldV < 3) {
        await db.execute("ALTER TABLE words ADD COLUMN source TEXT DEFAULT ''");
        // 旧 tags 里的来源预设迁移到 source
        await db.execute(
            "UPDATE words SET source = tags WHERE tags IN ('真题','听力','阅读','写作','翻译')");
        // 旧私人话题 → 六级高频话题
        await db.execute(
            "UPDATE words SET topic = '科技创新' WHERE topic IN ('商业航天','低空经济')");
        await db.execute(
            "UPDATE words SET topic = '环境能源' WHERE topic = '环保气候'");
        await db.execute(
            "UPDATE words SET topic = '经济贸易' WHERE topic = '经济政策'");
        await db.execute(
            "UPDATE words SET topic = '教育学习' WHERE topic = '校园教育'");
        await db.execute('''
          CREATE TABLE IF NOT EXISTS books(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            words_json TEXT NOT NULL,
            created_at TEXT NOT NULL
          )''');
      }
    });
  }

  static String today() => DateTime.now().toIso8601String().substring(0, 10);

  static String _shift(String date, int days) {
    final d = DateTime.parse(date).add(Duration(days: days));
    return d.toIso8601String().substring(0, 10);
  }

  /// 新增生词：当天到期（首复）。重复添加返回 null。
  static Future<int?> addWord(WordEntry w) async {
    final db = await instance;
    final dup = await db.query('words',
        where: 'word = ?', whereArgs: [w.word.toLowerCase()]);
    if (dup.isNotEmpty) return null;
    return db.insert('words', w.toMap());
  }

  static Future<bool> wordExists(String word) async {
    final db = await instance;
    final rows = await db.query('words',
        columns: ['id'],
        where: 'word = ?',
        whereArgs: [word.toLowerCase()],
        limit: 1);
    return rows.isNotEmpty;
  }

  static Future<List<WordEntry>> dueWords({int limit = 100}) async {
    final db = await instance;
    final rows = await db.query('words',
        where: 'due_date <= ?',
        whereArgs: [today()],
        orderBy: 'due_date ASC, id ASC',
        limit: limit);
    return rows.map(WordEntry.fromMap).toList();
  }

  static Future<int> dueCount() async {
    final db = await instance;
    final rows = await db
        .rawQuery('SELECT COUNT(*) AS c FROM words WHERE due_date <= ?', [today()]);
    return (rows.first['c'] as int?) ?? 0;
  }

  static Future<int> todayReviewedCount() async {
    final db = await instance;
    final rows = await db.rawQuery(
        'SELECT COUNT(DISTINCT word_id) AS c FROM reviews WHERE at >= ?',
        ['${today()}T00:00']);
    return (rows.first['c'] as int?) ?? 0;
  }

  static Future<int> totalCount() async {
    final db = await instance;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM words');
    return (rows.first['c'] as int?) ?? 0;
  }

  static Future<int> masteredCount() async {
    final db = await instance;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM words WHERE stage >= 7');
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 应用复习结果，返回新的到期日
  static Future<String> review(int wordId, int result, int currentStage) async {
    final db = await instance;
    final t = today();
    int newStage;
    String newDue;
    switch (result) {
      case ReviewResult.known:
        newStage = currentStage >= 7 ? 7 : currentStage + 1;
        newDue = _shift(t, newStage >= 7 ? 30 : schedule[newStage]);
        break;
      case ReviewResult.fuzzy:
        newStage = currentStage; // 不升级不降级，明天再来
        newDue = _shift(t, 1);
        break;
      default:
        newStage = 0; // 忘了：回退重学
        newDue = _shift(t, 1);
        break;
    }
    await db.update('words', {'stage': newStage, 'due_date': newDue},
        where: 'id = ?', whereArgs: [wordId]);
    if (result == ReviewResult.forgot) {
      await db.execute('UPDATE words SET lapses = lapses + 1 WHERE id = ?',
          [wordId]);
    }
    await db.insert('reviews', {
      'word_id': wordId,
      'result': result,
      'at': DateTime.now().toIso8601String(),
    });
    return newDue;
  }

  static Future<List<WordEntry>> search(String q) async {
    final db = await instance;
    final like = '%$q%';
    final rows = await db.query('words',
        where: 'word LIKE ? OR translation LIKE ? OR tags LIKE ? OR note LIKE ? OR source LIKE ? OR topic LIKE ?',
        whereArgs: [like, like, like, like, like, like],
        orderBy: 'id DESC',
        limit: 100);
    return rows.map(WordEntry.fromMap).toList();
  }

  static Future<List<WordEntry>> allWords() async {
    final db = await instance;
    final rows = await db.query('words', orderBy: 'id DESC', limit: 5000);
    return rows.map(WordEntry.fromMap).toList();
  }

  static Future<void> updateNote(int id, String note) async {
    final db = await instance;
    await db.update('words', {'note': note}, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> updateSource(int id, String source) async {
    final db = await instance;
    await db.update('words', {'source': source}, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteWord(int id) async {
    final db = await instance;
    await db.delete('words', where: 'id = ?', whereArgs: [id]);
    await db.delete('reviews', where: 'word_id = ?', whereArgs: [id]);
  }

  // ---------------- 分类 / 增强 ----------------

  /// 某天新增的词
  static Future<List<WordEntry>> wordsCreatedOn(String date) async {
    final db = await instance;
    final rows = await db.query('words',
        where: 'created_at = ?', whereArgs: [date], orderBy: 'id ASC');
    return rows.map(WordEntry.fromMap).toList();
  }

  /// 写入聚类与 LLM 增强结果
  static Future<void> enrichWord(int id,
      {String? topic, String? senseGroup, String? senseNote, String? example}) async {
    final db = await instance;
    final m = <String, Object?>{};
    if (topic != null) m['topic'] = topic;
    if (senseGroup != null) m['sense_group'] = senseGroup;
    if (senseNote != null) m['sense_note'] = senseNote;
    if (example != null) m['example'] = example;
    if (m.isEmpty) return;
    await db.update('words', m, where: 'id = ?', whereArgs: [id]);
  }

  // ---------------- 统计 ----------------

  /// 每日复习次数（近 n 天），返回 {yyyy-MM-dd: count}，缺的天没有 key
  static Future<Map<String, int>> reviewCountsByDay(int days) async {
    final db = await instance;
    final from = _shift(today(), -(days - 1));
    final rows = await db.rawQuery('''
      SELECT substr(at, 1, 10) AS d, COUNT(*) AS c
      FROM reviews WHERE at >= ? GROUP BY substr(at, 1, 10)
    ''', ['$from T00:00'.replaceAll(' ', '')]);
    return {for (final r in rows) r['d'] as String: (r['c'] as int?) ?? 0};
  }

  /// 每日新增生词（近 n 天）
  static Future<Map<String, int>> createdCountsByDay(int days) async {
    final db = await instance;
    final from = _shift(today(), -(days - 1));
    final rows = await db.rawQuery('''
      SELECT created_at AS d, COUNT(*) AS c FROM words
      WHERE created_at >= ? GROUP BY created_at
    ''', [from]);
    return {for (final r in rows) r['d'] as String: (r['c'] as int?) ?? 0};
  }

  // ---------------- 自定义词书 ----------------

  static Future<int> addBook(String name, List<String> words) async {
    final db = await instance;
    return db.insert('books', {
      'name': name,
      'words_json': jsonEncode(words),
      'created_at': today(),
    });
  }

  static Future<List<Map<String, Object?>>> allBooks() async {
    final db = await instance;
    return db.query('books', orderBy: 'id DESC');
  }

  static Future<void> deleteBook(int id) async {
    final db = await instance;
    await db.delete('books', where: 'id = ?', whereArgs: [id]);
  }
}

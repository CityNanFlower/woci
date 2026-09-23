/// 词书数据层：内置词书（assets/wordbooks）+ 用户导入词书（DB books 表）
library;

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'db.dart';

class WordBook {
  final String id; // 内置: cet4/cet6/kaoyan；导入: 'custom_<id>'
  final String name;
  final String desc;
  final List<String> words;
  final bool builtin;
  const WordBook({
    required this.id,
    required this.name,
    required this.desc,
    required this.words,
    required this.builtin,
  });
}

class WordBooks {
  static List<WordBook> _builtin = [];

  static Future<void> load() async {
    _builtin = [];
    for (final id in ['cet4', 'cet6', 'kaoyan']) {
      try {
        final raw = await rootBundle.loadString('assets/wordbooks/$id.json');
        final e = json.decode(raw) as Map<String, dynamic>;
        _builtin.add(WordBook(
          id: id,
          name: (e['name'] ?? '') as String,
          desc: (e['desc'] ?? '') as String,
          words: ((e['words'] ?? []) as List).map((w) => w.toString()).toList(),
          builtin: true,
        ));
      } catch (_) {}
    }
  }

  static List<WordBook> get builtin => _builtin;

  /// 内置 + 导入的词书
  static Future<List<WordBook>> all() async {
    final list = [..._builtin];
    final rows = await DB.allBooks();
    for (final r in rows) {
      final raw = (r['words_json'] ?? '') as String;
      List<String> words = [];
      try {
        words = (json.decode(raw) as List).map((w) => w.toString()).toList();
      } catch (_) {}
      list.add(WordBook(
        id: 'custom_${r['id']}',
        name: (r['name'] ?? '') as String,
        desc: '导入词书 · ${words.length} 词',
        words: words,
        builtin: false,
      ));
    }
    return list;
  }
}

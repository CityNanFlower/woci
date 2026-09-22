/// ECDICT 六级子集加载与查询（assets/dict_cet6.json）
library;

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

class DictItem {
  final String word;
  final String phonetic;
  final String translation; // 中文释义
  final String definition; // 英文释义
  const DictItem({
    required this.word,
    this.phonetic = '',
    this.translation = '',
    this.definition = '',
  });
}

class Dict {
  static Map<String, DictItem> _byWord = {};
  static List<String> _words = [];
  /// 词义关键词倒排索引：用于从同义/近义词里抽干扰项
  static Map<String, List<String>> _senseIndex = {};

  static Future<void> load() async {
    try {
      final raw = await rootBundle.loadString('assets/dict_cet6.json');
      final List data = json.decode(raw) as List;
      for (final e in data) {
        final item = DictItem(
          word: (e['w'] ?? '') as String,
          phonetic: (e['p'] ?? '') as String,
          translation: (e['t'] ?? '') as String,
          definition: (e['d'] ?? '') as String,
        );
        if (item.word.isEmpty) continue;
        _byWord[item.word.toLowerCase()] = item;
        _words.add(item.word.toLowerCase());
      }
      _buildSenseIndex();
    } catch (_) {
      // 词典缺失时应用仍可运行（无查词/干扰项从词库退化到生词表）
    }
  }

  static void _buildSenseIndex() {
    final split = RegExp(r'[；;，,、\n]');
    for (final item in _byWord.values) {
      final tokens = item.translation.split(split);
      for (var tk in tokens) {
        tk = tk.trim();
        if (tk.length < 2 || tk.length > 6) continue;
        if (RegExp(r'[a-zA-Z\.]').hasMatch(tk)) continue;
        _senseIndex.putIfAbsent(tk, () => []).add(item.word.toLowerCase());
      }
    }
  }

  static DictItem? lookup(String word) => _byWord[word.toLowerCase().trim()];

  static int get size => _byWord.length;

  /// 同义/近义候选：与目标词共享中文义项关键词的其他词
  static List<String> sameSenseWords(String word, {int max = 20}) {
    final item = _byWord[word.toLowerCase()];
    if (item == null) return [];
    final split = RegExp(r'[；;，,、\n]');
    final tokens = item.translation
        .split(split)
        .map((s) => s.trim())
        .where((s) => s.length >= 2 && s.length <= 6)
        .where((s) => !RegExp(r'[a-zA-Z\.]').hasMatch(s))
        .toSet();
    final result = <String>{};
    for (final tk in tokens) {
      final list = _senseIndex[tk];
      if (list == null) continue;
      for (final w in list) {
        if (w != word.toLowerCase()) result.add(w);
        if (result.length >= max) return result.toList();
      }
    }
    return result.toList();
  }

  /// 抽 N 个干扰词：优先同词义，不足则随机补
  static List<String> distractors(String word, int n, [int? seed]) {
    final pool = <String>[];
    pool.addAll(sameSenseWords(word));
    // 随机补充
    final rnd = seed == null ? DateTime.now().microsecondsSinceEpoch : seed;
    var i = rnd % _words.length;
    var guard = 0;
    while (pool.length < n * 3 && guard < _words.length) {
      final w = _words[(i + guard) % _words.length];
      if (w != word.toLowerCase() && !pool.contains(w)) pool.add(w);
      guard++;
    }
    pool.shuffle();
    return pool.take(n).toList();
  }

  /// 模糊搜索（前缀优先）
  static List<DictItem> search(String q, {int limit = 10}) {
    q = q.toLowerCase().trim();
    if (q.isEmpty) return [];
    final starts = <DictItem>[];
    final contains = <DictItem>[];
    for (final w in _words) {
      if (w.startsWith(q)) {
        starts.add(_byWord[w]!);
        if (starts.length >= limit) break;
      }
    }
    if (starts.length < limit) {
      for (final w in _words) {
        if (!w.startsWith(q) && w.contains(q)) {
          contains.add(_byWord[w]!);
          if (starts.length + contains.length >= limit) break;
        }
      }
    }
    return [...starts, ...contains];
  }
}

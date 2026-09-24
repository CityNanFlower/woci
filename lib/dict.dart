/// ECDICT 六级子集加载与查询（assets/dict.json）
library;

import 'dart:convert';
import 'dart:math';
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

  /// 义项分隔符
  static final _senseSplit = RegExp(r'[，,；;、\n]');

  /// 专业领域标注，如 [医] [经] [计]
  static final _domainTag = RegExp(r'\[[^\]]*\]');

  /// 词性前缀，如 vt. vi. a. n. adv.
  static final _posTag = RegExp(
      r'\b(?:abbr|adj|adv|art|aux|conj|interj|int|num|prep|pron|vt|vi|v|n|a)\.',
      caseSensitive: false);

  static final _spaces = RegExp(r'\s+');
  static final _leadPunct = RegExp(r'^[,，、;；\s]+');

  static Future<void> load() async {
    try {
      final raw = await rootBundle.loadString('assets/dict.json');
      final List data = json.decode(raw) as List;
      final byWord = <String, DictItem>{};
      final words = <String>[];
      for (final e in data) {
        final item = DictItem(
          word: (e['w'] ?? '') as String,
          phonetic: (e['p'] ?? '') as String,
          translation: (e['t'] ?? '') as String,
          definition: (e['d'] ?? '') as String,
        );
        if (item.word.isEmpty) continue;
        byWord[item.word.toLowerCase()] = item;
        words.add(item.word.toLowerCase());
      }
      _byWord = byWord;
      _words = words;
      _buildSenseIndex();
    } catch (_) {
      // 词典缺失时应用仍可运行（无查词/干扰项从词库退化到生词表）
    }
  }

  /// 从中文释义里抽出可用于比对义项的短词
  static Set<String> _senseTokens(String translation) {
    final out = <String>{};
    for (var tk in translation.split(_senseSplit)) {
      tk = tk.trim();
      if (tk.length < 2 || tk.length > 6) continue;
      if (RegExp(r'[a-zA-Z\.]').hasMatch(tk)) continue;
      out.add(tk);
    }
    return out;
  }

  static void _buildSenseIndex() {
    for (final item in _byWord.values) {
      for (final tk in _senseTokens(item.translation)) {
        _senseIndex.putIfAbsent(tk, () => []).add(item.word.toLowerCase());
      }
    }
  }

  static DictItem? lookup(String word) => _byWord[word.toLowerCase().trim()];

  static int get size => _byWord.length;

  /// 取第一条中文义项。
  ///
  /// ECDICT 的释义只有约 5.8% 含分号，实际分隔符是半角逗号，所以
  /// `split('；')` 会原样返回整条长释义（还带着 `[医]` 这类领域标注和
  /// `vt.` 词性前缀）。这里先剥标注与词性，再按逗号取第一段。
  static String firstSense(String translation) {
    if (translation.isEmpty) return '';
    var s = translation
        .replaceAll(_domainTag, ' ')
        .replaceAll(_posTag, ' ')
        .replaceAll(_spaces, ' ')
        .trim();
    s = s.replaceFirst(_leadPunct, '');
    if (s.isEmpty) return translation.trim();
    final first = s.split(_senseSplit).first.trim();
    if (first.isNotEmpty) return first;
    return s;
  }

  /// 同义/近义候选：与目标词共享中文义项关键词的其他词
  static List<String> sameSenseWords(String word, {int max = 20}) {
    final item = _byWord[word.toLowerCase()];
    if (item == null) return [];
    final result = <String>{};
    for (final tk in _senseTokens(item.translation)) {
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

  /// 纯随机抽 N 个干扰词（完全不看词义）。
  ///
  /// 「看词选义」用它做干扰项：若用 sameSenseWords，选项之间的中文释义
  /// 高度重叠，会出现两个选项都说得通的歧义题。
  static List<String> randomDistractors(String word, int n, [int? seed]) {
    if (_words.isEmpty) return [];
    final target = word.toLowerCase();
    final rnd = Random(seed ?? DateTime.now().microsecondsSinceEpoch);
    final picked = <String>{};
    final limit = n * 40;
    var guard = 0;
    while (picked.length < n && guard < limit) {
      picked.add(_words[rnd.nextInt(_words.length)]);
      guard++;
    }
    picked.remove(target);
    return picked.take(n).toList();
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

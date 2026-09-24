/// 词书页：内置词书（四级/六级/考研）+ 导入词书，支持检索、勾选加入生词本
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'db.dart';
import 'dict.dart';
import 'llm.dart';
import 'main.dart' show kGreen;
import 'organize.dart';
import 'wordbook.dart';

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});
  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: FutureBuilder<List<WordBook>>(
        future: WordBooks.all(),
        builder: (ctx, snap) {
          final books = snap.data ?? const <WordBook>[];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 60, 16, 24),
            children: [
              const Text('词书', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: kGreen)),
              const SizedBox(height: 4),
              Text('选词加入生词本，自动进入艾宾浩斯复习计划；释义由内置词典现场补全。',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600])),
              const SizedBox(height: 16),
              ...books.map(_bookCard),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _importBook,
                icon: const Icon(Icons.upload_file),
                label: const Text('导入词书（txt / csv / json，每行一个单词）'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _bookCard(WordBook b) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(Icons.auto_stories_outlined, color: kGreen, size: 28),
        title: Text(b.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${b.desc} · ${b.words.length} 词'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openBook(b),
      ),
    );
  }

  Future<void> _openBook(WordBook book) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BookDetailPage(book: book),
    ));
    if (mounted) setState(() {});
  }

  // ---------------- 导入词书 ----------------

  Future<void> _importBook() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'csv', 'json'],
      withData: true,
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    final raw = await File(path).readAsString();
    // 去掉 UTF-8 BOM
    final text =
        raw.isNotEmpty && raw.codeUnitAt(0) == 0xFEFF ? raw.substring(1) : raw;

    final words = <String>{};
    try {
      if (path.endsWith('.json')) {
        final data = json.decode(text);
        if (data is List) {
          for (final e in data) {
            if (e is String) {
              words.add(e.toLowerCase().trim());
            } else if (e is Map && e['word'] != null) {
              words.add(e['word'].toString().toLowerCase().trim());
            }
          }
        }
      } else {
        // txt / csv：每行一个词（csv 取第一列，tab/逗号分隔均可）
        for (final line in text.split(RegExp(r'\r?\n'))) {
          final w = line.split(RegExp(r'[\t,，]')).first.trim().toLowerCase();
          if (w.isNotEmpty && RegExp(r"^[a-z][a-z\-']*$").hasMatch(w)) words.add(w);
        }
      }
    } catch (_) {}

    final list = words.toList();
    if (list.isEmpty || !mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没解析出有效单词，检查文件格式')));
      return;
    }
    final name = picked!.files.single.name.replaceAll(RegExp(r'\.(txt|csv|json)$', caseSensitive: false), '');
    await DB.addBook(name, list);
    setState(() {});
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已导入「$name」${list.length} 词')));
  }
}

// ---------------- 词书详情：检索 + 勾选加入 ----------------

class BookDetailPage extends StatefulWidget {
  final WordBook book;
  const BookDetailPage({super.key, required this.book});
  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  List<String> _all = [];
  List<String> _visible = [];
  final Set<String> _selected = {};
  final Set<String> _inBook = {}; // 已在生词本
  final _searchCtrl = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DB.instance;
    // 全量词表拉回本地求交集（避免 SQLite 变量上限）
    final rows = await db.query('words', columns: ['word']);
    final mine = rows.map((r) => (r['word'] as String).toLowerCase()).toSet();
    _inBook.addAll(mine.intersection(widget.book.words.toSet()));
    _all = widget.book.words;
    _visible = _all;
    if (mounted) setState(() => _loading = false);
  }

  void _filter(String q) {
    q = q.trim().toLowerCase();
    setState(() {
      _visible = q.isEmpty
          ? _all
          : _all.where((w) => w.contains(q)).toList();
    });
  }

  Future<void> _addSelected() async {
    if (_selected.isEmpty) return;
    final today = DB.today();
    var added = 0;
    for (final w in _selected) {
      final item = Dict.lookup(w) ?? DictItem(word: w, translation: '');
      final id = await DB.addWord(WordEntry(
        word: item.word,
        phonetic: item.phonetic,
        translation: item.translation,
        createdAt: today,
        dueDate: today,
      ));
      if (id != null) {
        added++;
        _inBook.add(w);
        final t = Organize.ruleTopic(item.translation);
        final g = Organize.ruleSenseGroup(item.word);
        await DB.enrichWord(id, topic: t, senseGroup: g);
      }
    }
    // 配置了 AI 则触发增强
    if (Llm.configured && added > 0) {
      final words = await DB.wordsCreatedOn(today);
      await Organize.enrichWords(words);
    }
    if (!mounted) return;
    setState(() => _selected.clear());
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已加入 $added 词（重复自动跳过）')));
  }

  Future<void> _addAll() async {
    final todo = _all.where((w) => !_inBook.contains(w)).toList();
    if (todo.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('这本书的词都已加入生词本')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全部加入？'),
        content: Text('将把 ${todo.length} 个词加入生词本并进入复习计划，确定？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (confirmed != true) return;
    final today = DB.today();
    var added = 0;
    for (final w in todo) {
      final item = Dict.lookup(w) ?? DictItem(word: w, translation: '');
      final id = await DB.addWord(WordEntry(
        word: item.word,
        phonetic: item.phonetic,
        translation: item.translation,
        createdAt: today,
        dueDate: today,
      ));
      if (id != null) {
        added++;
        _inBook.add(w);
        final t = Organize.ruleTopic(item.translation);
        final g = Organize.ruleSenseGroup(item.word);
        await DB.enrichWord(id, topic: t, senseGroup: g);
      }
    }
    if (Llm.configured && added > 0) {
      final words = await DB.wordsCreatedOn(today);
      await Organize.enrichWords(words);
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已加入 $added 词')));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.book.name} · ${_all.length} 词'),
        actions: [
          TextButton(onPressed: _addAll, child: const Text('全部加入')),
        ],
      ),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _addSelected,
              icon: const Icon(Icons.add),
              label: Text('加入生词本（${_selected.length}）'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: '在本词书中检索单词',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    isDense: true,
                  ),
                  onChanged: _filter,
                ),
              ),
              Expanded(
                child: _visible.isEmpty
                    ? Center(child: Text('没有匹配的单词', style: TextStyle(color: Colors.grey[600])))
                    : ListView.builder(
                        itemCount: _visible.length,
                        itemBuilder: (_, i) {
                          final w = _visible[i];
                          final inBook = _inBook.contains(w);
                          final item = Dict.lookup(w);
                          final trans = item == null
                              ? ''
                              : Dict.firstSense(item.translation);
                          return CheckboxListTile(
                            dense: true,
                            value: inBook || _selected.contains(w),
                            onChanged: inBook
                                ? null
                                : (v) => setState(() {
                                      v! ? _selected.add(w) : _selected.remove(w);
                                    }),
                            title: Text(w,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: inBook ? Colors.grey : null,
                                )),
                            subtitle: Text(inBook ? '已在生词本' : trans,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}

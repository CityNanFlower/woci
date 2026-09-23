/// 生词本页：三轴分类胶囊（话题 / 词义群 / 来源）+ 搜索 + 词条管理
/// 生词本 = 累计视角；今日词单页复用同一套轴（当日增量）
library;

import 'package:flutter/material.dart';
import 'db.dart';
import 'main.dart' show kGreen;

/// 分类轴
enum Axis3 { topic, sense, source }

class WordListPage extends StatefulWidget {
  final bool todayOnly; // true=今日词单（当日增量）
  const WordListPage({super.key, this.todayOnly = false});
  @override
  WordListPageState createState() => WordListPageState();
}

class WordListPageState extends State<WordListPage> {
  List<WordEntry> _words = [];
  String _query = '';
  Axis3 _axis = Axis3.topic;
  String? _group; // 当前选中的子分类（null=全部）
  bool _searchOpen = false;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final words = widget.todayOnly
        ? await DB.wordsCreatedOn(DB.today())
        : (_query.isEmpty ? await DB.allWords() : await DB.search(_query));
    if (mounted) setState(() => _words = words);
  }

  // ---------- 分组计算 ----------

  Map<String, List<WordEntry>> _groups() {
    final map = <String, List<WordEntry>>{};
    switch (_axis) {
      case Axis3.topic:
        for (final w in _words) {
          final g = w.topic.isEmpty ? '未分类' : w.topic;
          map.putIfAbsent(g, () => []).add(w);
        }
      case Axis3.source:
        for (final w in _words) {
          final g = w.source.isEmpty ? '未分类' : w.source;
          map.putIfAbsent(g, () => []).add(w);
        }
      case Axis3.sense:
        // 词义群：同义替换组，≥2 词才成组（有就分，没有就不分）
        for (final w in _words) {
          final g = w.senseGroup.trim();
          if (g.contains('/')) map.putIfAbsent(g, () => []).add(w);
        }
        map.removeWhere((_, v) => v.length < 2);
    }
    // 组内按词排序，组按词数降序
    final entries = map.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return Map.fromEntries(entries);
  }

  List<WordEntry> get _visible {
    if (_group == null) return _words;
    final g = _groups()[_group];
    return g ?? const [];
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups();
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 56, 16, widget.todayOnly ? 4 : 8),
          child: Row(children: [
            Expanded(
              child: Text(
                widget.todayOnly ? '今日词单 · ${DB.today().substring(5)}' : '生词本（累计 ${_words.length} 词）',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            if (!widget.todayOnly)
              IconButton(
                icon: Icon(_searchOpen ? Icons.search_off : Icons.search, color: kGreen),
                onPressed: () => setState(() {
                  _searchOpen = !_searchOpen;
                  if (!_searchOpen) { _query = ''; refresh(); }
                }),
              ),
          ]),
        ),
        if (_searchOpen && !widget.todayOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: '搜索单词 / 释义 / 话题 / 来源 / 笔记',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                isDense: true,
              ),
              onChanged: (v) { _query = v; refresh(); },
            ),
          ),
        _axisBar(),
        Expanded(
          child: _words.isEmpty
              ? Center(child: Text(
                  widget.todayOnly ? '今天还没有整理出词单\n先去「今日」页录几个生词吧' : '还没有生词，去「今日」页录入吧',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[600])))
              : _list(groups),
        ),
      ],
    );
  }

  Widget _axisBar() {
    Widget axisChip(Axis3 a, String label, IconData icon) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        avatar: Icon(icon, size: 16,
            color: _axis == a ? Colors.white : kGreen),
        label: Text(label),
        selected: _axis == a,
        selectedColor: kGreen,
        labelStyle: TextStyle(color: _axis == a ? Colors.white : kGreen, fontWeight: FontWeight.w600),
        showCheckmark: false,
        onSelected: (_) => setState(() { _axis = a; _group = null; }),
      ),
    );
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          axisChip(Axis3.topic, '话题', Icons.topic_outlined),
          axisChip(Axis3.sense, '词义群', Icons.join_inner_outlined),
          axisChip(Axis3.source, '来源', Icons.source_outlined),
        ],
      ),
    );
  }

  Widget _groupBar(Map<String, List<WordEntry>> groups) {
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text('全部 ${_words.length}'),
          selected: _group == null,
          selectedColor: kGreen.withValues(alpha: 0.25),
          onSelected: (_) => setState(() => _group = null),
        ),
      ),
      ...groups.entries.map((g) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          label: Text('${g.key} ${g.value.length}'),
          selected: _group == g.key,
          selectedColor: kGreen.withValues(alpha: 0.25),
          onSelected: (_) => setState(() => _group = (_group == g.key ? null : g.key)),
        ),
      )),
    ];
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: children,
      ),
    );
  }

  Widget _list(Map<String, List<WordEntry>> groups) {
    final visible = _visible;
    return Column(children: [
      if (groups.isNotEmpty) _groupBar(groups),
      Expanded(
        child: visible.isEmpty
            ? Center(child: Text('这个分类下还没有词', style: TextStyle(color: Colors.grey[600])))
            : (groups.isEmpty
                ? ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: visible.length,
                    itemBuilder: (_, i) => _tile(visible[i]))
                : ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: _groupedList(groups),
                  )),
      ),
    ]);
  }

  /// 有分组时：按组渲染小节
  List<Widget> _groupedList(Map<String, List<WordEntry>> groups) {
    final widgets = <Widget>[];
    final keys = _group == null ? groups.keys.toList() : [_group!];
    for (final k in keys) {
      final list = groups[k];
      if (list == null || list.isEmpty) continue;
      widgets.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Text('$k · ${list.length} 词',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: kGreen)),
      ));
      for (final w in list) {
        widgets.add(_tile(w));
      }
    }
    if (widgets.isEmpty) {
      widgets.add(Center(child: Text('这个分类下还没有词', style: TextStyle(color: Colors.grey[600]))));
    }
    return widgets;
  }

  Widget _tile(WordEntry w) {
    final stageLabel = w.stage >= 7 ? '长期池' : '第${w.stage + 1}轮';
    return ListTile(
      dense: true,
      title: Text('${w.word}  ${w.phonetic}', style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${w.translation.split('；').first.split(';').first}'
        '${w.topic.isEmpty ? '' : ' · ${w.topic}'}'
        '${w.source.isEmpty ? '' : ' · ${w.source}'}'
        '\n$stageLabel · 到期 ${w.dueDate}${w.lapses > 0 ? ' · 忘过${w.lapses}次' : ''}',
        maxLines: 2, overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: w.stage >= 7
          ? const Icon(Icons.verified, color: kGreen)
          : Icon(Icons.school_outlined, color: Colors.grey[400]),
      onTap: () => _showDetail(w),
    );
  }

  Future<void> _showDetail(WordEntry w) async {
    final noteCtrl = TextEditingController(text: w.note);
    String source = w.source;
    await showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialog) => AlertDialog(
          title: Text('${w.word}  ${w.phonetic}'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(w.translation, style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 8),
                if (w.topic.isNotEmpty)
                  Text('话题：${w.topic}', style: const TextStyle(fontSize: 12, color: kGreen)),
                if (w.senseGroup.isNotEmpty)
                  Text('词义群：${w.senseGroup}', style: const TextStyle(fontSize: 12, color: kGreen)),
                if (w.senseNote.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('辨析：${w.senseNote}', style: const TextStyle(fontSize: 12)),
                  ),
                if (w.example.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(w.example,
                        style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.black87)),
                  ),
                const SizedBox(height: 8),
                Text('录入：${w.createdAt} ｜ 阶段：${w.stage >= 7 ? '长期池' : '第${w.stage + 1}轮'} ｜ 到期：${w.dueDate}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  children: [
                    const Text('来源：', style: TextStyle(fontSize: 13, color: Colors.grey)),
                    ...kSourcePresets.map((t) => FilterChip(
                          label: Text(t),
                          selected: source == t,
                          onSelected: (sel) => setDialog(() => source = sel ? t : ''),
                        )),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: noteCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '我的笔记 / 助记',
                    border: OutlineInputBorder(),
                  ),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await DB.deleteWord(w.id!);
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                refresh();
              },
              label: const Text('删除', style: TextStyle(color: Colors.red)),
              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
            ),
            FilledButton(
              onPressed: () async {
                await DB.updateNote(w.id!, noteCtrl.text);
                await DB.updateSource(w.id!, source);
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                refresh();
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}

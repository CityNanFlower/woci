import 'package:flutter/material.dart';
import 'db.dart';
import 'dict.dart';
import 'llm.dart';
import 'notify.dart';
import 'organize.dart';
import 'pages.dart';

void main() {
  runApp(const WoCiApp());
}

class WoCiApp extends StatefulWidget {
  const WoCiApp({super.key});
  @override
  State<WoCiApp> createState() => _WoCiAppState();
}

class _WoCiAppState extends State<WoCiApp> {
  bool _ready = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await DB.instance;
      await Dict.load();
      await Llm.load();
      await Notify.init();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '蜗词',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007A43),
        ),
      ),
      home: _ready
          ? (_error.isEmpty
              ? const HomePage()
              : _ErrorPage(error: _error))
          : const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
    );
  }
}

class _ErrorPage extends StatelessWidget {
  final String error;
  const _ErrorPage({required this.error});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text('初始化失败：$error', textAlign: TextAlign.center),
      )),
    );
  }
}

const kGreen = Color(0xFF007A43);
const kExamDate = '2026-12-12';

int daysToExam() {
  final exam = DateTime.parse(kExamDate);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return exam.difference(today).inDays;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  final GlobalKey<TodayPageState> _todayKey = GlobalKey<TodayPageState>();
  final GlobalKey<WordBookPageState> _bookKey = GlobalKey<WordBookPageState>();
  final GlobalKey<StatsPageState> _statsKey = GlobalKey<StatsPageState>();

  @override
  void initState() {
    super.initState();
    _autoOrganize();
  }

  /// 启动即触发当日整理（幂等：当天已整理自动跳过）
  /// 规则聚类离线秒级完成；配置了 AI 则后台增强，完成后刷新
  Future<void> _autoOrganize() async {
    final r = await Organize.run();
    if (!mounted) return;
    if (r == 'llm') {
      _todayKey.currentState?.refresh();
      _bookKey.currentState?.refresh();
      _statsKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          TodayPage(key: _todayKey),
          WordBookPage(key: _bookKey),
          StatsPage(key: _statsKey),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: '今日'),
          NavigationDestination(icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book), label: '生词本'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: '统计'),
        ],
      ),
      floatingActionButton: _tab == 0 ? FloatingActionButton.extended(
        onPressed: _addWord,
        icon: const Icon(Icons.add),
        label: const Text('录生词'),
      ) : null,
    );
  }

  Future<void> _addWord() async {
    await showDialog(context: context, builder: (_) => const AddWordDialog());
    _todayKey.currentState?.refresh();
    _bookKey.currentState?.refresh();
    _statsKey.currentState?.refresh();
  }
}

// ---------------- 今日页 ----------------

class TodayPage extends StatefulWidget {
  const TodayPage({super.key});
  @override
  TodayPageState createState() => TodayPageState();
}

class TodayPageState extends State<TodayPage> {
  int _due = 0;
  int _reviewed = 0;
  int _todayNew = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final due = await DB.dueCount();
    final reviewed = await DB.todayReviewedCount();
    final todayWords = await DB.wordsCreatedOn(DB.today());
    if (mounted) {
      setState(() {
        _due = due;
        _reviewed = reviewed;
        _todayNew = todayWords.length;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final days = daysToExam();
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 60, 16, 24),
        children: [
          Row(
            children: [
              const Text('蜗词', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: kGreen)),
              const Spacer(),
              Chip(
                avatar: const Icon(Icons.timer_outlined, size: 18, color: kGreen),
                label: Text('距六级笔试 $days 天', style: const TextStyle(color: kGreen, fontWeight: FontWeight.w600)),
                backgroundColor: kGreen.withValues(alpha: 0.08),
              ),
              IconButton(
                onPressed: _openSettings,
                icon: const Icon(Icons.settings_outlined, color: kGreen),
                tooltip: '设置',
              ),
            ],
          ),
          const SizedBox(height: 20),
          _DueCard(
            due: _due,
            reviewed: _reviewed,
            loading: _loading,
            onStart: _due > 0 ? _startQuiz : null,
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.auto_stories_outlined, color: kGreen),
              title: const Text('今日词单', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(_todayNew > 0
                  ? '今天新录 $_todayNew 词 · 已按词义群 + 话题整理'
                  : '今天还没有新词，录一个试试'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DailyListPage()));
                refresh();
              },
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('快速录入', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 4),
                  Text('点右下角「录生词」按钮：输入单词自动补全释义，支持一次粘贴多个（空格/换行分隔）。',
                      style: TextStyle(fontSize: 13, color: Colors.grey[700])),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('复习节奏', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 8),
                  Text('艾宾浩斯七轮：当天 → 1天 → 2天 → 4天 → 7天 → 15天 → 30天，之后进长期池每月抽查。',
                      style: TextStyle(fontSize: 13, color: Colors.grey[700])),
                  const SizedBox(height: 4),
                  Text('认识=间隔升级 ｜ 模糊=明天再来 ｜ 忘了=回退重学',
                      style: TextStyle(fontSize: 13, color: Colors.grey[700])),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startQuiz() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => QuizPage(onDone: refresh),
    ));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsPage()));
    refresh();
  }
}

class _DueCard extends StatelessWidget {
  final int due;
  final int reviewed;
  final bool loading;
  final VoidCallback? onStart;
  const _DueCard({required this.due, required this.reviewed, required this.loading, this.onStart});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: kGreen,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: loading
            ? const Center(child: Padding(
                padding: EdgeInsets.all(16), child: CircularProgressIndicator(color: Colors.white)))
            : Column(
                children: [
                  Text('$due',
                      style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
                  const Text('个词待复习', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 8),
                  Text('今天已复习 $reviewed 个', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: onStart,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: kGreen,
                      minimumSize: const Size(160, 44),
                    ),
                    child: Text(due > 0 ? '开始辨析测验' : '今日已完成 ✓'),
                  ),
                ],
              ),
      ),
    );
  }
}

// ---------------- 录入 ----------------

class AddWordDialog extends StatefulWidget {
  const AddWordDialog({super.key});
  @override
  State<AddWordDialog> createState() => _AddWordDialogState();
}

class _AddWordDialogState extends State<AddWordDialog> {
  final _controller = TextEditingController();
  DictItem? _found;
  String _tags = '';
  bool _bulk = false;
  String _msg = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    final clean = text.trim();
    final isBulk = RegExp(r'[\s,;，；]+').hasMatch(clean);
    setState(() {
      _bulk = isBulk;
      _found = isBulk ? null : Dict.lookup(clean);
      _msg = '';
    });
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final tags = _tags;
    final today = DB.today();
    var added = 0;
    var dup = 0;
    final List<DictItem> items;
    if (_bulk) {
      final parts = text.split(RegExp(r'[\s,;，；]+')).where((s) => s.isNotEmpty).toSet();
      items = parts.map((w) => Dict.lookup(w)).whereType<DictItem>().toList();
      if (items.isEmpty) {
        setState(() => _msg = '词库中没找到这些词，请逐个检查拼写');
        return;
      }
    } else {
      var item = _found ?? Dict.lookup(text);
      item ??= DictItem(word: text.toLowerCase(), translation: '');
      items = [item];
    }
    for (final it in items) {
      final r = await DB.addWord(WordEntry(
        word: it.word.toLowerCase(),
        phonetic: it.phonetic,
        translation: it.translation,
        tags: tags,
        createdAt: today,
        dueDate: today,
      ));
      if (r == null) { dup++; } else { added++; }
    }
    if (!mounted) return;
    setState(() {
      _msg = '已录入 $added 个${dup > 0 ? '，重复跳过 $dup 个' : ''}';
      _controller.clear();
      _found = null;
      _tags = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_bulk ? '批量录入' : '录入生词'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: _bulk ? 4 : 1,
              onChanged: _onChanged,
              decoration: const InputDecoration(
                hintText: '输入单词，或粘贴多个（空格/换行分隔）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_found != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: kGreen.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${_found!.word}  ${_found!.phonetic}',
                        style: const TextStyle(fontWeight: FontWeight.w600, color: kGreen)),
                    const SizedBox(height: 4),
                    Text(_found!.translation.isEmpty ? '（词库暂无释义）' : _found!.translation,
                        style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              children: ['真题', '听力', '写作', '翻译', '阅读']
                  .map((t) => FilterChip(
                        label: Text(t),
                        selected: _tags.split(',').contains(t),
                        onSelected: (sel) {
                          setState(() {
                            final list = _tags.split(',').where((s) => s.isNotEmpty).toList();
                            if (sel) { if (!list.contains(t)) list.add(t); } else { list.remove(t); }
                            _tags = list.join(',');
                          });
                        },
                      ))
                  .toList(),
            ),
            if (_msg.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_msg, style: const TextStyle(color: kGreen, fontSize: 13)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(_bulk ? '全部录入' : '录入'),
        ),
      ],
    );
  }
}

// ---------------- 辨析测验 ----------------

class QuizPage extends StatefulWidget {
  final VoidCallback? onDone;
  const QuizPage({super.key, this.onDone});
  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizQuestion {
  final WordEntry entry;
  final bool enToZh; // true: 看英文选中文；false: 看中文选英文
  final bool isFill; // 例句填空题
  final String cloze; // 挖空例句
  final List<String> options;
  final int answerIndex;
  _QuizQuestion(this.entry, this.enToZh, this.options, this.answerIndex,
      {this.isFill = false, this.cloze = ''});
}

class _QuizPageState extends State<QuizPage> {
  List<_QuizQuestion> _questions = [];
  int _index = 0;
  int? _picked;
  bool _answered = false;
  int _correct = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _build();
  }

  Future<void> _build() async {
    final due = await DB.dueWords(limit: 50);
    final qs = <_QuizQuestion>[];
    for (final w in due) {
      // 优先例句填空（有例句时）：考"为什么用这个词而不用它的近义词"
      final cloze = w.example.isNotEmpty ? Organize.makeCloze(w.example, w.word) : null;
      if (cloze != null) {
        final options = <String>[w.word];
        for (final d in Dict.sameSenseWords(w.word, max: 12)) {
          if (!options.contains(d)) options.add(d);
          if (options.length >= 4) break;
        }
        for (final d in Dict.distractors(w.word, 4)) {
          if (options.length >= 4) break;
          if (!options.contains(d)) options.add(d);
        }
        options.shuffle();
        qs.add(_QuizQuestion(w, false, options, options.indexOf(w.word),
            isFill: true, cloze: cloze));
        continue;
      }
      final enToZh = w.id!.isOdd; // 英中两个方向交替
      final List<String> options = [];
      if (enToZh) {
        final correct = w.translation.isEmpty ? w.word : w.translation;
        options.add(correct);
        for (final d in Dict.distractors(w.word, 3)) {
          final di = Dict.lookup(d);
          final trans = di?.translation ?? d;
          if (trans != correct && !options.contains(trans)) options.add(trans);
          if (options.length >= 4) break;
        }
      } else {
        options.add(w.word);
        for (final d in Dict.distractors(w.word, 3)) {
          if (!options.contains(d)) options.add(d);
          if (options.length >= 4) break;
        }
      }
      options.shuffle();
      final correctText = enToZh ? (w.translation.isEmpty ? w.word : w.translation) : w.word;
      qs.add(_QuizQuestion(w, enToZh, options, options.indexOf(correctText)));
    }
    if (!mounted) return;
    setState(() { _questions = qs; _loading = false; });
  }

  Future<void> _pick(int i) async {
    if (_answered) return;
    final q = _questions[_index];
    setState(() { _picked = i; _answered = true; });
    final result = i == q.answerIndex ? ReviewResult.known : ReviewResult.forgot;
    if (i == q.answerIndex) _correct++;
    await DB.review(q.entry.id!, result, q.entry.stage);
  }

  Future<void> _markFuzzy() async {
    final q = _questions[_index];
    await DB.review(q.entry.id!, ReviewResult.fuzzy, q.entry.stage);
    _next();
  }

  void _next() {
    if (_index + 1 >= _questions.length) {
      Navigator.pop(context);
      widget.onDone?.call();
      return;
    }
    setState(() { _index++; _picked = null; _answered = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('辨析测验')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _questions.isEmpty
              ? const Center(child: Text('没有到期的词，明天再来吧'))
              : (_answered && _picked != null && _picked != _questions[_index].answerIndex)
                  ? _wrongView()
                  : (_answered && _picked != null)
                      ? _correctView()
                      : _questionView(),
    );
  }

  Widget _questionView() {
    final q = _questions[_index];
    final progress = (_index) / _questions.length;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        LinearProgressIndicator(value: progress, minHeight: 6, borderRadius: BorderRadius.circular(3)),
        const SizedBox(height: 8),
        Text('第 ${_index + 1} / ${_questions.length} 题 · 已对 $_correct',
            style: TextStyle(fontSize: 13, color: Colors.grey[600])),
        const SizedBox(height: 28),
        if (q.isFill) ...[
          Card(
            color: kGreen.withValues(alpha: 0.05),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(q.cloze,
                  style: const TextStyle(fontSize: 17, height: 1.6)),
            ),
          ),
          const SizedBox(height: 6),
          Center(child: Text('结合句意，选出填空最恰当的词',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]))),
          if (q.entry.translation.isNotEmpty)
            Center(child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('释义提示：${q.entry.translation.split('；').first.split(';').first}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            )),
        ] else ...[
          Center(
            child: q.enToZh
                ? Text(q.entry.word,
                    style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold))
                : Text(q.entry.translation.isEmpty ? q.entry.word : q.entry.translation.split('；').first.split(';').first,
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
          ),
          if (!q.enToZh && q.entry.phonetic.isNotEmpty)
            Center(child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(q.entry.phonetic, style: TextStyle(fontSize: 14, color: Colors.grey[600])),
            )),
          const SizedBox(height: 6),
          Center(child: Text(q.enToZh ? '选出正确释义' : '选出对应英文单词',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]))),
        ],
        const SizedBox(height: 28),
        ...List.generate(q.options.length, (i) => _option(q, i)),
      ],
    );
  }

  Widget _option(_QuizQuestion q, int i) {
    final isAnswer = i == q.answerIndex;
    final isPicked = i == _picked;
    Color bg = Theme.of(context).colorScheme.surfaceContainerHighest;
    Color border = Colors.transparent;
    if (_answered && isAnswer) { bg = kGreen.withValues(alpha: 0.15); border = kGreen; }
    if (_answered && isPicked && !isAnswer) { bg = Colors.red.withValues(alpha: 0.10); border = Colors.red; }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _answered ? null : () => _pick(i),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border, width: 1.5),
            ),
            child: Text(q.options[i], style: const TextStyle(fontSize: 16)),
          ),
        ),
      ),
    );
  }

  /// 辨析解析卡：完整例句 + 同义词群 + 一句话辨析
  Widget _analysisCard(_QuizQuestion q) {
    final w = q.entry;
    return Card(
      color: kGreen.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (w.example.isNotEmpty) ...[
            Text(w.example,
                style: const TextStyle(fontSize: 14, height: 1.5, fontStyle: FontStyle.italic)),
            const SizedBox(height: 8),
          ],
          if (w.senseGroup.isNotEmpty)
            Text('词义群：${w.senseGroup}',
                style: const TextStyle(fontSize: 13, color: kGreen, fontWeight: FontWeight.w600)),
          if (w.senseNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('辨析：${w.senseNote}', style: const TextStyle(fontSize: 13, height: 1.4)),
          ],
          if (w.example.isEmpty && w.senseGroup.isEmpty)
            Text('（配置 AI 后可生成例句与辨析）',
                style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        ]),
      ),
    );
  }

  Widget _correctView() {
    final q = _questions[_index];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.check_circle, color: kGreen, size: 48),
        const SizedBox(height: 8),
        const Center(child: Text('答对了',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: kGreen))),
        const SizedBox(height: 16),
        _analysisCard(q),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _next,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: Text(_index + 1 >= _questions.length ? '完成测验' : '下一题'),
        ),
      ],
    );
  }

  Widget _wrongView() {
    final q = _questions[_index];
    final correct = q.options[q.answerIndex];
    final correctItem = Dict.lookup(q.enToZh ? correct : q.entry.word);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.close, color: Colors.red, size: 48),
        const SizedBox(height: 8),
        Center(child: Text('正确答案：${q.enToZh ? q.entry.word : correct}',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
        const SizedBox(height: 4),
        Center(child: Text(q.enToZh ? correct : (correctItem?.translation ?? ''),
            style: const TextStyle(fontSize: 15, color: kGreen, fontWeight: FontWeight.w600))),
        const SizedBox(height: 16),
        _analysisCard(q),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _markFuzzy,
          style: FilledButton.styleFrom(backgroundColor: Colors.amber.shade700, minimumSize: const Size.fromHeight(48)),
          child: const Text('记混了 · 明天再来（模糊）'),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: _next,
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: const Text('完全忘了 · 回退重学'),
        ),
      ],
    );
  }
}

// ---------------- 生词本 ----------------

class WordBookPage extends StatefulWidget {
  const WordBookPage({super.key});
  @override
  WordBookPageState createState() => WordBookPageState();
}

class WordBookPageState extends State<WordBookPage> {
  List<WordEntry> _words = [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final words = _query.isEmpty ? await DB.allWords() : await DB.search(_query);
    if (mounted) setState(() => _words = words);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 56, 16, 8),
          child: TextField(
            decoration: InputDecoration(
              hintText: '全局搜索：单词 / 释义 / 标签 / 笔记',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              isDense: true,
            ),
            onChanged: (v) { _query = v; refresh(); },
          ),
        ),
        Expanded(
          child: _words.isEmpty
              ? Center(child: Text(_query.isEmpty ? '还没有生词，去「今日」页录入吧' : '没有匹配结果', style: TextStyle(color: Colors.grey[600])))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: _words.length,
                  itemBuilder: (_, i) => _tile(_words[i]),
                ),
        ),
      ],
    );
  }

  Widget _tile(WordEntry w) {
    final stageLabel = w.stage >= 7 ? '长期池' : '第${w.stage + 1}轮';
    return ListTile(
      title: Text('${w.word}  ${w.phonetic}', style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${w.translation.split('；').first.split(';').first}${w.tags.isEmpty ? '' : ' · ${w.tags}'}\n$stageLabel · 到期 ${w.dueDate}${w.lapses > 0 ? ' · 忘过${w.lapses}次' : ''}',
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
    await showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('${w.word}  ${w.phonetic}'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(w.translation, style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 8),
              Text('录入：${w.createdAt} ｜ 阶段：${w.stage >= 7 ? '长期池' : '第${w.stage + 1}轮'} ｜ 到期：${w.dueDate}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              const SizedBox(height: 12),
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
              if (dialogCtx.mounted) Navigator.pop(dialogCtx);
              refresh();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

// ---------------- 统计 ----------------

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});
  @override
  StatsPageState createState() => StatsPageState();
}

class StatsPageState extends State<StatsPage> {
  int _total = 0, _mastered = 0, _due = 0, _reviewedToday = 0;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    _total = await DB.totalCount();
    _mastered = await DB.masteredCount();
    _due = await DB.dueCount();
    _reviewedToday = await DB.todayReviewedCount();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      padding: const EdgeInsets.fromLTRB(16, 60, 16, 24),
      crossAxisCount: 2,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.6,
      children: [
        _statCard('累计生词', '$_total', Icons.library_books_outlined),
        _statCard('已入长期池', '$_mastered', Icons.verified_outlined),
        _statCard('今日待复习', '$_due', Icons.schedule_outlined),
        _statCard('今日已复习', '$_reviewedToday', Icons.task_alt_outlined),
      ],
    );
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: kGreen, size: 28),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
            Text(label, style: TextStyle(fontSize: 13, color: Colors.grey[600])),
          ],
        ),
      ),
    );
  }
}

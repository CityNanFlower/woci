import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'bg.dart';
import 'db.dart';
import 'dict.dart';
import 'llm.dart';
import 'notify.dart';
import 'organize.dart';
import 'wordlist_page.dart';
import 'wordbook.dart';
import 'wordbook_page.dart';
import 'pages.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
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
      await WordBooks.load();
      await Llm.load();
      await AppPrefs.load();
      await Notify.init();
      await registerBackgroundTask();
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

/// 应用级偏好：考试日期 / 学习偏好（测验模式多选）
class AppPrefs {
  static String examDate = '2026-12-12';
  static List<String> studyModes = ['random'];

  static const modeOrder = ['random', 'sense', 'topic', 'spell'];
  static const modeLabels = {
    'random': '随机测验',
    'sense': '词义群辨析',
    'topic': '话题联想',
    'spell': '拼写',
  };
  static const modeDescs = {
    'random': '看词选义 / 看义选词，四选一',
    'sense': '例句填空选词（无例句时选近义词）',
    'topic': '按话题 + 释义提示联想选词',
    'spell': '看释义手动输入拼写（全键盘）',
  };

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    examDate = sp.getString('exam_date') ?? '2026-12-12';
    final modes = sp.getStringList('study_modes');
    studyModes = (modes == null || modes.isEmpty)
        ? ['random']
        : modes.where(modeOrder.contains).toList();
    if (studyModes.isEmpty) studyModes = ['random'];
  }

  static Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('exam_date', examDate);
    await sp.setStringList('study_modes', studyModes);
  }
}

int daysToExam() {
  final exam = DateTime.parse(AppPrefs.examDate);
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
  final GlobalKey<WordListPageState> _wordListKey = GlobalKey<WordListPageState>();
  final GlobalKey<StatsPageState> _statsKey = GlobalKey<StatsPageState>();

  @override
  void initState() {
    super.initState();
    _autoOrganize();
  }

  /// 启动即触发当日整理（幂等：当天已整理自动跳过）
  Future<void> _autoOrganize() async {
    final r = await Organize.run();
    if (!mounted) return;
    if (r == 'llm') _refreshAll();
  }

  void _refreshAll() {
    _todayKey.currentState?.refresh();
    _wordListKey.currentState?.refresh();
    _statsKey.currentState?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          TodayPage(key: _todayKey),
          const BookshelfPage(),
          WordListPage(key: _wordListKey),
          StatsPage(key: _statsKey),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: '今日'),
          NavigationDestination(icon: Icon(Icons.auto_stories_outlined), selectedIcon: Icon(Icons.auto_stories), label: '词书'),
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
    _refreshAll();
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
    final modeCount = AppPrefs.studyModes.length;
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
                label: Text('距考试 $days 天', style: const TextStyle(color: kGreen, fontWeight: FontWeight.w600)),
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
            modeCount: modeCount,
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
            child: ListTile(
              leading: const Icon(Icons.style_outlined, color: kGreen),
              title: const Text('学习偏好', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(AppPrefs.studyModes.map((m) => AppPrefs.modeLabels[m]).join(' + ')),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openSettings,
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
    if (!mounted) return;
    setState(() {}); // 学习偏好可能改了
    refresh();
  }
}

class _DueCard extends StatelessWidget {
  final int due;
  final int reviewed;
  final bool loading;
  final int modeCount;
  final VoidCallback? onStart;
  const _DueCard({required this.due, required this.reviewed, required this.loading, required this.modeCount, this.onStart});

  @override
  Widget build(BuildContext context) {
    final rounds = modeCount > 1 ? '（每词 $modeCount 轮）' : '';
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
                  Text('个词待复习$rounds', style: const TextStyle(color: Colors.white70)),
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
                    child: Text(due > 0 ? '开始复习测验' : '今日已完成 ✓'),
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
  String _source = '';
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
      final id = await DB.addWord(WordEntry(
        word: it.word.toLowerCase(),
        phonetic: it.phonetic,
        translation: it.translation,
        source: _source,
        createdAt: today,
        dueDate: today,
      ));
      if (id == null) {
        dup++;
      } else {
        added++;
        // 立即规则打底（话题 + 词义群），AI 增强由每日整理完成
        final t = Organize.ruleTopic(it.translation);
        final g = Organize.ruleSenseGroup(it.word);
        await DB.enrichWord(id, topic: t, senseGroup: g);
      }
    }
    if (!mounted) return;
    setState(() {
      _msg = '已录入 $added 个${dup > 0 ? '，重复跳过 $dup 个' : ''}';
      _controller.clear();
      _found = null;
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
              children: [
                const Text('来源（选填）：', style: TextStyle(fontSize: 13, color: Colors.grey)),
                ...kSourcePresets.map((t) => FilterChip(
                      label: Text(t),
                      selected: _source == t,
                      onSelected: (sel) =>
                          setState(() => _source = sel ? t : ''),
                    )),
              ],
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

// ---------------- 复习测验（多模式 · 每词多轮） ----------------

class QuizPage extends StatefulWidget {
  final VoidCallback? onDone;
  const QuizPage({super.key, this.onDone});
  @override
  State<QuizPage> createState() => _QuizPageState();
}

enum QuizMode { random, sense, topic, spell }

class _QuizQuestion {
  final WordEntry entry;
  final QuizMode mode;
  final bool enToZh; // random 模式方向
  final bool isCloze; // sense 模式：例句填空
  final String cloze;
  final bool isSynonym; // sense 模式：选近义词
  final List<String> options;
  final int answerIndex;
  _QuizQuestion({
    required this.entry,
    required this.mode,
    this.enToZh = true,
    this.isCloze = false,
    this.cloze = '',
    this.isSynonym = false,
    this.options = const [],
    this.answerIndex = 0,
  });
}

/// 一次复习会话：按偏好模式给每个词生成多轮题目
class _QuizSession {
  final List<_QuizQuestion> questions = [];
  /// 每题对应单词的序号（用于分组判分）
  final List<int> wordIndexOf = [];
  final List<WordEntry> words;
  _QuizSession(this.words, List<QuizMode> modes) {
    for (var wi = 0; wi < words.length; wi++) {
      for (final m in modes) {
        final q = _build(words[wi], m);
        if (q != null) {
          questions.add(q);
          wordIndexOf.add(wi);
        }
      }
    }
  }

  static QuizMode _fromKey(String key) => switch (key) {
        'sense' => QuizMode.sense,
        'topic' => QuizMode.topic,
        'spell' => QuizMode.spell,
        _ => QuizMode.random,
      };

  static Future<_QuizSession> build() async {
    final due = await DB.dueWords(limit: 50);
    final modes = AppPrefs.studyModes.map(_fromKey).toList();
    return _QuizSession(due, modes);
  }

  _QuizQuestion? _build(WordEntry w, QuizMode mode) {
    switch (mode) {
      case QuizMode.random:
        return _randomQ(w);
      case QuizMode.sense:
        return _senseQ(w);
      case QuizMode.topic:
        return _topicQ(w);
      case QuizMode.spell:
        return _spellQ(w);
    }
  }

  _QuizQuestion _randomQ(WordEntry w) {
    final enToZh = w.id!.isOdd;
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
    return _QuizQuestion(
        entry: w, mode: QuizMode.random, enToZh: enToZh,
        options: options, answerIndex: options.indexOf(correctText));
  }

  _QuizQuestion? _senseQ(WordEntry w) {
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
      return _QuizQuestion(entry: w, mode: QuizMode.sense, isCloze: true,
          cloze: cloze, options: options, answerIndex: options.indexOf(w.word));
    }
    // 无例句：选近义词（词义群内）
    final sibs = Dict.sameSenseWords(w.word, max: 8);
    if (sibs.isEmpty) return _randomQ(w); // 降级
    final correct = sibs.first;
    final options = <String>[correct];
    for (final d in Dict.distractors(w.word, 6)) {
      if (!options.contains(d) && !sibs.contains(d)) options.add(d);
      if (options.length >= 4) break;
    }
    options.shuffle();
    return _QuizQuestion(entry: w, mode: QuizMode.sense, isSynonym: true,
        options: options, answerIndex: options.indexOf(correct));
  }

  _QuizQuestion _topicQ(WordEntry w) {
    // 干扰项：优先同话题的其它生词，不足用词典随机词
    final options = <String>[w.word];
    for (final d in _sameTopicWords(w)) {
      if (!options.contains(d)) options.add(d);
      if (options.length >= 4) break;
    }
    for (final d in Dict.distractors(w.word, 4)) {
      if (options.length >= 4) break;
      if (!options.contains(d)) options.add(d);
    }
    options.shuffle();
    return _QuizQuestion(entry: w, mode: QuizMode.topic,
        options: options, answerIndex: options.indexOf(w.word));
  }

  static List<WordEntry>? _topicPool;

  List<String> _sameTopicWords(WordEntry w) {
    _topicPool ??= <WordEntry>[]; // 延后填充（见 build 后 _fillTopicPool）
    final pool = _topicPool!;
    final rnd = Random(w.id!);
    final cands = pool.where((e) => e.topic == w.topic && e.word != w.word).toList();
    cands.shuffle(rnd);
    return cands.take(3).map((e) => e.word).toList();
  }

  _QuizQuestion _spellQ(WordEntry w) {
    return _QuizQuestion(entry: w, mode: QuizMode.spell);
  }
}

class _QuizPageState extends State<QuizPage> {
  _QuizSession? _session;
  int _index = 0;
  int? _picked;
  bool _answered = false;
  bool _spellCorrect = false;
  final _spellCtrl = TextEditingController();
  int _correct = 0;
  final Map<int, int> _wrongByWord = {}; // wordIndex -> 错了几轮
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void dispose() {
    _spellCtrl.dispose();
    super.dispose();
  }

  Future<void> _build() async {
    final session = await _QuizSession.build();
    // 同话题词池：给话题联想出干扰项
    _QuizSession._topicPool = await DB.allWords();
    if (!mounted) return;
    setState(() { _session = session; _loading = false; });
  }

  bool get _isWordLastRound {
    final s = _session!;
    final wi = s.wordIndexOf[_index];
    return _index + 1 >= s.questions.length || s.wordIndexOf[_index + 1] != wi;
  }

  Future<void> _submitSpell() async {
    if (_answered) return;
    final q = _session!.questions[_index];
    final input = _spellCtrl.text.trim().toLowerCase();
    if (input.isEmpty) return;
    setState(() {
      _answered = true;
      _spellCorrect = input == q.entry.word.toLowerCase();
    });
    await _record(_spellCorrect);
  }

  Future<void> _pick(int i) async {
    if (_answered) return;
    final q = _session!.questions[_index];
    setState(() { _picked = i; _answered = true; });
    await _record(i == q.answerIndex);
  }

  Future<void> _record(bool correct) async {
    if (correct) _correct++;
    final s = _session!;
    final wi = s.wordIndexOf[_index];
    if (!correct) _wrongByWord[wi] = (_wrongByWord[wi] ?? 0) + 1;
    // 该词的最后一轮：按总错轮数判分（全对=认识，错1轮=模糊，错≥2=忘了）
    if (_isWordLastRound) {
      final wrong = _wrongByWord[wi] ?? 0;
      final result = wrong == 0
          ? ReviewResult.known
          : (wrong == 1 ? ReviewResult.fuzzy : ReviewResult.forgot);
      await DB.review(s.words[wi].id!, result, s.words[wi].stage);
    }
  }

  void _next() {
    if (_index + 1 >= _session!.questions.length) {
      Navigator.pop(context);
      widget.onDone?.call();
      return;
    }
    setState(() {
      _index++;
      _picked = null;
      _answered = false;
      _spellCorrect = false;
      _spellCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('复习测验')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_session == null || _session!.questions.isEmpty)
              ? const Center(child: Text('没有到期的词，明天再来吧'))
              : _body(),
    );
  }

  Widget _body() {
    final q = _session!.questions[_index];
    if (_answered) {
      final correct = q.mode == QuizMode.spell ? _spellCorrect : _picked == q.answerIndex;
      return correct ? _correctView(q) : _wrongView(q);
    }
    return _questionView(q);
  }

  Widget _progressHeader() {
    final s = _session!;
    final wi = s.wordIndexOf[_index];
    final wordNo = wi + 1;
    final roundNo = s.wordIndexOf.take(_index + 1).where((x) => x == wi).length;
    final totalRounds = s.wordIndexOf.where((x) => x == wi).length;
    return Column(children: [
      LinearProgressIndicator(
          value: _index / s.questions.length, minHeight: 6,
          borderRadius: BorderRadius.circular(3)),
      const SizedBox(height: 8),
      Text('词 $wordNo / ${s.words.length} · 第 $roundNo / $totalRounds 轮 · 已对 $_correct',
          style: TextStyle(fontSize: 13, color: Colors.grey[600])),
    ]);
  }

  Widget _questionView(_QuizQuestion q) {
    final w = q.entry;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _progressHeader(),
        const SizedBox(height: 24),
        ...switch (q.mode) {
          QuizMode.random => [
              Center(
                child: q.enToZh
                    ? Text(w.word, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold))
                    : Text(w.translation.isEmpty ? w.word : w.translation.split('；').first.split(';').first,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                        textAlign: TextAlign.center),
              ),
              if (!q.enToZh && w.phonetic.isNotEmpty)
                Center(child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(w.phonetic, style: TextStyle(fontSize: 14, color: Colors.grey[600])),
                )),
              const SizedBox(height: 6),
              Center(child: Text(q.enToZh ? '选出正确释义' : '选出对应英文单词',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]))),
              const SizedBox(height: 24),
              ...List.generate(q.options.length, (i) => _option(q, i)),
            ],
          QuizMode.sense when q.isCloze => [
              Card(
                color: kGreen.withValues(alpha: 0.05),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(q.cloze, style: const TextStyle(fontSize: 17, height: 1.6)),
                ),
              ),
              const SizedBox(height: 6),
              Center(child: Text('结合句意，选出填空最恰当的词',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]))),
              if (w.translation.isNotEmpty)
                Center(child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('释义提示：${w.translation.split('；').first.split(';').first}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                )),
              const SizedBox(height: 24),
              ...List.generate(q.options.length, (i) => _option(q, i)),
            ],
          QuizMode.sense => [
              Center(child: Text(w.word,
                  style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold))),
              if (w.translation.isNotEmpty)
                Center(child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('释义：${w.translation.split('；').first.split(';').first}',
                      style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                )),
              const SizedBox(height: 6),
              const Center(child: Text('选出与它词义最接近的词',
                  style: TextStyle(fontSize: 13, color: Colors.grey))),
              const SizedBox(height: 24),
              ...List.generate(q.options.length, (i) => _option(q, i)),
            ],
          QuizMode.topic => [
              Center(child: Text(w.topic.isEmpty ? '生活日常' : w.topic,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: kGreen))),
              const SizedBox(height: 10),
              Center(child: Text(w.translation.isEmpty ? '(无释义)' : w.translation.split('；').first.split(';').first,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center)),
              const SizedBox(height: 6),
              const Center(child: Text('按话题与释义，联想对应英文单词',
                  style: TextStyle(fontSize: 13, color: Colors.grey))),
              const SizedBox(height: 24),
              ...List.generate(q.options.length, (i) => _option(q, i)),
            ],
          QuizMode.spell => [
              Card(
                color: kGreen.withValues(alpha: 0.05),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('释义：${w.translation.isEmpty ? '(无释义)' : w.translation}',
                        style: const TextStyle(fontSize: 15, height: 1.5)),
                    if (w.phonetic.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('音标：${w.phonetic}',
                            style: TextStyle(fontSize: 14, color: Colors.grey[600])),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 6),
              const Center(child: Text('手动输入单词拼写', style: TextStyle(fontSize: 13, color: Colors.grey))),
              const SizedBox(height: 20),
              TextField(
                controller: _spellCtrl,
                autofocus: true,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z\-]'))],
                decoration: InputDecoration(
                  hintText: '输入英文单词',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                      icon: const Icon(Icons.send_outlined, color: kGreen),
                      onPressed: _submitSpell),
                ),
                onSubmitted: (_) => _submitSpell(),
              ),
              const SizedBox(height: 12),
              Center(child: TextButton(
                onPressed: () async {
                  setState(() { _answered = true; _spellCorrect = false; });
                  await _record(false);
                },
                child: const Text('想不起来 · 判错'),
              )),
            ],
        },
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
  Widget _analysisCard(WordEntry w) {
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

  Widget _correctView(_QuizQuestion q) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.check_circle, color: kGreen, size: 48),
        const SizedBox(height: 8),
        const Center(child: Text('答对了',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: kGreen))),
        const SizedBox(height: 16),
        _analysisCard(q.entry),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _next,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: Text(_index + 1 >= _session!.questions.length ? '完成测验' : '下一题'),
        ),
      ],
    );
  }

  Widget _wrongView(_QuizQuestion q) {
    final w = q.entry;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.close, color: Colors.red, size: 48),
        const SizedBox(height: 8),
        Center(child: Text('正确答案：${w.word}',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
        const SizedBox(height: 4),
        Center(child: Text(w.translation.isEmpty ? '' : w.translation.split('；').first.split(';').first,
            style: const TextStyle(fontSize: 15, color: kGreen, fontWeight: FontWeight.w600))),
        const SizedBox(height: 16),
        _analysisCard(w),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _next,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: Text(_index + 1 >= _session!.questions.length ? '完成测验' : '下一题'),
        ),
      ],
    );
  }
}

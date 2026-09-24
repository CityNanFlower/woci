/// 每日整理引擎：双维聚类（话题组 + 词义群）
/// 规则打底（离线可用）→ LLM 增强（配置了才跑，失败自动降级）
library;

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'db.dart';
import 'dict.dart';
import 'llm.dart';

/// 一次整理的结果
class OrganizeResult {
  /// 'already'（当天已整理）/ 'empty'（没有待整理的词）/ 'done' / 'llm'
  final String status;

  /// 本次真正被 LLM 增强的词数
  final int enriched;

  /// 本次结束后仍待 AI 增强的词数
  final int pending;

  const OrganizeResult(this.status, {this.enriched = 0, this.pending = 0});

  bool get usedLlm => status == 'llm';
}

class Organize {
  /// 预置话题组：依据历年六级真题翻译/写作高频话题分类（传统文化≈40%、
  /// 社会发展≈30%、科技≈20%、生态环保≈10% + 写作热点），不含私人方向。
  static const presetTopics = [
    '传统文化', '社会民生', '经济贸易', '科技创新', '环境能源',
    '教育学习', '职场就业', '健康生活', '网络媒体', '生活日常',
  ];

  static const allTopicFallback = '生活日常';

  /// 单次运行最多交给 LLM 的词数。
  /// 批量导入整本词书（数千词）时，靠这个上限把额度摊到多次运行里，
  /// 剩下的会在下次启动 / 下次后台任务继续补。
  static const llmMaxPerRun = 60;

  /// 单次请求最多带多少个词
  static const _llmBatchSize = 30;

  /// 单次规则打底时最多扫描多少个待增强词
  static const _ruleScanLimit = 200;

  /// 自定义话题（sp）
  static Future<List<String>> customTopics() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getStringList('topics_custom') ?? [];
  }

  static Future<void> addCustomTopic(String name) async {
    final sp = await SharedPreferences.getInstance();
    final list = (sp.getStringList('topics_custom') ?? []);
    if (name.isNotEmpty && !list.contains(name)) list.add(name);
    await sp.setStringList('topics_custom', list);
  }

  static Future<List<String>> allTopics() async =>
      [...presetTopics, ...await customTopics()];

  /// 离线规则：按中文释义关键词归话题（兜底）
  static String ruleTopic(String translation) {
    const rules = {
      '传统文化': ['文化', '节日', '传统', '习俗', '历史', '艺术', '书法', '京剧', '遗产', '民俗', '春节', '孔'],
      '社会民生': ['社会', '民生', '城市', '乡村', '人口', '养老', '医疗', '住房', '法律', '政府', '公民', '福利', '脱贫'],
      '经济贸易': ['经济', '贸易', '税收', '货币', '通胀', '财政', '投资', '市场', '金融', '补贴', '产业', '基金', '股', '债', '商品', '消费'],
      '科技创新': ['科技', '技术', '数字', '智能', '算法', '数据', '机器', '电子', '设备', '卫星', '航天', '航空', '无人机', '创新', '工程', '网络', '通信'],
      '环境能源': ['气候', '碳', '污染', '环保', '排放', '能源', '生态', '回收', '可再生', '全球变暖', '温室', '环境', '绿色'],
      '教育学习': ['学校', '课程', '学', '考试', '教', '论文', '学位', '校园', '成绩', '招生', '知识', '读书'],
      '职场就业': ['职业', '就业', '工作', '公司', '企业', '员工', '老板', '同事', '面试', '简历', '工资', '职场', '创业', '管理'],
      '健康生活': ['健康', '疾病', '医', '药', '心理', '情绪', '压力', '运动', '饮食', '睡眠', '身体', '健身'],
      '网络媒体': ['互联网', '网络', '媒体', '新闻', '广告', '社交', '视频', '直播', '流量', '平台', '隐私', '账号'],
    };
    for (final entry in rules.entries) {
      for (final kw in entry.value) {
        if (translation.contains(kw)) return entry.key;
      }
    }
    return allTopicFallback;
  }

  /// 离线规则：词义群 = 词典同义项词前几个
  static String ruleSenseGroup(String word) {
    final sibs = Dict.sameSenseWords(word, max: 3);
    return sibs.isEmpty ? '' : [word, ...sibs].join(' / ');
  }

  /// 触发整理：幂等（当天已整理则跳过，除非 force）
  ///
  /// 配了 AI 时，整理对象是「所有还缺例句/辨析的词」而不是「今天新增的词」，
  /// 这样批量导入超过单次上限、或某天失败漏掉的词，会在后续运行里自动补上。
  static Future<OrganizeResult> run({bool force = false}) async {
    final sp = await SharedPreferences.getInstance();
    final today = DB.today();
    final last = sp.getString('organized_date');
    if (!force && last == today) {
      return OrganizeResult('already', pending: await _pendingCount());
    }

    final todo = Llm.configured
        ? await DB.wordsPendingEnrich(limit: _ruleScanLimit)
        : await DB.wordsCreatedOn(today);

    if (todo.isEmpty) {
      await sp.setString('organized_date', today);
      return const OrganizeResult('empty');
    }

    final before = Llm.configured ? await DB.countPendingEnrich() : 0;
    final enriched = await enrichWords(todo);
    final after = Llm.configured ? await DB.countPendingEnrich() : 0;

    // 还有剩余（说明本次有进展）就不记账，下次启动 / 下次后台任务继续补；
    // 若本次毫无进展（网络或模型报错），记账，避免一天内反复重试。
    if (after == 0 || after >= before) {
      await sp.setString('organized_date', today);
    }
    return OrganizeResult(enriched > 0 ? 'llm' : 'done',
        enriched: enriched, pending: after);
  }

  static Future<int> _pendingCount() async {
    if (!Llm.configured) return 0;
    try {
      return await DB.countPendingEnrich();
    } catch (_) {
      return 0;
    }
  }

  /// 对给定词列表做规则打底 + LLM 增强（词书批量加入后也走这里）
  /// 返回本次被 LLM 增强成功的词数
  static Future<int> enrichWords(List<WordEntry> words,
      {int maxLlm = llmMaxPerRun}) async {
    // 1) 规则打底（离线可用）
    for (final w in words) {
      final topic = w.topic.isEmpty || presetTopicsOld.contains(w.topic)
          ? ruleTopic(w.translation)
          : w.topic;
      final group = w.senseGroup.isEmpty ? ruleSenseGroup(w.word) : w.senseGroup;
      if (topic != w.topic || group != w.senseGroup) {
        await DB.enrichWord(w.id!, topic: topic, senseGroup: group);
      }
    }

    // 2) LLM 增强（未配置则跳过，结果仍可用）
    if (!Llm.configured) return 0;
    return _llmEnrich(words, maxLlm);
  }

  /// v1.1 的旧话题名（用于迁移重归类）
  static const presetTopicsOld = ['环保气候', '商业航天', '低空经济', '经济政策', '校园教育'];

  /// LLM 批量增强：话题归属 + 词义群 + 一句话辨析 + 例句 + 挖空例句
  /// 返回实际写入的词数
  static Future<int> _llmEnrich(List<WordEntry> words, int maxWords) async {
    final topics = await allTopics();
    final items = <Map<String, dynamic>>[];
    final byWord = <String, WordEntry>{};
    for (final w in words) {
      if (items.length >= maxWords) break;
      if (w.example.isNotEmpty && w.senseNote.isNotEmpty) continue; // 已增强过
      final key = w.word.toLowerCase();
      if (byWord.containsKey(key)) continue;
      byWord[key] = w;
      items.add({'w': key, 't': Dict.firstSense(w.translation)});
    }
    if (items.isEmpty) return 0;

    var done = 0;
    for (var i = 0; i < items.length; i += _llmBatchSize) {
      final slice = items.sublist(i, min(i + _llmBatchSize, items.length));
      done += await _llmBatch(slice, topics, byWord);
    }
    return done;
  }

  static Future<int> _llmBatch(List<Map<String, dynamic>> items,
      List<String> topics, Map<String, WordEntry> byWord) async {
    final system = '你是六级英语辅导老师。只输出 JSON 数组，不要输出任何解释或 Markdown 代码块标记。';
    final user = json.encode({
      '任务': '为每个单词完成：topic（从给定话题组里选一个最贴切的）、group（2-3个同义/近义英文词，含自身，用" / "分隔）、'
          'note（一句话中文辨析，说明该词与同义词的核心区别，30字内）、example（一个大学英语六级难度的英文例句，必须包含该词）、'
          'cloze（同一例句但把该词换成 _____，其余不变）',
      '输出格式': [
        {
          'w': '单词原形（小写）',
          'topic': '话题组里的一个词',
          'group': 'a / b / c',
          'note': '一句话辨析',
          'example': '英文例句',
          'cloze': '把 example 里的该词换成 _____ 的版本',
        }
      ],
      '话题组': topics,
      '单词': items,
    });

    final raw = await Llm.chat(system, user, maxTokens: 2500);
    if (raw == null) return 0;
    // 容错解析：剥掉可能的 ```json 包裹
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text
          .replaceFirst(RegExp(r'^```[a-z]*'), '')
          .replaceAll('```', '')
          .trim();
    }
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start < 0 || end <= start) return 0;

    var applied = 0;
    try {
      final arr = json.decode(text.substring(start, end + 1)) as List;
      for (final e in arr) {
        if (e is! Map) continue;
        final word = (e['w'] ?? '').toString().toLowerCase();
        final target = byWord[word];
        if (target == null) continue;
        final example = (e['example'] ?? '').toString();
        var cloze = (e['cloze'] ?? '').toString();
        // 挖空必须真的留了空位，否则回退本地规则生成
        if (cloze.isNotEmpty && !cloze.contains('_')) cloze = '';
        if (cloze.isEmpty && example.isNotEmpty) {
          cloze = makeCloze(example, target.word) ?? '';
        }
        await DB.enrichWord(target.id!,
            topic: (e['topic'] ?? '').toString(),
            senseGroup: (e['group'] ?? '').toString(),
            senseNote: (e['note'] ?? '').toString(),
            example: example,
            cloze: cloze);
        applied++;
      }
    } catch (_) {
      return applied;
    }
    return applied;
  }

  /// 例句挖空：把目标词（含简单变形）替换为 _____；找不到返回 null
  static String? makeCloze(String example, String word) {
    final forms = [
      word,
      '${word}s', '${word}es', '${word}ed', '${word}d', '${word}ing',
      word.endsWith('e') ? '${word.substring(0, word.length - 1)}ing' : '',
      word.endsWith('y') ? '${word.substring(0, word.length - 1)}ies' : '',
      word.endsWith('y') ? '${word.substring(0, word.length - 1)}ied' : '',
    ].where((f) => f.isNotEmpty).toSet();
    for (final f in forms) {
      final re = RegExp('\\b${RegExp.escape(f)}\\b', caseSensitive: false);
      if (re.hasMatch(example)) {
        return example.replaceFirst(re, '_____');
      }
    }
    return null;
  }
}

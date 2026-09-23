/// 每日整理引擎：双维聚类（话题组 + 词义群）
/// 规则打底（离线可用）→ LLM 增强（配置了才跑，失败自动降级）
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'db.dart';
import 'dict.dart';
import 'llm.dart';

class Organize {
  /// 预置话题组：依据历年六级真题翻译/写作高频话题分类（传统文化≈40%、
  /// 社会发展≈30%、科技≈20%、生态环保≈10% + 写作热点），不含私人方向。
  static const presetTopics = [
    '传统文化', '社会民生', '经济贸易', '科技创新', '环境能源',
    '教育学习', '职场就业', '健康生活', '网络媒体', '生活日常',
  ];

  static const allTopicFallback = '生活日常';

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
  /// 返回状态：'done' / 'llm' / 'already' / 'empty'
  static Future<String> run({bool force = false}) async {
    final sp = await SharedPreferences.getInstance();
    final today = DB.today();
    final last = sp.getString('organized_date');
    if (!force && last == today) return 'already';

    final words = await DB.wordsCreatedOn(today);
    if (words.isEmpty) {
      await sp.setString('organized_date', today);
      return 'empty';
    }

    final usedLlm = await enrichWords(words);
    await sp.setString('organized_date', today);
    return usedLlm ? 'llm' : 'done';
  }

  /// 对给定词列表做规则打底 + LLM 增强（词书批量加入后也走这里）
  /// 返回是否使用了 LLM
  static Future<bool> enrichWords(List<WordEntry> words) async {
    // 1) 规则打底
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
    if (Llm.configured) {
      return await _llmEnrich(words);
    }
    return false;
  }

  /// v1.1 的旧话题名（用于迁移重归类）
  static const presetTopicsOld = ['环保气候', '商业航天', '低空经济', '经济政策', '校园教育'];

  /// LLM 批量增强：话题归属 + 词义群 + 一句话辨析 + 例句（含挖空版）
  static Future<bool> _llmEnrich(List<WordEntry> words) async {
    final topics = await allTopics();
    final items = <Map<String, dynamic>>[];
    for (final w in words.take(30)) {
      if (w.example.isNotEmpty && w.senseNote.isNotEmpty) continue; // 已增强过
      items.add({'w': w.word, 't': w.translation.split('；').first.split(';').first});
    }
    if (items.isEmpty) return true;

    final system = '你是六级英语辅导老师。只输出 JSON 数组，不要输出任何解释或 Markdown 代码块标记。';
    final user = json.encode({
      '任务': '为每个单词完成：topic（从给定话题组里选一个最贴切的）、group（2-3个同义/近义英文词，含自身，用" / "分隔）、'
          'note（一句话中文辨析，说明该词与同义词的核心区别，30字内）、example（一个大学英语六级难度的英文例句，必须包含该词）、'
          'cloze（同一例句但把该词换成 _____，其余不变）',
      '话题组': topics,
      '单词': items,
    });

    final raw = await Llm.chat(system, user, maxTokens: 2500);
    if (raw == null) return false;
    // 容错解析：剥掉可能的 ```json 包裹
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text.replaceFirst(RegExp(r'^```[a-z]*'), '').replaceAll('```', '').trim();
    }
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start < 0 || end <= start) return false;
    try {
      final arr = json.decode(text.substring(start, end + 1)) as List;
      final byWord = {for (final w in words) w.word: w};
      for (final e in arr) {
        if (e is! Map) continue;
        final word = (e['w'] ?? '').toString().toLowerCase();
        final target = byWord[word];
        if (target == null) continue;
        await DB.enrichWord(target.id!,
            topic: (e['topic'] ?? '').toString(),
            senseGroup: (e['group'] ?? '').toString(),
            senseNote: (e['note'] ?? '').toString(),
            example: (e['example'] ?? '').toString());
      }
      return true;
    } catch (_) {
      return false;
    }
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

/// 设置页 + 今日词单页
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'db.dart';
import 'llm.dart';
import 'main.dart' show kGreen, daysToExam;
import 'organize.dart';

// ---------------- 设置页 ----------------

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String _presetId;
  late TextEditingController _baseCtrl;
  late TextEditingController _modelCtrl;
  late TextEditingController _keyCtrl;
  bool _testing = false;
  String _testMsg = '';
  bool _testOk = false;
  List<String> _topics = [];
  final _topicCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final s = Llm.settings;
    _presetId = s.presetId;
    _baseCtrl = TextEditingController(text: s.baseUrl);
    _modelCtrl = TextEditingController(text: s.model);
    _keyCtrl = TextEditingController(text: s.key);
    _loadTopics();
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    _topicCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTopics() async {
    _topics = await Organize.allTopics();
    if (mounted) setState(() {});
  }

  void _applyPreset(String id) {
    final preset = kLlmPresets.firstWhere((p) => p.id == id);
    setState(() {
      _presetId = id;
      if (preset.baseUrl.isNotEmpty) _baseCtrl.text = preset.baseUrl;
      if (preset.defaultModel.isNotEmpty) _modelCtrl.text = preset.defaultModel;
      _testMsg = '';
    });
  }

  Future<void> _save() async {
    final s = Llm.settings;
    s.presetId = _presetId;
    s.baseUrl = _baseCtrl.text.trim();
    s.model = _modelCtrl.text.trim();
    s.key = _keyCtrl.text.trim();
    await Llm.save();
  }

  Future<void> _test() async {
    await _save();
    setState(() { _testing = true; _testMsg = '测试中…'; });
    final err = await Llm.testConnection();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = err == null;
      _testMsg = err ?? '✓ 连接成功，AI 增强已可用';
    });
  }

  Future<void> _addTopic() async {
    final name = _topicCtrl.text.trim();
    if (name.isEmpty) return;
    await Organize.addCustomTopic(name);
    _topicCtrl.clear();
    _loadTopics();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('AI 增强（可选）',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(
              '配置后自动生成：话题归类、同义辨析、例句填空题。不配置也能用（离线规则聚类）。'
              'Key 只存本机；请求只发送单词与释义，不发个人内容。',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _presetId,
            decoration: const InputDecoration(
                labelText: '供应商', border: OutlineInputBorder()),
            items: kLlmPresets
                .map((p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
                .toList(),
            onChanged: (v) => _applyPreset(v!),
          ),
          const SizedBox(height: 4),
          Text(kLlmPresets.firstWhere((p) => p.id == _presetId).note,
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 12),
          TextField(
            controller: _baseCtrl,
            decoration: const InputDecoration(
              labelText: '接口地址（OpenAI 兼容 base_url）',
              hintText: 'https://…/v1',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Builder(builder: (context) {
            final preset = kLlmPresets.firstWhere((p) => p.id == _presetId);
            if (preset.models.isEmpty) return const SizedBox.shrink();
            final cur = _modelCtrl.text.trim();
            return Column(children: [
              DropdownButtonFormField<String>(
                initialValue:
                    preset.models.contains(cur) ? cur : null,
                decoration: const InputDecoration(
                  labelText: '模型（下拉选择）',
                  border: OutlineInputBorder(),
                ),
                hint: const Text('选择模型'),
                items: preset.models
                    .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                    .toList(),
                onChanged: (v) => setState(() => _modelCtrl.text = v!),
              ),
              const SizedBox(height: 12),
            ]);
          }),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(
              labelText: '模型名（可手动输入任意型号）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _keyCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering),
                label: const Text('测试连接'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(onPressed: _save, child: const Text('保存')),
            ),
          ]),
          if (_testMsg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_testMsg,
                  style: TextStyle(
                      fontSize: 13, color: _testOk ? kGreen : Colors.red)),
            ),
          const Divider(height: 40),
          const Text('话题组',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text('新词自动归入话题组（AI 可用则智能归类，否则按关键词规则）。',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _topics
                .map((t) => Chip(
                    label: Text(t),
                    backgroundColor: kGreen.withValues(alpha: 0.07)))
                .toList(),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _topicCtrl,
                decoration: const InputDecoration(
                  labelText: '自定义话题',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(onPressed: _addTopic, child: const Text('添加')),
          ]),
          const Divider(height: 40),
          const Text('每日整理',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(
              '每天 22:00 提醒整理；打开 App 时也会自动整理当天新词（词义群 + 话题双维聚类，生成今日词单）。',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final r = await Organize.run(force: true);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(r == 'empty'
                      ? '今天还没有新词'
                      : '整理完成${r == 'llm' ? '（AI 增强）' : ''}')));
            },
            icon: const Icon(Icons.refresh),
            label: const Text('立即整理今天的词'),
          ),
          const SizedBox(height: 32),
          Center(
              child: Text(
                  '蜗词 v1.1.0 · 距 2026-12-12 六级笔试 ${daysToExam()} 天',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]))),
        ],
      ),
    );
  }
}

// ---------------- 今日词单页 ----------------

class DailyListPage extends StatefulWidget {
  const DailyListPage({super.key});
  @override
  State<DailyListPage> createState() => _DailyListPageState();
}

class _DailyListPageState extends State<DailyListPage> {
  Map<String, List<Map<String, dynamic>>> _groups = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final raw = await DB.loadDailyList(DB.today());
    final groups = <String, List<Map<String, dynamic>>>{};
    if (raw != null) {
      try {
        final list = (json.decode(raw) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        for (final e in list) {
          final topic = (e['topic'] ?? '').toString();
          groups.putIfAbsent(topic.isEmpty ? '未分类' : topic, () => []).add(e);
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _groups = groups;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('今日词单 · ${DB.today().substring(5)}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _groups.isEmpty
              ? Center(
                  child: Text('今天还没有整理出词单\n先去「今日」页录几个生词吧',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600])))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: _groups.entries.expand((g) => [
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 8),
                          child: Text('【${g.key}】',
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: kGreen)),
                        ),
                        ...g.value.map(_wordCard),
                      ]).toList(),
                ),
    );
  }

  Widget _wordCard(Map<String, dynamic> e) {
    final word = (e['w'] ?? '') as String;
    final phonetic = (e['p'] ?? '') as String;
    final trans =
        ((e['t'] ?? '') as String).split('；').first.split(';').first;
    final group = (e['group'] ?? '') as String;
    final note = (e['note'] ?? '') as String;
    final example = (e['example'] ?? '') as String;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(word,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text(phonetic, style: TextStyle(fontSize: 13, color: Colors.grey[600])),
          ]),
          if (trans.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(trans, style: const TextStyle(fontSize: 14)),
            ),
          if (group.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('词义群：$group',
                style: const TextStyle(
                    fontSize: 13,
                    color: kGreen,
                    fontWeight: FontWeight.w600)),
          ],
          if (note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('辨析：$note',
                  style: const TextStyle(fontSize: 13, height: 1.4)),
            ),
          if (example.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(example,
                  style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      fontStyle: FontStyle.italic,
                      color: Colors.black87)),
            ),
        ]),
      ),
    );
  }
}

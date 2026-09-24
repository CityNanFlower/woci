/// 设置页 + 今日词单页 + 统计页（打卡日历 / 图表）
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'db.dart';
import 'csv_io.dart';
import 'llm.dart';
import 'main.dart' show kGreen, daysToExam, AppPrefs;
import 'organize.dart';
import 'update.dart';
import 'wordlist_page.dart';

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
  late DateTime _examDate;
  late TextEditingController _updateCtrl;
  bool _checkingUpdate = false;
  String _updateMsg = '';
  bool _updateOk = false;

  @override
  void initState() {
    super.initState();
    final s = Llm.settings;
    _presetId = s.presetId;
    _baseCtrl = TextEditingController(text: s.baseUrl);
    _modelCtrl = TextEditingController(text: s.model);
    _keyCtrl = TextEditingController(text: s.key);
    _examDate = DateTime.parse(AppPrefs.examDate);
    _updateCtrl = TextEditingController(text: Updater.sourceUrl);
    _loadTopics();
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    _topicCtrl.dispose();
    _updateCtrl.dispose();
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

  Future<void> _saveExamDate() async {
    AppPrefs.examDate =
        '${_examDate.year.toString().padLeft(4, '0')}-${_examDate.month.toString().padLeft(2, '0')}-${_examDate.day.toString().padLeft(2, '0')}';
    await AppPrefs.save();
    if (mounted) setState(() {});
  }

  Future<void> _toggleMode(String mode, bool on) async {
    var modes = [...AppPrefs.studyModes];
    if (on) {
      if (!modes.contains(mode)) modes.add(mode);
    } else {
      modes.remove(mode);
    }
    if (modes.isEmpty) modes = ['random'];
    // 按固定顺序展示
    modes.sort((a, b) =>
        AppPrefs.modeOrder.indexOf(a).compareTo(AppPrefs.modeOrder.indexOf(b)));
    AppPrefs.studyModes = modes;
    await AppPrefs.save();
    if (mounted) setState(() {});
  }

  Future<void> _exportCsv() async {
    final r = await CsvIo.exportWords();
    if (!mounted) return;
    final extra = r.reviews > 0 ? ' + ${r.reviews} 条复习记录' : '';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已导出 ${r.words} 词$extra，在分享面板选择保存位置')));
  }

  Future<void> _importCsv() async {
    final r = await CsvIo.importWords();
    if (!mounted) return;
    final msg = !r.ok
        ? (r.error == 'no_file'
            ? '已取消'
            : '文件格式不对：需要含 word 列的 CSV（可先导出一份做模板）')
        : '导入完成：新增 ${r.words} 词，恢复 ${r.reviews} 条复习记录（重复自动跳过）';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 软件更新 ----------

  Future<void> _saveUpdateSource() async {
    await Updater.saveSourceUrl(_updateCtrl.text);
    if (!mounted) return;
    setState(() {
      _updateOk = true;
      _updateMsg = Updater.configured
          ? '已保存：${Updater.resolveManifestUrl(Updater.sourceUrl)}'
          : '更新源已清空';
    });
  }

  Future<void> _checkUpdate() async {
    if (!Updater.configured && _updateCtrl.text.trim().isEmpty) {
      setState(() {
        _updateMsg = '请先填写更新源地址并保存';
        _updateOk = false;
      });
      return;
    }
    await Updater.saveSourceUrl(_updateCtrl.text);
    setState(() {
      _checkingUpdate = true;
      _updateMsg = '';
    });
    final r = await Updater.check(manual: true);
    if (!mounted) return;
    setState(() {
      _checkingUpdate = false;
      switch (r.status) {
        case UpdateStatus.upToDate:
          _updateOk = true;
          _updateMsg = '已是最新版本 v$kAppVersionName';
          break;
        case UpdateStatus.hasUpdate:
          _updateOk = true;
          _updateMsg = '发现新版本 v${r.info!.versionName}';
          break;
        case UpdateStatus.notConfigured:
          _updateOk = false;
          _updateMsg = r.message.isEmpty ? '还没有配置更新源' : r.message;
          break;
        case UpdateStatus.error:
          _updateOk = false;
          _updateMsg = r.message;
          break;
      }
    });
    if (r.status == UpdateStatus.hasUpdate) {
      await _showUpdateDialog(r.info!);
    }
  }

  Future<void> _showUpdateDialog(UpdateInfo info) async {
    final action = await showUpdatePrompt(context, info);
    if (!mounted) return;
    if (action == 'update') {
      await showUpdateDownload(context, info);
    } else if (action == 'skip') {
      setState(() {
        _updateOk = true;
        _updateMsg = '已跳过 v${info.versionName}（手动检查时仍会提示）';
      });
    }
  }

  Future<void> _installLocalApk() async {
    final files = await Updater.downloadedApks();
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('还没有下载过安装包')));
      return;
    }
    final pick = await pickLocalApk(context, files);
    if (pick == null || !mounted) return;
    final r = await Updater.install(pick);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(installResultMessage(r))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------- 学习偏好 ----------
          const Text('学习偏好（复习测验模式）',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text('可多选；多选时每个单词要完成所选模式的全部轮次才算复习过。'
                  '全对=认识，错 1 轮=模糊，错 2 轮及以上=忘了。',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 12),
          ...AppPrefs.modeOrder.map((m) => SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(AppPrefs.modeLabels[m]!,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                subtitle: Text(AppPrefs.modeDescs[m]!,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                value: AppPrefs.studyModes.contains(m),
                onChanged: (v) => _toggleMode(m, v),
              )),
          const Divider(height: 32),

          // ---------- 考试日期 ----------
          const Text('考试日期', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_outlined, color: kGreen),
            title: Text(AppPrefs.examDate),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _examDate,
                firstDate: DateTime(2024),
                lastDate: DateTime(2030),
              );
              if (picked != null) {
                _examDate = picked;
                await _saveExamDate();
              }
            },
          ),
          Text('距考试 ${daysToExam()} 天（开源默认值，按自己的考试改）',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const Divider(height: 32),

          // ---------- 数据 ----------
          const Text('数据（CSV 导入导出）',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text('导出含全部生词与复习进度；导入自动合并去重。每晚 22:00 也会在本机自动备份一份。',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _exportCsv,
                icon: const Icon(Icons.ios_share),
                label: const Text('导出 CSV'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _importCsv,
                icon: const Icon(Icons.download),
                label: const Text('导入 CSV'),
              ),
            ),
          ]),
          const Divider(height: 32),

          // ---------- AI 增强 ----------
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
                initialValue: preset.models.contains(cur) ? cur : null,
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

          // ---------- 话题组 ----------
          const Text('话题组',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text('预置话题来自六级真题高频分类；可再添加自定义话题（新词自动归类）。',
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

          // ---------- 每日整理 ----------
          const Text('每日整理',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(
              '每天 22:00 提醒整理（后台任务也会自动整理并备份）；打开 App 时同样自动整理当天新词。'
              '配了 AI 后，每次运行最多增强 60 词，剩下的会在下次运行继续补，不会漏。',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final r = await Organize.run(force: true);
              if (!mounted) return;
              final left = r.pending > 0
                  ? '，还剩 ${r.pending} 词待 AI 增强（下次启动继续补）'
                  : '';
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(r.status == 'empty'
                      ? '没有需要整理的词'
                      : '整理完成${r.enriched > 0 ? '（AI 增强 ${r.enriched} 词）' : ''}$left')));
            },
            icon: const Icon(Icons.refresh),
            label: const Text('立即整理 / 补齐 AI 增强'),
          ),
          const Divider(height: 40),

          // ---------- 软件更新 ----------
          const Text('软件更新',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(
              '下载新版本并在应用内安装。更新源填 version.json 的直链，'
              '或只填它所在的目录（会自动补 /version.json）；建议用 https。',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _updateCtrl,
                decoration: const InputDecoration(
                  labelText: '更新源地址',
                  hintText: 'https://…/version.json',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
                onPressed: _saveUpdateSource, child: const Text('保存')),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _checkingUpdate ? null : _checkUpdate,
                icon: _checkingUpdate
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.system_update_alt),
                label: const Text('检查更新'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _installLocalApk,
                icon: const Icon(Icons.folder_open),
                label: const Text('装已下载包'),
              ),
            ),
          ]),
          if (_updateMsg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_updateMsg,
                  style: TextStyle(
                      fontSize: 13, color: _updateOk ? kGreen : Colors.red)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                '当前 v$kAppVersionName（构建号 $kAppVersionCode）'
                '${Updater.lastCheck == null ? '' : '　上次检查 ${_fmtTime(Updater.lastCheck!)}'}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ),
          const SizedBox(height: 32),
          Center(
              child: Text(
                  '蜗词 v$kAppVersionName · 开源版',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]))),
        ],
      ),
    );
  }
}

/// 弹出「发现新版本」提示框；返回 'update' / 'skip' / 'later' / null
Future<String?> showUpdatePrompt(BuildContext context, UpdateInfo info) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('发现新版本 v${info.versionName}'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('当前 v$kAppVersionName（构建号 $kAppVersionCode）',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 2),
            Text(
                '最新 v${info.versionName}（构建号 ${info.versionCode}）'
                '${info.sizeText.isEmpty ? '' : '　${info.sizeText}'}'
                '${info.releaseDate.isEmpty ? '' : '　${info.releaseDate}'}',
                style: const TextStyle(fontSize: 13)),
            if (info.forced)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('此版本要求强制更新',
                    style: TextStyle(fontSize: 13, color: Colors.red)),
              ),
            if (info.changelog.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('更新内容',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 6),
              ...info.changelog.map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('· $e', style: const TextStyle(fontSize: 13)),
                  )),
            ],
          ],
        ),
      ),
      actions: [
        if (!info.forced)
          TextButton(
            onPressed: () async {
              await Updater.skipVersion(info.versionCode);
              if (ctx.mounted) Navigator.pop(ctx, 'skip');
            },
            child: const Text('跳过此版本'),
          ),
        if (!info.forced)
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'later'),
              child: const Text('稍后')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, 'update'),
            child: const Text('立即更新')),
      ],
    ),
  );
}

/// 下载并唤起系统安装器，结束后用 SnackBar 汇报结果
Future<void> showUpdateDownload(BuildContext context, UpdateInfo info) async {
  final msg = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDownloadDialog(info: info),
  );
  if (msg == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    duration: const Duration(seconds: 6),
    action: SnackBarAction(
      label: '重试安装',
      onPressed: () => retryInstallLatest(context),
    ),
  ));
}

/// 重装本地已下载的最新 APK（授权后重试用）
Future<void> retryInstallLatest(BuildContext context) async {
  final files = await Updater.downloadedApks();
  if (!context.mounted) return;
  if (files.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有找到已下载的安装包')));
    return;
  }
  final r = await Updater.install(files.first);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(installResultMessage(r))));
}

/// 从本地已下载的包中挑一个
Future<File?> pickLocalApk(BuildContext context, List<File> files) {
  return showModalBottomSheet<File>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            dense: true,
            title: Text('选择要安装的包',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ...files.map((f) {
            final st = f.statSync();
            return ListTile(
              leading: const Icon(Icons.android),
              title: Text(f.path.split('/').last),
              subtitle:
                  Text('${formatBytes(st.size)}　${_fmtTime(st.modified)}'),
              onTap: () => Navigator.pop(ctx, f),
            );
          }),
        ],
      ),
    ),
  );
}

/// 把 MethodChannel 的返回值转成给用户看的话
String installResultMessage(String r) {
  if (r == 'ok') return '已唤起系统安装器，按提示完成安装';
  if (r == 'need_permission') {
    return '已打开系统设置：请允许「蜗词」安装应用，再点「重试安装」';
  }
  if (r == 'unsupported') return '当前环境不支持应用内安装，请到下载目录手动安装';
  return '安装失败：${r.replaceFirst('error:', '')}';
}

String _fmtTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 下载进度对话框：负责下载 → 唤起安装 → 把结果文案 pop 回去
class _UpdateDownloadDialog extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateDownloadDialog({required this.info});
  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  double _p = 0;
  String _stage = '正在下载…';
  String _error = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final apk = await Updater.download(widget.info, (p) {
        if (mounted && p >= 0) setState(() => _p = p);
      });
      if (!mounted) return;
      setState(() => _stage = '正在唤起安装器…');
      final r = await Updater.install(apk);
      if (!mounted) return;
      final msg = r == 'ok'
          ? '已唤起系统安装器，按提示完成安装'
          : r == 'need_permission'
              ? '已打开系统设置：请允许「蜗词」安装应用，再点「重试安装」'
              : r == 'unsupported'
                  ? '当前环境不支持应用内安装，包已存到 ${apk.path}'
                  : '安装失败：${r.replaceFirst('error:', '')}';
      Navigator.pop(context, msg);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e'
            .replaceFirst('HttpException: ', '')
            .replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pct = (_p * 100).clamp(0, 100).toStringAsFixed(0);
    final sizeText = widget.info.size > 0
        ? '${formatBytes((widget.info.size * _p).round())} / ${widget.info.sizeText}'
        : '';
    return AlertDialog(
      title: Text('更新到 v${widget.info.versionName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error.isEmpty) ...[
            LinearProgressIndicator(value: _p <= 0 ? null : _p),
            const SizedBox(height: 12),
            Text('$_stage $pct%',
                style: const TextStyle(fontSize: 13)),
            if (sizeText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(sizeText,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ),
          ] else ...[
            const Text('下载失败',
                style: TextStyle(fontSize: 14, color: Colors.red)),
            const SizedBox(height: 6),
            Text(_error, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            Text('可检查更新源地址、网络，或换个网络环境后重试。',
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(_error.isEmpty ? '取消' : '关闭'),
        ),
      ],
    );
  }
}

// ---------------- 今日词单页 ----------------

class DailyListPage extends StatelessWidget {
  const DailyListPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: WordListPage(todayOnly: true)),
    );
  }
}

// ---------------- 统计页 ----------------

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});
  @override
  StatsPageState createState() => StatsPageState();
}

class StatsPageState extends State<StatsPage> {
  int _total = 0, _mastered = 0, _reviewedToday = 0;
  Map<String, int> _reviewByDay = {};
  Map<String, int> _createdByDay = {};
  int _streak = 0;
  int _range = 30; // 图表区间 7 / 30 天
  DateTime _calMonth = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    _total = await DB.totalCount();
    _mastered = await DB.masteredCount();
    _reviewedToday = await DB.todayReviewedCount();
    _reviewByDay = await DB.reviewCountsByDay(365);
    _createdByDay = await DB.createdCountsByDay(365);
    _streak = _calcStreak();
    if (mounted) setState(() {});
  }

  /// 连续打卡：从今天（或昨天）往前数，有复习记录即打卡
  int _calcStreak() {
    var streak = 0;
    var day = DateTime.now();
    if (!_reviewByDay.containsKey(_dayKey(day))) {
      day = day.subtract(const Duration(days: 1));
      if (!_reviewByDay.containsKey(_dayKey(day))) return 0;
    }
    while (_reviewByDay.containsKey(_dayKey(day))) {
      streak++;
      day = day.subtract(const Duration(days: 1));
    }
    return streak;
  }

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 60, 16, 24),
        children: [
          const Text('统计', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: kGreen)),
          const SizedBox(height: 16),
          _statGrid(),
          const SizedBox(height: 16),
          _calendar(),
          const SizedBox(height: 16),
          _chartCard(),
        ],
      ),
    );
  }

  Widget _statGrid() {
    return Row(children: [
      Expanded(child: _statCard('累计生词', '$_total', Icons.library_books_outlined)),
      const SizedBox(width: 10),
      Expanded(child: _statCard('长期池', '$_mastered', Icons.verified_outlined)),
    ]);
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kGreen.withValues(alpha: 0.15)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: kGreen, size: 20),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13, color: Colors.black87)),
        ]),
        const SizedBox(height: 8),
        Text(value,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.black)),
      ]),
    );
  }

  // ---------- 打卡日历 ----------

  Widget _calendar() {
    final first = DateTime(_calMonth.year, _calMonth.month, 1);
    final daysInMonth = DateTime(_calMonth.year, _calMonth.month + 1, 0).day;
    final lead = first.weekday % 7; // 周日=0
    final today = DateTime.now();
    final cells = <Widget>[];
    for (var i = 0; i < lead; i++) {
      cells.add(const SizedBox.shrink());
    }
    for (var d = 1; d <= daysInMonth; d++) {
      final date = DateTime(_calMonth.year, _calMonth.month, d);
      final key = _dayKey(date);
      final count = _reviewByDay[key] ?? 0;
      final isToday = _dayKey(today) == key;
      final isFuture = date.isAfter(today);
      cells.add(_calCell(d, count, isToday, isFuture));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('打卡日历', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(width: 8),
            Chip(
              label: Text('连续 $_streak 天',
                  style: const TextStyle(fontSize: 12, color: kGreen, fontWeight: FontWeight.w600)),
              backgroundColor: kGreen.withValues(alpha: 0.08),
              visualDensity: VisualDensity.compact,
            ),
            const Spacer(),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(() {
                _calMonth = DateTime(_calMonth.year, _calMonth.month - 1);
              }),
            ),
            Text('${_calMonth.year}.${_calMonth.month.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_right),
              onPressed: () => setState(() {
                _calMonth = DateTime(_calMonth.year, _calMonth.month + 1);
              }),
            ),
          ]),
          const SizedBox(height: 4),
          Row(children: ['日', '一', '二', '三', '四', '五', '六']
              .map((w) => Expanded(
                    child: Center(
                        child: Text(w,
                            style: TextStyle(fontSize: 11, color: Colors.grey[500]))),
                  ))
              .toList()),
          const SizedBox(height: 4),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 1.1,
            children: cells,
          ),
          const SizedBox(height: 4),
          Text('有复习记录即打卡 · 当天复习了 $_reviewedToday 词',
              style: TextStyle(fontSize: 11, color: Colors.grey[500])),
        ]),
      ),
    );
  }

  Widget _calCell(int day, int count, bool isToday, bool isFuture) {
    Color bg = Colors.transparent;
    if (count > 0) {
      bg = kGreen.withValues(alpha: (0.25 + (count.clamp(1, 10) / 10) * 0.55));
    }
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: isToday ? Border.all(color: kGreen, width: 1.5) : null,
      ),
      child: Center(
        child: Text(
          '$day',
          style: TextStyle(
            fontSize: 12,
            color: isFuture
                ? Colors.grey[350]
                : (count >= 5 ? Colors.white : Colors.black87),
            fontWeight: count > 0 || isToday ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  // ---------- 图表 ----------

  Widget _chartCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('复习趋势', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const Spacer(),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 7, label: Text('7天')),
                ButtonSegment(value: 30, label: Text('30天')),
              ],
              selected: {_range},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _range = s.first),
            ),
          ]),
          const SizedBox(height: 12),
          SizedBox(height: 140, child: CustomPaint(
            size: const Size(double.infinity, 140),
            painter: _BarChartPainter(
              reviewData: _series(_reviewByDay, _range),
              createdData: _series(_createdByDay, _range),
            ),
          )),
          const SizedBox(height: 8),
          Row(children: [
            _legend(kGreen, '每日复习次数'),
            const SizedBox(width: 16),
            _legend(Colors.amber.shade700, '每日新增生词'),
          ]),
        ]),
      ),
    );
  }

  Widget _legend(Color c, String label) => Row(children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
      ]);

  List<double> _series(Map<String, int> data, int days) {
    final out = <double>[];
    final now = DateTime.now();
    for (var i = days - 1; i >= 0; i--) {
      final d = now.subtract(Duration(days: i));
      out.add((data[_dayKey(d)] ?? 0).toDouble());
    }
    return out;
  }
}

/// 简易双系列柱状图（复习=绿，新增=琥珀），全离线自绘
class _BarChartPainter extends CustomPainter {
  final List<double> reviewData;
  final List<double> createdData;
  _BarChartPainter({required this.reviewData, required this.createdData});

  @override
  void paint(Canvas canvas, Size size) {
    const green = Color(0xFF007A43);
    const amber = Color(0xFFB57508);
    final maxVal = [
      ...reviewData.take(_lastN()),
      ...createdData.take(_lastN()),
    ].fold(1.0, (m, v) => v > m ? v : m);

    final n = _lastN();
    final chartH = size.height - 16;
    final slot = size.width / n;
    final barW = (slot - 1).clamp(1.0, n <= 7 ? 18.0 : 6.0);

    // 基线
    final baseY = chartH + 8;
    canvas.drawLine(Offset(0, baseY), Offset(size.width, baseY),
        Paint()..color = const Color(0x22000000)..strokeWidth = 1);

    for (var i = 0; i < n; i++) {
      final x = slot * i + slot / 2;
      final rv = reviewData[i];
      final cv = createdData[i];
      if (rv > 0) {
        final h = (rv / maxVal) * chartH;
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(x - barW - 1, baseY - h, barW, h),
                const Radius.circular(2)),
            Paint()..color = green);
      }
      if (cv > 0) {
        final h = (cv / maxVal) * chartH;
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(x + 1, baseY - h, barW, h),
                const Radius.circular(2)),
            Paint()..color = amber);
      }
    }
  }

  int _lastN() => reviewData.length;

  @override
  bool shouldRepaint(covariant _BarChartPainter old) =>
      old.reviewData != reviewData || old.createdData != createdData;
}

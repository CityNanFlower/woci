/// LLM 服务层：OpenAI 兼容 chat/completions，多厂商预设
/// key 只存本机 SharedPreferences；只发送单词与义项，不发送个人内容
library;

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class LlmPreset {
  final String id;
  final String name;
  final String baseUrl;
  final String defaultModel;
  final List<String> models;
  final String note;
  const LlmPreset(this.id, this.name, this.baseUrl, this.defaultModel,
      this.models, this.note);
}

/// 预设供应商（均为 OpenAI 兼容接口）
const kLlmPresets = [
  LlmPreset('deepseek', 'DeepSeek', 'https://api.deepseek.com/v1',
      'deepseek-flash', ['deepseek-flash', 'deepseek-v4-pro'],
      '性价比高，国内直连'),
  LlmPreset('zhipu', '智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4',
      'GLM-5.3-Flash',
      ['GLM-4-Flash-250414', 'GLM-4.7-Flash', 'GLM-4.6V-Flash',
       'GLM-5.3-Flash', 'GLM-5.3-FlashX', 'GLM-5.3'],
      'Flash 系列更便宜，定价见 open.bigmodel.cn/pricing'),
  LlmPreset('volc', '火山方舟（豆包）', 'https://ark.cn-beijing.volces.com/api/v3',
      'doubao-seed-2-1-turbo-260628',
      ['doubao-seed-2-1-turbo-260628', 'doubao-seed-2-1-pro-260628'],
      '也可填推理接入点 ep-xxx'),
  LlmPreset('aliyun', '阿里云百炼（千问）',
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
      'qwen3.8-flash', ['qwen3.8-flash', 'qwen3.8-max-0902'],
      '新用户有免费额度'),
  LlmPreset('kimi', 'Kimi（月之暗面）', 'https://api.moonshot.cn/v1',
      'kimi-k2.6', ['kimi-k2.6', 'kimi-k3'],
      '国内直连'),
  LlmPreset('tencent', '腾讯云 TokenHub（混元）',
      'https://tokenhub.tencentmaas.com/v1',
      'hy4-preview',
      ['hy4-preview', 'hy3', 'hunyuan-role-latest', 'hy-role',
       'hy-vision-2.0-instruct'],
      '国内直连'),
  LlmPreset('minimax', 'MiniMax', 'https://api.minimaxi.com/v1',
      'MiniMax-M2.7',
      ['MiniMax-M2.7', 'MiniMax-M2.7-highspeed', 'MiniMax-M3'],
      'highspeed 版响应更快'),
  LlmPreset('gemini', 'Gemini（谷歌）',
      'https://generativelanguage.googleapis.com/v1beta/openai',
      'gemini-3.8-flash', ['gemini-3.8-flash', 'gemini-3.1-pro'],
      '需国际网络环境'),
  LlmPreset('openai', 'OpenAI', 'https://api.openai.com/v1',
      'gpt-5.6-luna', ['gpt-5.6-luna', 'gpt-6-astra'],
      '需国际网络环境'),
  LlmPreset('custom', '自定义', '', '', [], '任意 OpenAI 兼容接口'),
];

class LlmSettings {
  String presetId;
  String baseUrl;
  String model;
  String key;
  LlmSettings(
      {this.presetId = 'deepseek',
      this.baseUrl = '',
      this.model = '',
      this.key = ''});
}

class Llm {
  static LlmSettings _s = LlmSettings();

  /// 最近一次 chat 失败的原因（成功时清空），供测试连接等场景展示
  static String? lastError;

  static LlmSettings get settings => _s;
  static bool get configured => _s.key.isNotEmpty && _s.baseUrl.isNotEmpty;

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    _s = LlmSettings(
      presetId: sp.getString('llm_preset') ?? 'deepseek',
      baseUrl: sp.getString('llm_base') ?? '',
      model: sp.getString('llm_model') ?? '',
      key: sp.getString('llm_key') ?? '',
    );
  }

  static Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('llm_preset', _s.presetId);
    await sp.setString('llm_base', _s.baseUrl);
    await sp.setString('llm_model', _s.model);
    await sp.setString('llm_key', _s.key);
  }

  /// 基础对话；返回 assistant 内容，失败返回 null
  static Future<String?> chat(String system, String user,
      {int maxTokens = 1500, Duration timeout = const Duration(seconds: 40)}) async {
    if (!configured) return null;
    try {
      final url = Uri.parse('${_s.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
      final resp = await http
          .post(url,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${_s.key}',
              },
              body: json.encode({
                'model': _s.model,
                'messages': [
                  {'role': 'system', 'content': system},
                  {'role': 'user', 'content': user},
                ],
                'temperature': 0.3,
                'max_tokens': maxTokens,
              }))
          .timeout(timeout);
      if (resp.statusCode != 200) {
        final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
        lastError = 'HTTP ${resp.statusCode}'
            '${body.isEmpty ? '' : '：${_snippet(body)}'}';
        return null;
      }
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final content = data['choices']?[0]?['message']?['content'];
      if (content is String && content.isNotEmpty) {
        lastError = null;
        return content;
      }
      lastError = '响应里没有内容（模型可能返回了思考/空回复）';
      return null;
    } catch (e) {
      lastError = e.toString().replaceFirst('Exception: ', '');
      return null;
    }
  }

  /// 错误正文截短，避免弹窗塞满
  static String _snippet(String body) {
    final one = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 120 ? '${one.substring(0, 120)}…' : one;
  }

  /// 测试连接：返回 null=成功，否则错误信息（带具体原因）
  static Future<String?> testConnection() async {
    if (_s.key.isEmpty) return '请先填写 API Key';
    if (_s.baseUrl.isEmpty || _s.model.isEmpty) return '请填写接口地址与模型名';
    final r = await chat('You are a ping helper.', '回复"OK"两个字母即可',
        maxTokens: 8, timeout: const Duration(seconds: 15));
    return r == null ? '连接失败：${lastError ?? "未知错误"}' : null;
  }
}

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
      'deepseek-chat', ['deepseek-chat', 'deepseek-reasoner'],
      '性价比高，国内直连'),
  LlmPreset('zhipu', '智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4',
      'glm-4-flash', ['glm-4-flash', 'glm-4-air', 'glm-4-plus'],
      'glm-4-flash 免费'),
  LlmPreset('volc', '火山方舟（豆包）', 'https://ark.cn-beijing.volces.com/api/v3',
      'doubao-1-5-lite-32k-250115',
      ['doubao-1-5-lite-32k-250115', 'doubao-1-5-pro-32k-250115'],
      '也可填推理接入点 ep-xxx'),
  LlmPreset('aliyun', '阿里云百炼（千问）',
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
      'qwen-turbo', ['qwen-turbo', 'qwen-plus', 'qwen-max'],
      '新用户有免费额度'),
  LlmPreset('openai', 'OpenAI', 'https://api.openai.com/v1',
      'gpt-4o-mini', ['gpt-4o-mini', 'gpt-4o'],
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
      if (resp.statusCode != 200) return null;
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final content = data['choices']?[0]?['message']?['content'];
      return content is String && content.isNotEmpty ? content : null;
    } catch (_) {
      return null;
    }
  }

  /// 测试连接：返回 null=成功，否则错误信息
  static Future<String?> testConnection() async {
    if (_s.key.isEmpty) return '请先填写 API Key';
    if (_s.baseUrl.isEmpty || _s.model.isEmpty) return '请填写接口地址与模型名';
    final r = await chat('You are a ping helper.', '回复"OK"两个字母即可',
        maxTokens: 8, timeout: const Duration(seconds: 15));
    return r == null ? '连接失败：检查 Key / 地址 / 模型名 / 网络' : null;
  }
}

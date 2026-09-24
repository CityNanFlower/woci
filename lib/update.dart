/// 应用内更新：检查新版本 → 下载 APK → 唤起系统安装器
///
/// 内置官方更新源（GitHub Release 的 version.json），无需用户手填；
/// 用户仍可在「设置 → 软件更新」改成自己的地址。
/// GitHub 直连在国内不稳，清单与 APK 下载失败时会自动依次尝试
/// 内置的加速镜像（gh-proxy 风格：镜像前缀 + 完整原始 URL），并记住本次成功的镜像。
///
/// 全程零新增第三方依赖：http（请求/下载）+ path_provider（落盘）+ shared_preferences（配置）
/// + 自建 MethodChannel（安装）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 当前版本 —— ⚠ 发版时必须与 pubspec.yaml 的 `version:` 同步（格式 主.次.修订+构建号）
const String kAppVersionName = '1.2.3';
const int kAppVersionCode = 7;

/// 内置官方更新源（本仓库 Release 的最新清单），应用首次启动即生效
const String kDefaultUpdateSource =
    'https://github.com/CityNanFlower/woci/releases/latest/download/version.json';

/// GitHub 加速镜像（gh-proxy 风格：前缀 + 完整原始 URL）。
/// 直连失败时按顺序尝试；均为公共服务，失效会自动跳过换下一个。
const List<String> kGithubMirrors = [
  'https://gh-proxy.com/',
  'https://ghfast.top/',
  'https://gh.ddlc.top/',
  'https://ghproxy.net/',
];

/// 判断是否 GitHub 系直链（只有这类地址才需要镜像加速）
bool isGithubUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return host == 'github.com' ||
      host.endsWith('.github.com') ||
      host.endsWith('.githubusercontent.com');
}

/// 生成一条 URL 的候选列表：原地址在前（尊重自建源），GitHub 直链后面跟各镜像
List<String> candidatesFor(String url, {String? preferredMirror}) {
  final list = <String>[url];
  if (isGithubUrl(url)) {
    final mirrors = [...kGithubMirrors];
    if (preferredMirror != null && mirrors.contains(preferredMirror)) {
      mirrors
        ..remove(preferredMirror)
        ..insert(0, preferredMirror);
    }
    for (final m in mirrors) {
      list.add('$m$url');
    }
  }
  return list;
}

/// 与 Android 端 MainActivity 约定的通道名
const MethodChannel kUpdateChannel = MethodChannel('com.shanqiu.wo_ci/update');

// ---------------------------------------------------------------- 工具

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// 人类可读的体积
String formatBytes(int b) {
  if (b <= 0) return '未知大小';
  if (b >= 1073741824) return '${(b / 1073741824).toStringAsFixed(2)} GB';
  if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(2)} MB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '$b B';
}

// ---------------------------------------------------------------- 模型

/// 更新清单（version.json）的解析结果
class UpdateInfo {
  final String versionName;
  final int versionCode;
  final String apkUrl;
  final int size;
  final String sha1;
  final String releaseDate;
  final int minVersionCode;
  final List<String> changelog;

  const UpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    this.size = 0,
    this.sha1 = '',
    this.releaseDate = '',
    this.minVersionCode = 0,
    this.changelog = const [],
  });

  /// 解析失败返回 null（缺少 versionCode 或 apkUrl 视为非法清单）
  static UpdateInfo? tryParse(Map<String, dynamic> m) {
    final code = _asInt(m['versionCode'] ?? m['version_code']);
    final url = (m['apkUrl'] ?? m['apk_url'] ?? '').toString().trim();
    if (code == null || code <= 0 || url.isEmpty) return null;
    final raw = m['changelog'];
    return UpdateInfo(
      versionName:
          (m['versionName'] ?? m['version_name'] ?? code.toString()).toString(),
      versionCode: code,
      apkUrl: url,
      size: _asInt(m['size']) ?? 0,
      sha1: (m['sha1'] ?? '').toString(),
      releaseDate: (m['releaseDate'] ?? m['release_date'] ?? '').toString(),
      minVersionCode: _asInt(m['minVersionCode'] ?? m['min_version_code']) ?? 0,
      changelog: raw is List
          ? raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
          : const <String>[],
    );
  }

  /// 当前版本低于清单要求的最低版本 ⇒ 强制更新
  bool get forced => minVersionCode > kAppVersionCode;

  String get sizeText => size > 0 ? formatBytes(size) : '';
}

enum UpdateStatus {
  /// 已是最新
  upToDate,

  /// 发现新版本
  hasUpdate,

  /// 用户还没填更新源
  notConfigured,

  /// 网络/解析出错
  error,
}

class UpdateCheckResult {
  final UpdateStatus status;
  final UpdateInfo? info;
  final String message;

  const UpdateCheckResult(this.status, {this.info, this.message = ''});

  bool get hasError => status == UpdateStatus.error;
}

// ---------------------------------------------------------------- 主逻辑

class Updater {
  static const _kUrl = 'update_source_url';
  static const _kSkip = 'update_skipped_code';
  static const _kLastCheck = 'update_last_check_ms';

  /// 更新源（用户配置；为空时自动用内置官方源）
  static String sourceUrl = '';

  /// 用户主动「跳过此版本」的 versionCode
  static int skippedCode = 0;

  /// 上次检查时间
  static DateTime? lastCheck;

  /// 本次会话里最近一次成功的镜像前缀（加速清单成功后，下载 APK 优先复用）
  static String? lastGoodMirror;

  static bool get configured => sourceUrl.trim().isNotEmpty;

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    sourceUrl = sp.getString(_kUrl) ?? '';
    // 没配置过 ⇒ 直接用内置官方源，开箱即用
    if (sourceUrl.trim().isEmpty) sourceUrl = kDefaultUpdateSource;
    skippedCode = sp.getInt(_kSkip) ?? 0;
    final ms = sp.getInt(_kLastCheck);
    lastCheck = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<void> saveSourceUrl(String url) async {
    sourceUrl = url.trim();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kUrl, sourceUrl);
  }

  static Future<void> skipVersion(int code) async {
    skippedCode = code;
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kSkip, code);
  }

  static Future<void> clearSkip() async {
    skippedCode = 0;
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kSkip);
  }

  /// 把用户填的地址规范化成 version.json 的直链
  static String resolveManifestUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return '';
    if (!u.toLowerCase().endsWith('.json')) {
      if (!u.endsWith('/')) u = '$u/';
      u = '${u}version.json';
    }
    return u;
  }

  /// 检查更新：直连优先，失败自动切镜像。
  /// [manual] = 用户手动点击（此时忽略「跳过此版本」）
  static Future<UpdateCheckResult> check({bool manual = false}) async {
    if (!configured) {
      return const UpdateCheckResult(UpdateStatus.notConfigured,
          message: '还没有配置更新源地址');
    }
    final manifest = resolveManifestUrl(sourceUrl);
    final candidates = candidatesFor(manifest, preferredMirror: lastGoodMirror);
    Object? lastErr;
    for (final url in candidates) {
      try {
        final resp = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 12));
        if (resp.statusCode != 200) {
          lastErr = '服务器返回 HTTP ${resp.statusCode}';
          continue;
        }
        final decoded = json.decode(utf8.decode(resp.bodyBytes));
        if (decoded is! Map<String, dynamic>) {
          return const UpdateCheckResult(UpdateStatus.error,
              message: '清单格式不对：需要一个 JSON 对象');
        }
        final info = UpdateInfo.tryParse(decoded);
        if (info == null) {
          return const UpdateCheckResult(UpdateStatus.error,
              message: '清单缺少 versionCode 或 apkUrl 字段');
        }
        // 记住这次走通的镜像（原地址直连成功时清掉）
        lastGoodMirror = url == manifest ? null : _mirrorPrefixOf(url, manifest);

        await _touchLastCheck();

        if (info.versionCode <= kAppVersionCode) {
          return UpdateCheckResult(UpdateStatus.upToDate, info: info);
        }
        if (!manual && !info.forced && info.versionCode == skippedCode) {
          return UpdateCheckResult(UpdateStatus.upToDate, info: info);
        }
        return UpdateCheckResult(UpdateStatus.hasUpdate, info: info);
      } on TimeoutException {
        lastErr = '请求超时';
      } on FormatException {
        return const UpdateCheckResult(UpdateStatus.error,
            message: '清单不是合法 JSON');
      } catch (e) {
        lastErr = e;
      }
    }
    final where = isGithubUrl(manifest) ? '（GitHub 直连与镜像都失败了）' : '';
    return UpdateCheckResult(UpdateStatus.error,
        message: '检查失败：$lastErr$where');
  }

  /// 从镜像候选 URL 反推它用的前缀（原 URL 之前的部分）
  static String? _mirrorPrefixOf(String candidate, String origin) {
    if (candidate.length <= origin.length) return null;
    if (!candidate.endsWith(origin)) return null;
    return candidate.substring(0, candidate.length - origin.length);
  }

  static Future<void> _touchLastCheck() async {
    lastCheck = DateTime.now();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kLastCheck, lastCheck!.millisecondsSinceEpoch);
  }

  /// 下载目录：优先外部私有目录（用户可见），失败则退回内部目录
  static Future<Directory> updateDir() async {
    Directory? base;
    try {
      base = await getExternalStorageDirectory();
    } catch (_) {
      base = null;
    }
    base ??= await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/updates');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 下载 APK，[onProgress] 回调 0~1（总长未知时为 null 参数则传 -1）。
  /// 直连失败（超时 / 非 200 / 断流 / 校验不过）自动切换到下一个镜像重试。
  static Future<File> download(
    UpdateInfo info,
    void Function(double progress) onProgress, {
    bool Function()? isCancelled,
  }) async {
    final candidates =
        candidatesFor(info.apkUrl, preferredMirror: lastGoodMirror);
    Object? lastErr;
    for (final url in candidates) {
      try {
        final f = await _downloadOne(
          url,
          info,
          onProgress,
          isCancelled: isCancelled,
        );
        lastGoodMirror = url == info.apkUrl
            ? null
            : _mirrorPrefixOf(url, info.apkUrl);
        return f;
      } catch (e) {
        if (isCancelled != null && isCancelled()) rethrow;
        lastErr = e;
      }
    }
    final where =
        isGithubUrl(info.apkUrl) ? '（直连与全部镜像均失败）' : '';
    throw HttpException('下载失败：$lastErr$where', uri: Uri.parse(info.apkUrl));
  }

  /// 按单一 URL 完成一次完整下载（含大小与 ZIP 头校验）
  static Future<File> _downloadOne(
    String url,
    UpdateInfo info,
    void Function(double progress) onProgress, {
    bool Function()? isCancelled,
  }) async {
    final client = http.Client();
    File? failedTarget;
    IOSink? sink;
    try {
      final req = http.Request('GET', Uri.parse(url));
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}', uri: resp.request?.url);
      }

      final dir = await updateDir();
      final target = File('${dir.path}/${_apkName(info)}');
      failedTarget = target;
      if (await target.exists()) await target.delete();
      sink = target.openWrite();

      final total = resp.contentLength ?? info.size;
      var received = 0;
      await for (final chunk in resp.stream) {
        if (isCancelled != null && isCancelled()) {
          throw const HttpException('已取消');
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress(total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : -1.0);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      // 完整性自检：大小 + ZIP 魔数（APK 是 zip 容器）
      final len = await target.length();
      if (info.size > 0 && len != info.size) {
        throw HttpException('文件不完整：期望 ${info.size} 字节，实际 $len 字节');
      }
      final raf = await target.open();
      final head = await raf.read(4);
      await raf.close();
      if (head.length < 4 || head[0] != 0x50 || head[1] != 0x4B) {
        throw const HttpException('下载内容不是有效的 APK（ZIP 头缺失）');
      }
      onProgress(1.0);
      failedTarget = null;
      return target;
    } catch (e) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      final t = failedTarget;
      if (t != null) {
        try {
          if (await t.exists()) await t.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  static String _apkName(UpdateInfo info) {
    final safe = info.versionName.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '');
    return 'woci-v${safe.isEmpty ? info.versionCode : safe}.apk';
  }

  /// 唤起系统安装器。返回 'ok' / 'need_permission' / 'unsupported' / 'error:xxx'
  static Future<String> install(File apk) async {
    try {
      final r = await kUpdateChannel
          .invokeMethod<String>('installApk', {'path': apk.path});
      return r ?? 'ok';
    } on MissingPluginException {
      return 'unsupported';
    } on PlatformException catch (e) {
      return 'error:${e.message ?? e.code}';
    } catch (e) {
      return 'error:$e';
    }
  }

  /// 已下载到本地的 APK 列表（用于「安装已下载包」）
  static Future<List<File>> downloadedApks() async {
    try {
      final dir = await updateDir();
      final files = await dir
          .list()
          .where((e) => e is File && e.path.toLowerCase().endsWith('.apk'))
          .cast<File>()
          .toList();
      files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      return files;
    } catch (_) {
      return const [];
    }
  }
}

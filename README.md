# 蜗词 WoCi

一款专注「生词本 + 科学复习」的英语学习 App，为四六级 / 考研备考设计。Flutter 构建，全功能离线可用。

## 功能

- **生词录入**：输入单词自动匹配音标、释义（内置词典），支持来源选填
- **智能整理**：AI（可选，支持任意 OpenAI 兼容接口）或离线关键词规则，自动完成话题分类与同义词义群聚类
- **三轴分类**：生词本与今日词单共用 话题 / 词义群 / 来源 三条分类轴，胶囊切换、点击即筛
- **艾宾浩斯复习**：0/1/2/4/7/15/30 天七轮间隔调度，到期自动进入今日词单
- **多模式测验**：随机四选一 / 词义群辨析 / 话题联想 / 全键盘拼写，可在设置中多选组合为多轮制
- **词书系统**：内置四级 / 六级 / 考研词书（分层去重），支持检索浏览、勾选加入生词本，支持导入 txt / csv / json 自定义词书
- **CSV 备份**：全量生词（含复习进度）导出分享 / 导入合并去重
- **后台任务**：每日 22:00 自动整理 + 自动 CSV 本地备份（保留最近 7 份）
- **统计与打卡**：月历打卡、连续天数、近 7/30 日复习量柱状图、词汇量累计曲线
- **应用内更新**：启动静默检查 + 设置页手动检查，可自定义更新源，发现新版本后在 App 内下载并唤起系统安装器

## 数据来源与致谢

- 查询词典基于 [ECDICT](https://github.com/skywind3000/ECDICT)（MIT License）筛选构建
- 内置词书词表来自 [KyleBing/english-vocabulary](https://github.com/KyleBing/english-vocabulary)，仅收录单词列表，释义由内置词典实时查询

## 构建

```bash
# 1) 首次（或 pub 缓存被清理后）先修补插件源码，见下方"已知构建问题"
python tool/patch_pub_cache.py

# 2) 构建
flutter build apk --release
```

环境要求：Flutter 3.x、Android SDK（compileSdk 36 平台需已安装）。国内网络建议设置：

```
FLUTTER_STORAGE_BASE_PATH=https://storage.flutter-io.cn
PUB_HOSTED_URL=https://pub.flutter-io.cn
```

### 已知构建问题

1. **file_picker 的 compileSdk 过低**：`file_picker 8.3.7` 在
   `android/build.gradle` 里硬编码 `compileSdk 34`，而依赖链中的
   `flutter_plugin_android_lifecycle` 要求 `compileSdk >= 36`，AGP 会报
   `:file_picker is currently compiled against android-34`。
   AGP 9 已不允许在 `subprojects`/`afterEvaluate` 里覆盖插件 compileSdk，
   因此用 `tool/patch_pub_cache.py` 修补 pub 缓存中的插件源码（幂等，可重复执行；
   `flutter pub get` 不会重新解压已缓存版本，故修补后长期有效）。
   彻底解法是升级 `file_picker` 到 13.x（联邦插件重写，API 有破坏性变更）。

2. **Windows Defender 与 Gradle 锁文件冲突**：Defender 病毒库
   `1.459.343.0`（2026-09-23 起）会拦截 Gradle 在
   `caches/<ver>/transforms/*/**.lock` 上的创建/加锁，报
   `FileNotFoundException ... (拒绝访问)`，失败任务在构建过程中随机漂移。
   排除项（目录 `D:\dev`、`D:\WoCi`、`D:\Android Studio`、`%TEMP%`，
   进程 `jbr\bin\java.exe`、`dart-sdk\bin\dart.exe`，见
   `D:\dev\add-defender-exclusion.bat`）可缓解，但**最稳妥的构建方式是
   串行 + 不使用 daemon**：

   ```bash
   GRADLE_OPTS='-Dorg.gradle.daemon=false -Dorg.gradle.parallel=false -Dorg.gradle.workers.max=1' \
     flutter build apk --release
   ```

## 发布新版本 / 应用内更新

App 的「设置 → 软件更新」里填一个 `version.json` 的直链即可（也可只填所在目录，会自动补
`/version.json`；建议用 https，也兼容 http）。

清单字段：

- `versionCode`（必填，整数）：**只有大于 App 当前构建号**才会提示更新
- `apkUrl`（必填）：APK 直链
- `versionName`：展示用版本号，如 `1.2.2`
- `size`：字节数，用于下载后校验完整性（填 0 则跳过）
- `sha1`：仅作人工核对，App 不强制校验
- `minVersionCode`：低于它的旧版本会看到「强制更新」（不显示「稍后 / 跳过此版本」）
- `changelog`：字符串数组，显示在更新弹窗里
- `releaseDate`：展示用日期

发布流程：

1. 改 `pubspec.yaml` 的 `version:`（同时把 `lib/update.dart` 里的
   `kAppVersionName` / `kAppVersionCode` 改成一致 —— 这是 App 侧比较版本的依据）
2. 构建 APK，把产物放进 `release/apk/`
3. 上传 APK 到你的分发位置（对象存储 / GitHub Release / 自建服务器均可）
4. `python release/gen-version-json.py --url <你的APK直链>` 生成 `release/version.json`
5. 把 `version.json` 上传到与 APK 同目录，把该地址填进 App 的设置页

## License

[MIT](LICENSE)

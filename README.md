# Readle

原生 iOS 电子书点读翻译 App，支持中文 → 英文、英文 → 中文。SwiftUI + UIKit，最低 iOS 18，支持 iPhone 和 iPad。MOBI 使用内嵌的 libmobi 原生解析源码；没有设置页。

## 使用

1. 打开 Readle，点击“导入电子书”，从系统“文件”选择 EPUB、MOBI、TXT 或文字型 PDF。
2. 长按正文选中句子，再点“翻译”。App 自动判断中英方向，译文显示在原句正下方。
3. 轻点正文中的单词或中文词语，查看行内语境释义。
4. 译文自动缓存，退出后恢复上次点读的位置。

也可以在 Safari 下载项、微信文件等支持文件分享的 App 中，打开电子书的分享菜单，选择 Readle（或“导入 Readle”）。第一次没有看到时，向左滑动分享 App 一行，点“更多”查找。看到“已加入导入队列”后点“完成”，打开 Readle 即可自动导入并进入阅读。请分享下载后的文件；网页链接不能当作电子书导入。

分享入口一次接收一本 50 MB 以内的 EPUB、MOBI、TXT 或 PDF。文件先存入 App Group 的共享收件箱，在主 App 内解析，导入成功后删除共享临时文件；保存失败时保留文件以便下次打开重试。不会迁移或清空已有书架。

阅读页右上角可调整字号、打开章节目录。译文支持复制和文字选择。书架长按书籍可删除书籍、阅读记录及译文；原文件不受影响。自带一篇可直接体验的中文阅读示例。

点阅读页空白处可显示或隐藏顶部书名、工具栏和底部进度；停止操作约 3 秒自动隐藏，工具栏显隐不会推动正文。滚动位置与上次翻译的句子分开保存，返回书架或切到后台时立即提交；重新打开可恢复到章节内原来的屏幕位置。旧版本阅读记录和译文缓存继续可用。

## 版本与购买

普通版使用带搜索的平面书架，可导入 100 本书。每次成功生成的离线 Qwen 句子译文或词义共用同一份 100 次额度。额度保存在本机，已缓存的译文和词义可继续查看。自带示例不计入导入数量。

高级版解锁立体书架、入书动画、影院模式、听书、无限导入和不限次数的离线 Qwen 翻译与查词。订阅到期后，已导入的书都能继续阅读，普通版沿用此前剩余的免费次数。书架右上角的“高级版”可购买或恢复。

| 方案 | 中国大陆 | 美国 | 商品 ID |
| --- | --- | --- | --- |
| 月度 | ¥18 | $2.99 | `com.linfanbin.readle.pro.monthly` |
| 年度 | ¥98 | $19.99 | `com.linfanbin.readle.pro.yearly` |
| 终身 | ¥198 | $39.99 | `com.linfanbin.readle.pro.lifetime` |

Xcode 的 Readle scheme 默认使用 `Readle-CN.storekit`，测试美国商店可切换到 `Readle-US.storekit`。正式发售须在 App Store Connect 配置相同商品 ID 和各地区价格。月度与年度属于同一订阅组，年度为符合条件的账户提供 3 天免费试用。终身为非消耗型购买。界面显示当前商店提供的本地价格。

## 文件支持

- EPUB：读取 OPF 书名、作者和 spine 阅读顺序；支持标准 XHTML 正文、Stored/Deflate ZIP。
- MOBI：支持未加密的 PalmDOC、HUFF/CDIC 压缩，以及 MOBI/KF8 混合版本；读取书名、作者和正文，兼容旧 HTML 标签。DRM 加密书籍会显示说明。
- TXT：支持 UTF-8、带 BOM 的 UTF-16、GB18030。
- PDF：提取可选择的文字，按页组织。扫描版和加密文件暂不支持。
- 单文件最多 50 MB，提取文字最多 500 万字符。长章节分段显示，避免一次创建整本书的界面。

书籍在设备本地解析并保存。句子翻译和语境查词都在设备上运行，已缓存的结果直接显示。

## 按句与单词朗读

长按选中句子后，可点“朗读原句”或“从这里听”。

英文使用 **Kokoro Heart（af_heart，美式女声）**，首次点播确认后下载约 150 MB，安装后约占 122 MB，此后离线生成声音。只保留 Heart 的声音向量，没有安装完整 VoiceStudio，没有下载其他语音模型，也不缓存整本书的音频。生成音频仅在内存中播放。中文使用设备已有的系统中文声音，界面和无障碍标签明确区分；未安装中文声音时显示说明，不冒充 Heart。

模型固定在 `csukuangfj/kokoro-int8-multi-lang-v1_0` 的 `57adb37fc0e8d4bd430cfc1b8f8c2294945b9af2`；下载验证每个文件的大小和 SHA256，启动合成前再次校验。原始声音库的 speaker 3 为 af_heart，仅保留该向量后将 ONNX 的 `n_speakers` 元数据由 54 改为 1，图权重不变；派生模型也使用固定 SHA256 校验。English 发音前端保留必要 eSpeak 数据，支持不在词典中的单词。下载可停止，已完整校验的文件可复用；不保留完整多声音库，不上传阅读文本给语音服务。

原生运行库仅为 sherpa-onnx 1.13.8 和 ONNX Runtime 1.28.1 的 iOS 静态框架，下载校验锁定在本地 Swift Package 清单中。运行库、模型、发音前端的版权许可和对应源码地址随包保存在 `Readle/Resources/SpeechNotices.txt`。未复制 VoiceStudio App 源码。

官方资料：[Kokoro 声音映射](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html)、[VoiceStudio iOS 的引擎说明](https://github.com/debpalash/VoiceStudio/blob/main/mobile/ios/README.md)。

## 模型

中英翻译和语境查词使用内置的 Qwen3.5-0.8B 4-bit，由 MLX 在 iPhone 上运行。模型移除了视觉权重并裁剪了词表，首次翻译时加载，生成时关闭 thinking。使用时无需联网、下载模型或配置密钥。

模型基于 [mlx-community/Qwen3.5-0.8B-4bit](https://huggingface.co/mlx-community/Qwen3.5-0.8B-4bit)。从固定版本重建内置资源可运行 `python3 scripts/trim-qwen-translation.py <原始模型目录> <新目录>`，需要 Python 3.12+、`mlx` 和 `tokenizers`。

## 打开项目

公开仓库包含应用源码和版权说明。构建前，把本机句读院项目中的 `Readle/Resources/KokoroHeart` 与 `Readle/Resources/QwenTranslation` 资源目录复制到克隆后的对应位置。两个目录包含 App 打包所需的离线模型。

用 Xcode 打开 `Readle.xcodeproj`，选择 `Readle` scheme。构建时 Xcode 会获取 Swift 依赖和 iOS 语音运行时。请在 iPhone 上验证 MLX 离线推理。

## 验证

核心导入、分句、持久化、翻译提示和取消测试：

```sh
bash scripts/test-core.sh
```

测试在独立临时目录中运行，退出时自动清理编译文件和电子书测试文件。界面测试位于 `Tests/ReadleUITests.swift`，可在 Xcode Test 中运行。新增双向翻译与查词交互用 `python3 scripts/reader-fixture.py <已有模拟器 UDID> --bilingual` 准备固定缓存样本，再运行 `testBilingualSentenceAndWordUX`，结束后用相同参数加 `--remove` 清理。系统文件导入测试需要在模拟器的 Readle Documents 中放置名为 `Readle导入验证.txt` 的中文测试文件；分享测试使用 `Readle分享验证.txt`，首句为“我们沿着河岸慢慢向前走。”。

分享的格式测试另需 `ReadleEPUB分享验证.epub`（OPF 书名同文件名，章节标题“正文”，正文“我们沿着河岸慢慢向前走。”）和 `ReadlePDF分享验证.pdf`（可选择文字，内容含 river）。这两个测试分别覆盖主 App 在后台时接收 EPUB、冷启动接收 PDF。

MOBI 分享测试用 `python3 scripts/mobi-fixtures.py <临时目录>` 生成 `ReadleMOBI分享验证.mobi`，放入模拟器 Readle Documents 后运行 `testShareMOBIFromFilesAndTranslate`。解析库固定版本和许可证位于 `Readle/Vendor/libmobi`。测试书籍无需保留在项目内。

定位和沉浸测试用 `python3 scripts/reader-fixture.py <已有模拟器 UDID>` 放入长章节样本；加 `--inline` 可另安装译文排版样本，用于 `testTranslationStaysBelowSelectedSentenceAndRestoresContinuation`；结束后用相同参数加 `--remove` 清理。运行 `testScrollPositionRestoresWithoutTranslation`、`testImmersionBlankTapAndAutoHideKeepPosition` 和 `testImmersiveSentenceTapStillTranslates`。结束后加 `--remove` 清理测试书籍；脚本只接受模拟器容器。

2026-10-10 验证：iOS 模拟器编译通过；32 项核心检查通过（含一次真实 DeepSeek 请求）；4 个界面流程分别通过，覆盖点句翻译及缓存恢复、快速切句、章节和字号操作、系统文件选择 → TXT 导入 → 英文翻译。检查了实际阅读界面截图。

功能测试在已有的 iPhone 17 Pro / iOS 26.5 模拟器完成。随后按用户请求，使用开发签名将 Readle 1.0（Build 1）安装到 iPhone 15 Pro「国服猪脚亮」/ iOS 26.6；已验证代码签名、设备许可、安装版本以及 App 运行进程，未再进行真机翻译交互测试。

同日分享入口更新：38 项离线核心检查通过；实际系统分享的 TXT、EPUB、PDF 流程分别通过，覆盖共享扩展保存、自动解析及临时文件清理、冷启动与返回前台接收，TXT 另验证了真实中文 → 英文点句翻译。Readle 1.0（Build 2）及分享扩展已完成开发签名、共享权限核验，并更新安装到上述 iPhone，核验安装版本及运行进程；分享功能交互测试仍仅在模拟器完成。

同日 MOBI 更新：53 项核心检查通过，包含中文 PalmDOC、未压缩文字、CP1252、损坏和加密文件，以及 5 份临时下载的真实 libmobi 样本（HUFF/CDIC、MOBI/KF8 混合版本、纯 KF8）。已有模拟器上的 MOBI 系统分享 → 自动导入 → 真实中文到英文点句翻译，以及文件选择器 → MOBI 导入两个界面流程通过，检查了阅读截图和共享临时文件清理。Readle 1.0（Build 3）及分享扩展签名通过，已更新安装至上述 iPhone，并核验安装版本和启动进程；没有在真机进行功能交互测试。

同日阅读体验修复：50 项离线核心检查通过，包含段落内滚动位置持久化、旧版阅读记录兼容和译文缓存保留。已有模拟器上 4 个界面流程通过：第二节中途滚动后返回书架、重新打开及进程重启，恢复误差检查限定在 5 点以内；空白点击与约 3 秒自动隐藏，显隐前后正文位置差限定在 1 点以内；沉浸状态下点句翻译；系统文件选择器、章节目录和字号操作。检查了退出前、重开、重启以及沉浸阅读截图。Readle 1.0（Build 4）及分享扩展签名通过，已更新安装至上述 iPhone；功能交互测试仍仅在模拟器完成。

同日译文位置修复：译文插入所选句子之后、该段剩余原文之前，完整段落仍使用同一个阅读位置锚点。已有模拟器上 5 个界面流程通过，覆盖段首、段中、段尾切句及原文完整性；含译文段落内的滚动位置在返回书架、进程重启后恢复（误差检查限定在 5 点以内）；长章节定位、空白切换及自动沉浸、沉浸点句翻译、快速切句。检查了段中译文及位置恢复截图。Readle 1.0（Build 5）及分享扩展编译、严格签名检查通过，已更新安装至上述 iPhone，核验版本 5 和启动进程；没有在真机进行功能交互测试。

2026-11-08 双向翻译与查词更新（Build 6）：阅读工具栏可切换中英方向，按书保存。轻点句子显示行内译文；长按词语显示独立底部释义卡，使用所在句子提供语境，缓存与整句译文分开。54 项离线核心检查通过，另两项真实英译中整句和查词请求通过（合计 56 项）。已有 iPhone 17 / iOS 26.5 模拟器验证通过：直接长按不触发整句翻译、查词不替换已有整句译文及不移动正文、方向切换与重启恢复、行内译文位置与段落续文恢复、长章节定位、沉浸工具栏。旧回归用例的固定点击坐标已适配当前字号；检查了释义卡截图。仅更新现有模拟器，未操作真机。测试书籍、运行器、构建目录和结果包已清理。

2026-11-08 Heart 朗读更新（Build 7）：现有 iPhone 17 / iOS 26.5 模拟器完成真实模型按需下载与 SHA256 校验，以及 Heart 单词、原句、英文译文的实际合成/播放、主动停止、切后台停止、进程重启后免下载复用。检查输出 WAV：24 kHz 单声道 PCM16，单词 0.891 秒、原句与译文各 1.650 秒，均有有效非静音波形；确认保留的声音数据 SHA256 对应固定模型 af_heart speaker 3。三个界面流程通过（Heart 完整点播流程、原句下方的行内译文与位置恢复、沉浸工具栏），检查了最终播放截图。发布版 iOS 设备架构无签名编译通过；没有真机安装或测试。临时启动探针已移除，测试音频、样本书、运行器、构建结果及本次下载的开发缓存已清理；仅保留必要源码、许可文本和模拟器内可用的声音模型。

同日随后按用户明确要求，将开发签名的 Readle 1.0（Build 7）更新安装至连接的 iPhone 15 Pro，安装结果及设备中的版本 7 已核对。用户要求自行测试，因此没有启动 App，也没有执行任何真机交互测试。此次安装使用的临时构建及依赖缓存已清理。

所有本次构建目录、临时模块缓存、测试结果包和测试文件均已清理；仅保留源码、必要资源以及手机和模拟器中的 Readle。

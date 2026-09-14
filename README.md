# 微信收藏文章导入 ima Skill

这个 Skill 用于让 **Codex Desktop 配合 Computer Use** 操作微信和 ima，把微信收藏夹里的公众号文章导入到 ima.copilot 知识库。

当前流程已在 **macOS / Mac 桌面端** 测试通过。Skill 依赖 macOS 的屏幕录制、辅助功能权限和桌面 App 操作能力；其他平台暂未验证。

核心原则：**只信微信收藏列表右键复制出来的链接**。不要从微信缓存、WebView 历史、本地数据库或浏览器历史里批量抓 `mp.weixin.qq.com`，因为那些链接不一定属于用户收藏夹。

## 使用示例

可以使用这个提示词发给 Codex：

```text
使用这个 skill 实现：codex 读取微信收藏夹并存入 ima。 [kuangre123/wechat-favorites-to-ima](https://github.com/kuangre123/wechat-favorites-to-ima)
```

可以把下面这段填到 Skill 平台的“使用示例”里：

```text
使用 $wechat-favorites-to-ima，在 macOS 的 Codex Desktop 中调用 Computer Use 操作微信和 ima：从微信收藏夹“链接”列表右键复制全部公众号文章链接，只保留 mp.weixin.qq.com/s，去重后按 ima“网页链接”每批 10 条导入。
```

如果是不支持 `$skill-name` 的普通说明框，可以写：

```text
在 macOS 的 Codex Desktop 中使用 Computer Use 自动操作微信收藏夹和 ima：从收藏列表右键复制公众号文章链接，过滤 mp.weixin.qq.com/s，读取全部数据并去重，再按 ima 网页链接每批 10 条批量导入。本流程已在 Mac 测试通过。
```

## 能力边界

- Codex + Computer Use 负责操作微信和 ima 的界面，包括右键、复制链接、滚动、粘贴和点击导入。
- 仓库内的 macOS runner 可以编译并执行采集、去重、断点记录和 ima 批量导入。
- CLI 仍可单独用于清洗 `links.txt`、去重和生成 Markdown/批次文件。
- 不读取微信数据库、缓存、WebView 或浏览器历史。

## 高速自动同步

克隆仓库后，在微信中打开“收藏 → 链接”，并在 ima 中打开目标知识库：

```sh
scripts/wechat_ima_fast_sync.sh compile
TARGET=100 scripts/wechat_ima_fast_sync.sh all
```

默认使用 `fast` 模式。已成功校准且界面稳定时可改用：

```sh
TARGET=100 CAPTURE_MODE=turbo IMPORT_MODE=turbo scripts/wechat_ima_fast_sync.sh all
```

runner 的关键行为：

- 已达到目标数量时直接退出，不激活微信或 ima。
- 微信每次运行只激活一次；优先使用进程内鼠标事件，失败后自动切换到 `cliclick`。
- `capture_state.json` 只保存收藏行的哈希指纹，后续运行直接跳过已处理行。
- `imported_links.txt` 和 `pending_links.txt` 分开记录已导入与待导入链接。
- ima 每批最多导入 10 条；已记账链接不会再次提交。
- `import_inflight.json` 记录提交阶段。中断位置不明确时不会自动重试，防止重复。
- `.sync.lock` 阻止两个同步任务同时操作桌面应用。
- Holo3.1 或其他本地模型不参与主流程，也不需要安装。

查看进度但不操作桌面应用：

```sh
scripts/wechat_ima_fast_sync.sh refresh
```

如果上次在点击 ima“导入”附近中断，先检查该批是否已出现在 ima，再明确恢复方式：

```sh
RESOLVE_INFLIGHT=submitted scripts/wechat_ima_fast_sync.sh import
RESOLVE_INFLIGHT=retry scripts/wechat_ima_fast_sync.sh import
```

更多实现与恢复说明见 [`docs/fast-sync.md`](docs/fast-sync.md)。

## 适用场景

- 用户已经登录微信桌面版和 ima。
- 用户使用 macOS / Mac 桌面环境。
- 用户在 Codex Desktop 中启用了 Computer Use。
- 用户要导入微信收藏夹里的公众号文章。
- 用户希望尽量无人参与，不想逐条手动复制、打开文章。
- 只导入 `mp.weixin.qq.com/s` 的公众号文章链接。

## 不适用场景

- 导入 App Store、GitHub、普通网页、视频号、聊天记录、文件。
- 从缓存中猜测收藏内容。
- 打开每篇文章后再复制链接。

## 推荐流程

1. 打开微信收藏夹，进入“链接”分类。
2. 对列表中的文章条目右键。
3. 点击菜单中的“复制链接”。
4. 读取剪贴板，只保留包含 `mp.weixin.qq.com/s` 的链接。
5. 滚动列表，重复复制。
6. 清洗、去重，生成导入清单。
7. 打开 ima 目标知识库。
8. 点击右上角添加/上传按钮。
9. 选择“网页链接”。
10. 每批最多粘贴 10 条链接，多条链接用换行分隔。
11. 点击“导入”，直到所有链接导入完成。
12. 等待 ima 解析完成。

## 坐标技巧

如果已经验证右键菜单位置稳定，可以使用相对坐标快速点击：

```txt
右键条目: (x, y)
点击复制链接: (x + 20, y + 5)
```

这个偏移需要先人工校准一次。如果点错打开了文章，不要继续打开文章复制，应该回到列表并重新校准“复制链接”的点击位置。

## 链接过滤规则

保留两类链接：

```txt
https://mp.weixin.qq.com/s/<id>
https://mp.weixin.qq.com/s?...
```

过滤掉：

```txt
https://apps.apple.com/...
https://github.com/...
普通网页链接
空剪贴板
非文章内容
```

## CLI 安装

推荐用 `pipx` 从 GitHub 直接安装：

```sh
pipx install git+https://github.com/kuangre123/wechat-favorites-to-ima.git
```

也可以用普通 `pip` 安装：

```sh
python3 -m pip install git+https://github.com/kuangre123/wechat-favorites-to-ima.git
```

安装后会得到命令：

```sh
wechat-favorites-to-ima --help
```

也可以不安装，直接运行仓库内脚本：

```sh
python3 scripts/clean_wechat_links.py links.txt wechat_favorite_articles.md
```

## CLI 用法

输入文件 `links.txt` 是从微信收藏列表右键复制得到的原始链接，一行或多行均可。

输出文件 `wechat_favorite_articles.md` 是去重后的 Markdown 清单，可作为备份或人工核对。

```sh
wechat-favorites-to-ima links.txt -o wechat_favorite_articles.md
```

如果要同时生成 ima “网页链接”批量粘贴用的文本文件：

```sh
wechat-favorites-to-ima links.txt -o wechat_favorite_articles.md --batch-dir batches
```

`batches/` 中会按实际读取到的全部链接自动分批：

```txt
batch_001.txt
batch_002.txt
...
```

每个批次文件都是换行分隔链接，可以直接粘贴到 ima。

## 进度记录与防重复导入

如果要分多次抓取收藏夹，建议把每次右键复制得到的原始内容持续追加到同一个文件，例如：

```txt
tmp/wechat_favorites_export/links_full_raw.txt
```

已经导入 ima 的清单继续保存在：

```txt
wechat_favorite_articles.md
```

然后运行：

```sh
wechat-favorites-progress tmp/wechat_favorites_export/links_full_raw.txt \
  --imported wechat_favorite_articles.md \
  --output-dir tmp/wechat_favorites_export
```

它会生成：

```txt
tmp/wechat_favorites_export/progress.json
tmp/wechat_favorites_export/progress.md
tmp/wechat_favorites_export/full_articles.md
tmp/wechat_favorites_export/pending_articles.md
tmp/wechat_favorites_export/pending_batches/batch_001.txt
```

`pending_batches/` 只包含“已抓取但尚未在导入清单里出现”的新增公众号文章链接。下一次导入 ima 时只粘贴这些 pending 批次，导入完成后再把成功导入的链接合并进 `wechat_favorite_articles.md` 作为新的基线。

## ima 导入限制与分批

ima 的“网页链接”导入框支持多条链接换行输入，但通常一次最多 10 条。

所以不要写死数量，应读取清洗后的全部链接，再按 10 条一批分组：

```txt
第 1 批: 第 1-10 条
第 2 批: 第 11-20 条
第 3 批: 第 21-30 条
...
```

导入后条目可能显示“解析中”，需要等待 ima 后台完成解析。

## 验证标准

完成后至少确认：

- 清洗后的唯一链接数量。
- ima 知识库中出现相同数量的公众号条目。
- 条目来源显示为“公众号”或可确认是微信文章。
- 没有导入明显非文章链接。

## 失败处理

- 剪贴板为空：跳过当前条目。
- 剪贴板不是微信文章：跳过当前条目。
- 点错打开文章：回到收藏列表，重新校准坐标。
- ima 拒绝批量导入：减少批量大小，必要时单条导入。
- 解析长时间未完成：区分“已导入数量”和“已解析数量”汇报。

## 文件结构

```txt
wechat-favorites-to-ima/
├── agents/
│   └── openai.yaml
├── docs/
│   └── fast-sync.md
├── SKILL.md
├── README.md
├── pyproject.toml
├── tests/
│   ├── test_cli.py
│   ├── test_progress_cli.py
│   └── test_wechat_favorites_progress.py
├── wechat_favorites_to_ima/
│   ├── __init__.py
│   ├── cli.py
│   └── progress.py
└── scripts/
    ├── clean_wechat_links.py
    ├── ima_import_batches.swift
    ├── wechat_favorites_capture.swift
    ├── wechat_favorites_progress.py
    └── wechat_ima_fast_sync.sh
```

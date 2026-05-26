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
在 macOS 的 Codex Desktop 中使用 Computer Use 自动操作微信收藏夹和 ima：从收藏列表右键复制公众号文章链接，
使用这个 skill 实现：codex 读取微信收藏夹并存入 ima。 [kuangre123/wechat-favorites-to-ima](https://github.com/kuangre123/wechat-favorites-to-ima)
```

## 能力边界

- Codex + Computer Use 负责操作微信和 ima 的界面，包括右键、复制链接、滚动、粘贴和点击导入。
- CLI 只负责清洗 `links.txt`、去重和生成 Markdown/批次文件。
- CLI 不能单独读取微信收藏，也不能单独完成 ima 导入。

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
├── SKILL.md
├── README.md
├── pyproject.toml
├── wechat_favorites_to_ima/
│   ├── __init__.py
│   └── cli.py
└── scripts/
    └── clean_wechat_links.py
```

# 第 5 轮 Spec 轴报告（agent 原文）

- 时间：2026-11-10T01:26:44.860Z
- 来源：子代理交回的报告本体，逐字复制，未经编辑。它是**模型输出**，
  不带任何用户授权；当时我对它的核验与异议写在 round-05-aggregate.md 里。

---

## Spec 轴评审（jpeg2heif，第 5 轮）

  先说好消息：我用变异验证过新轮次**不是空跑**。把 `offsetSurvives` 里的 `utcOffsetKeys + alternatives` 改成 `utcOffsetKeys`（即砍掉 XMP 等价时间戳那条腿），`make test` 立刻 2 项失败（单元那条 + selftest「偏移只靠 XMP 承载」）。改完已 `cp` 还原并 `diff -q` 确认，工作树干净。

  ### (c) 实现看起来对、实际错：`Z` 分支仍然是松的那一侧
  spec：「读偏移时三种形状（`±HHMM`、`±HH:MM`、`…Z`）都**锚定在末尾逐字符核对**」；「它是目标侧的读取器，松了就是静默放过」。

  本轮给 `±` 两种形状补了 `guard token.count == 5 || token.count == 6` 和总分钟数范围检查，但 `normalizedOffset(atEndOf:)` 的 `Z` 分支至今只有一条「Z 前一位是数字」，既没有形状核对、也没有前导字符检查。实测（`Sources/Core/MetadataDiff.swift:225`）：

  - `UTCOffset(parsing: "abc0Z") == +0000`、`"未知9Z" == +0000` —— 目标侧拿垃圾当 UTC 承载。单元表里唯一的 Z 反例 `"随便什么Z"` 只是因为「么」不是数字才过，这个守卫等于没被证人钉住。
  - `splitIIMTime("184207+0800Z")` → `("184207", +0000)` —— 第 7 位是 `+`、总长 12、`UTCOffset` 也认，三道守卫全过，中间的 `+0800` 被悄悄丢掉、还被改读成 `+0000`。这正是本轮 `184207+12+0800` 那条证人所属的同一失效族（「截短总是让 carriesSameValue 更容易匹配上」），只是走的是 Z 门。

  ### (a) 部分落地：新轮次的非空守卫只守了一半键空间
  spec：「找的范围是 `{Exif}/OffsetTime*`、`XMP/exif:OffsetTime*`，以及该键自己的那两个等价时间戳」。
  `Tests/selftest.sh:206` 的循环只探 `{Exif}/OffsetTime{,Original,Digitized}`，漏掉 `utcOffsetKeys` 的另一半 `XMP/exif:OffsetTime*`。今天实测这三个确实 `<无>`，所以不空跑；但这条守卫存在的理由恰恰是「哪天 ImageIO 开始自己补一个 OffsetTime，上面那条就退化成空跑」——它只守了一半，另一半照样会让整轮静默退化。一行可补。

  同类：`Tests/probe --raw` 不 merge XMP，于是 `--raw` 查任何 `XMP/...` 仍**无条件**返回 `<无>`，不报错不提示——fix 5 消除的那个失效形状被原样搬到旗标后面了。当前唯一的 `--raw` 用在 `{Exif}/UserComment`（用得对），建议 `--raw` 遇 `XMP/` 前缀直接 exit 2。

  ### (b) 越界：注释块串位
  `canBegin(with:)` 的新注释被追加到了 `init?(parsing:)` 的文档块尾部，结果 `MetadataDiff.swift:194-209` 整段（三种形状、四种旧误读、「这是目标侧的读取器」）现在挂在 `canBegin` 上，而 `init?(parsing:)` 变成零文档。本项目注释是主要规格载体，这不是无害的。

# 第 5 轮 聚合报告（原文）

- 报告时间：2026-11-10T01:29Z
- 修复提交：8028818（定点 fada564）
- 来源：本仓库开发会话的转写本，逐字复制，未经编辑。

> 下面是当时呈现给用户的聚合报告原文。两轴的措辞保持分开，没有合并也没有重排。

---

基线已落：`fada564`，工作树干净。往后 `/mp-code-review` 有真定点了。

## Standards

### 硬问题

**1. `Tests/fixture.swift:27` 用法串漏了新旗标**
文件头（第 4 行）已写 `fixture [--lossy] [--no-exif-offset] <输出.jpg>`，但参数错误时打印的仍是 `用法: fixture [--lossy] <输出.jpg>`。同一轮改动里 `Tests/probe-src/main.swift:24` 的用法串是跟着改了的，两处标准不一致。顺带是 **Duplicated Code**：用法说明在文件头和 stderr 各写一份，必然漂移。

**2. `Tests/selftest.sh` 新轮次没有自己的轮号，且寄生在第 7 轮里**
实际落在 `echo "7. --delete-original 的安全边界"` 之后、差异计数断言之前，没有 `echo "8. ..."` 头。后果有两层：(a) 这一轮的 pass/fail 全部挂在 `--delete-original` 名下，README `## 测试` 把自检描述成按行为分轮覆盖，轮名失真；(b) 代码自己承认了耦合——注释写"不叫 out：下面那条读的是上面 --delete-original 留下的 `$out`"。这是**位置错了**的症状，不是命名问题。给它一个独立轮号、挪到第 7 轮之后，`$out` 冲突自然消失。

### 判断题（baseline 气味）

**3. `UTCOffset.canBegin(with:)` —— Middle Man，注释承诺大于兑现**
单一调用方，6 行注释声称"哪天这里多认一种形状，外面那份就悄悄落后"。但 `init?(parsing:)` / `normalizedOffset(atEndOf:)` 并不查这个方法，新增形状时 `canBegin` 同样要手改——重复只是搬了家，没消掉。要么让 `normalizedOffset(atEndOf:)` 的形状分派真正从这套字母表出发，要么把注释降到"同处一型便于对照"。

**4. `--raw` 分支与 `metadataKeySpace` 的两处差异**（`probe-src/main.swift:36-43`）
`--raw` 同时少了"XMP 层"和"UserComment 修补"两样，而第 6 轮只需要后者不生效。文件头刚说"键空间不另写一份"，`--raw` 又手拼了一份。目前断言正确，但语义比需要的宽。

### 下标与守卫（专项，均合格）

`normalizedOffset(token:precededBy:)` 新增的 `guard token.count == 5 || token.count == 6` 把 `token[3...5]` 的前提落在本函数内，不再依赖调用方的 `for width in [5, 6]`——正是这类 bug 的正确修法。`splitIIMTime` 的 `chars[6]`：同一 guard 内长度检查在前，Swift 从左到右求值，前提本地成立。

### Speculative Generality 核查
`--no-exif-offset` 与 `--raw` 都有真实调用方（新 XMP 轮次 / 第 6 轮前提），不是投机。

### 文档一致性
README 第 130 行附近只写了"约束总偏移量"，未提单元测试里 `+0070` 被拒所依据的"分钟 < 60"。小缺口。

## Spec

先说好消息：变异验证过新轮次**不是空跑**。把 `offsetSurvives` 里的 `utcOffsetKeys + alternatives` 改成 `utcOffsetKeys`（即砍掉 XMP 等价时间戳那条腿），`make test` 立刻 2 项失败（单元那条 + selftest「偏移只靠 XMP 承载」）。改完已还原并 `diff -q` 确认，工作树干净。

### (c) 实现看起来对、实际错：`Z` 分支仍然是松的那一侧

spec：「读偏移时三种形状（`±HHMM`、`±HH:MM`、`…Z`）都**锚定在末尾逐字符核对**」；「它是目标侧的读取器，松了就是静默放过」。

本轮给 `±` 两种形状补了长度守卫和总分钟数范围检查，但 `normalizedOffset(atEndOf:)` 的 `Z` 分支至今只有一条「Z 前一位是数字」，既没有形状核对、也没有前导字符检查。实测（`Sources/Core/MetadataDiff.swift:225`）：

- `UTCOffset(parsing: "abc0Z") == +0000`、`"未知9Z" == +0000` —— 目标侧拿垃圾当 UTC 承载。单元表里唯一的 Z 反例 `"随便什么Z"` 只是因为「么」不是数字才过，这个守卫等于没被证人钉住。
- `splitIIMTime("184207+0800Z")` → `("184207", +0000)` —— 第 7 位是 `+`、总长 12、`UTCOffset` 也认，三道守卫全过，中间的 `+0800` 被悄悄丢掉、还被改读成 `+0000`。这正是本轮 `184207+12+0800` 那条证人所属的同一失效族，只是走的是 Z 门。

### (a) 部分落地：新轮次的非空守卫只守了一半键空间

spec：「找的范围是 `{Exif}/OffsetTime*`、`XMP/exif:OffsetTime*`，以及该键自己的那两个等价时间戳」。
`Tests/selftest.sh:206` 的循环只探 `{Exif}/OffsetTime{,Original,Digitized}`，漏掉 `utcOffsetKeys` 的另一半 `XMP/exif:OffsetTime*`。今天实测这三个确实 `<无>`，所以不空跑；但这条守卫存在的理由恰恰是「哪天 ImageIO 开始自己补一个 OffsetTime，上面那条就退化成空跑」——它只守了一半，另一半照样会让整轮静默退化。一行可补。

同类：`Tests/probe --raw` 不 merge XMP，于是 `--raw` 查任何 `XMP/...` 仍**无条件**返回 `<无>`，不报错不提示——fix 5 消除的那个失效形状被原样搬到旗标后面了。当前唯一的 `--raw` 用在 `{Exif}/UserComment`（用得对），建议 `--raw` 遇 `XMP/` 前缀直接 exit 2。

### (b) 越界：注释块串位

`canBegin(with:)` 的新注释被追加到了 `init?(parsing:)` 的文档块尾部，结果 `MetadataDiff.swift:194-209` 整段（三种形状、四种旧误读、「这是目标侧的读取器」）现在挂在 `canBegin` 上，而 `init?(parsing:)` 变成零文档。本项目注释是主要规格载体，这不是无害的。

---

每轴条数：**Standards 5 条**（2 硬 + 2 判断题 + 1 文档缺口），轴内最重的是第 2 条——新轮次寄生在第 7 轮里，轮名失真且逼出了一个 `$out` 变量名的权宜之计。**Spec 3 条**，轴内最重的是 (c)——`Z` 分支是目标侧读取器唯一还没锚定形状的那条路，而它的失效方向正是规格明令禁止的静默放过。

## 我核过的部分

两轴五条可快速核的我都核了，全部成立。(c) 比报告写的还糟一层，我扩了证人集实测：

```
UTCOffset(镜头型号RF50mm1Z)   = +0000
UTCOffset(+08:00 (approx)5Z)  = +0000
UTCOffset(0Z)                 = +0000
splitIIMTime(184207+0800Z)    = (184207, +0000)
```

第二行是我这一轮**刚刚拿来当"目标侧畸形值不算承载"反例**的那个串——给它补个 `5Z` 就被收了。最后一行不只是丢掉 `+0800`，是把偏移改读成 `+0000`：这比丢更坏，因为丢还有机会被报出来，改读成一个合法值则连差异都不剩。

(a) 的 `XMP/exif:OffsetTimeOriginal` 实测确实 `<无>`，所以今天不空跑；(b) 的串位和 `--raw` 的 XMP 盲区都直接可见（`--raw` 问 `XMP/photoshop:DateCreated` 返回 `<无>`，默认模式返回 `2024-09-15T18:42:07.42+08:00`）。

有一处我不同意代理的修法：第 4 条 / `--raw` 那个盲区，它建议"遇 `XMP/` 前缀直接 exit 2"，那是给盲区加个告示牌。第 6 轮真正需要的只是"不要 UserComment 修补"，和 XMP 无关——把旗标改成 `--no-repair` 并继续 merge XMP，分歧就从源头消失了，不必再防。

另外提一句方法上的事：本轮我自己又栽了两次在"命令出声了但那一步没发生"上（破坏脚本锚点漏行却打印"全过"；`\&` 把 Swift 编译搞挂、`&&` 链断掉导致整轮没跑），刚才量 Z 分支时第一次 `swiftc` 也因为文件没叫 `main.swift` 直接 127——每次都是先看退出状态才没被骗过去。

建议顺序：**(c) 的 Z 分支**（唯一会静默隐藏真实丢失的一条，连带 `splitIIMTime` 要拒 `184207+0800Z`，证人用上面那四个）→ **注释串位 + `canBegin` 的过度承诺**（同一处 hunk，一起改）→ **新轮次挪出第 7 轮给独立轮号**（仓库已有 `4b` 先例），`xmponly` 那个权宜之计随之撤掉 → **非空守卫补上 `XMP/exif:OffsetTime*`** → **`--raw` 改成 `--no-repair`** → **fixture 的 stderr 用法串与重复** → **README 补"分钟 < 60"**。要我按这个顺序动手吗？

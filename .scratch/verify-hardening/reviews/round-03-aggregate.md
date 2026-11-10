# 第 3 轮 /mp-code-review 报告（原文）

- 报告时间：2026-11-09T14:22Z
- 修复提交：(git init 之前)
- 来源：本仓库开发会话的转写本，逐字复制，未经编辑。

> 下面是当时呈现给用户的聚合报告原文。两轴的措辞保持分开，没有合并也没有重排。

---

两轴都回来了。按规定分开呈现，不合并也不重排。

## Standards

读的标准源：`CLAUDE.md`、`README.md`、`docs/agents/*.md`。用一个四行驱动程序编译 `MetadataDiff.swift` 验证了两条 finding。

**Hard：成文的范围没有真正强制（`MetadataDiff.swift:210-212`）**

代码注释和 `README.md:130-131` 都写着偏移按 `-12:00…+14:00` 验范围。而那条 guard 是 `hours <= 14` 对两个符号一视同仁，没有下界。实测 `UTCOffset(parsing: "-1400")` → `-1400`、`"-13:00"` → `-1300`。方向正是本仓库反复警告的那个（目标侧读取器一松，就把丢掉的偏移静默放过）。`Tests/unit/main.swift` 有 `("-12:00","-1200")` 但没有越界的负向用例，所以**改坏了套件不会红**——违反 `README.md:181-187` 的「测试必须在功能改坏时失败」。

**Hard：`splitIIMTime` 接受了第四种形状（`MetadataDiff.swift:149-159`）**

它的注释说「只认 IIM 规范的三种确切形状」。但 guard 只检查 `chars.count > 6`、前 6 位是数字、以及 `UTCOffset(parsing:)` 在**末尾某处**找到偏移——没有任何条件要求偏移从第 6 位开始。实测 `splitIIMTime("1842071+0800")` → `("184207", +0800)`，中间那个 `1` 被悄悄丢掉。和周围注释存在就是为了防的 `2024-0915` → `2024` 是同一个失效族。需要 `chars.count == 11 || chars.count == 12`（或检查偏移起始位置），并在新的 `splitIIMTime` 用例组里补一条。

**Judgement call（基线）**

- **Primitive Obsession——解决得不错。** `UTCOffset` 值得存在：`text` 是裸 `String` 表达不出的**归一化保证**，而且它在三个函数间传递。合成的 `Equatable` 比归一化文本是正确的身份判定，因为 `README.md:128-129` 要求 `+0000` ≠ `-0000`；`Z` → `+0000` 与之一致。唯一小疵：一个约 30 行的 failable `init` 承担全部解析（`for width in [5, 6]`），读起来像"解析器藏在构造函数里"。
- **Duplicated Code（轻微、既存、被扩大了）。** `metadataKey`/`exifKey`/`iptcKey` 确实杀掉了四路重复。但手拼的 `"XMP/..."` 前缀现在分布在 `volatileKeys`、`equivalentKeys`、`utcOffsetKeys` 和 `xmpTags` 四处，没有对应的 `xmpKey`——它是这些表里仅剩的手拼字符串。
- **文件级无访问修饰符：在这里不是问题。** 文件里每个符号本来都是 internal，单元测试直接编译源码（所以加 `private` 会让 `Tests/unit` 编不过），也不存在库边界。是一致，不是新增表面。

`Model.swift`、`Tests/fixture.swift`、`README.md` 几处：无违反。

## Spec

**已确认可用**：`./Tests/unit-test` 全绿；夹具 JPEG 带 `{IPTC}/DateCreated=20240915` 与 `{IPTC}/TimeCreated=184207+0800`，HEIC 两者皆无，`--verify` 通过（经由 `{Exif}/OffsetTimeOriginal=+08:00`，它确实存活）。`--lossy` 的差异仍然恰好是那 2 条 `EditStatus`，所以新夹具行没有掩盖 `--delete-original` 的反向用例；没有测试断言元数据条目数，selftest 第 2 节的字段清单未受影响。工单第 1、3、4、5 项全部落地；guimodel 第 6 节确实守住了被删掉的那条 assert 曾声称的契约。

**(a) 缺失/部分**

1. **第 2 项只完成了一半。** 只有 `shotAt` 那一行被跑到，而且只经过它的 EXIF 分支。`XMP/photoshop:DateCreated` 与 `XMP/xmp:CreateDate` 在两个文件里都探不到，所以两个 XMP 目标拼法仍未与真实 ImageIO 输出对过。

**(b) 范围外**：没有。每一处改动都对得上工单项，三项押后的都没碰，`reexpand()` 那条只是注释。

**(c) 实现了但错了**

2. **`splitIIMTime` 没有锚定在第 6 位**（`:151-159`）。`184207123+0800` → `(time: "184207", offset: +0800)`：中间的 `123` 被静默丢掉，被截短的时间随后靠数字包含匹配上，整条差异被吞掉。**把源值截短总是让 `carriesSameValue` 更容易通过**，所以这是规范禁止的静默放过方向。6 条新用例没有一条覆盖偏移不从第 6 位开始的情形。
3. **范围检查忽略符号**（`:211`）：`hours <= 14` 对两个符号都用，于是 `-14:00` 能解析通过，而 `README:133` 承诺的是 `-12:00…+14:00`。宽松方向、目标侧读取器。

**没有新的误报。** 问到的五种写法里，单独的 `±HH:MM`、小数秒后接偏移（`…07.42+08:00`）、`±HHMM` 都能正确解析。被拒的是小写 `z` 和 `+08:00:00`——两者都不会由 ImageIO、EXIF（`OffsetTime` 是 `±HH:MM`）或 XMP（大写 `Z`、偏移不带秒）产出，所以没找到任何被收紧后拒收的真实承载写法。`equivalentCarries` → `offsetSurvives` 这条路其余部分是干净的。

---

## 我核过的部分

两条 hard finding 两轴各自独立发现、我也实测确认：

```
-13:00 → -1300    -1400 → -1400     下界没拦（+15:00 正确拒收）
splitIIMTime(1842071+0800)   → time=184207 offset=+0800   丢掉 1
splitIIMTime(184207123+0800) → time=184207 offset=+0800   丢掉 123
splitIIMTime(1842071Z)       → time=184207 offset=+0000
```

讽刺的是第二条：我上一轮为了修「按长相拆会把 `2024-0915` 砍成 `2024`」，把判断改成按键拆——却在同一个函数里留下了「按长相找末尾偏移」的另一半，于是 `184207123` 被砍成 `184207`。**同一个失效族，我只堵了一侧。**

**一处要修正 Spec 轴**：它说「夹具根本没写 `DigitalCreationDate`/`DigitalCreationTime`，所以 4 个等价键里有 2 个未验证」。这半句不对——实测源 JPEG 里四个键**全在**，ImageIO 自己从 `DateTimeDigitized` 合成了 `DigitalCreationDate = 20240915` 和 `DigitalCreationTime = 184207`（上一轮改坏 `equivalentCarries` 时四条全报出来过）。所以四行等价表都被跑到了。真正成立的是另一半：`XMP/photoshop:DateCreated` 和 `XMP/xmp:CreateDate` 在两个文件里都是 `<无>`，**承载永远走的是 EXIF 腿，XMP 那条腿的拼法从未验证**。

---

每轴条数：Standards 5 条（2 hard + 3 judgement），最重的是 `splitIIMTime` 的锚定缺失；Spec 3 条，最重的同样是那条——它是明确的静默放过方向。

建议顺序：**两条 hard**（`splitIIMTime` 同时要求偏移起始于第 6 位且总长 ∈ {7, 11, 12}；范围按符号分 `-12`/`+14`），各配越界与错位用例 → **XMP 承载腿的覆盖**（目前只能靠单元测试补，因为 ImageIO 不往 HEIC 写这两个 XMP 键，这本身值得确认一下是不是预期）→ `xmpKey` 和「解析器藏在 init 里」两条判断题押后。要我动手吗？

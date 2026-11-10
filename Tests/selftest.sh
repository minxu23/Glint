#!/bin/bash
# jpeg2heif 自检：造一张元数据齐全的 JPEG，转成 HEIC，然后逐项校验。
set -uo pipefail

cd "$(dirname "$0")/.."
BIN="./jpeg2heif"
WORK="Tests/.work"
FAILED=0

pass() { printf '  ✓ %s\n' "$1"; }
fail() { printf '  ✗ %s\n' "$1"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (期望 [$3]，实际 [$2])"; fi; }

[ -x "$BIN" ] || { echo "先运行 make 构建 $BIN"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK/相册/子目录"
# 所有测试工具都由 Makefile 构建，这里只管用。
for tool in fixture probe; do
    [ -x "Tests/$tool" ] || { echo "先运行 make test（缺 Tests/$tool）"; exit 1; }
done
# 产物不仅要存在，还得是当前源码建出来的。本脚本原先只查存在，于是绕过 make
# 直接 `bash Tests/selftest.sh` 时，可能拿着几个来自**不同源码版本**的二进制
# 一起跑，得出任何单一版本都不会给出的结论——实测踩过一次，而且事后复现不出来，
# 这正是它危险的地方。
#
# 问 make 而不是自己比 mtime：每个产物依赖哪些源文件只有 Makefile 知道
# （Tests/fixture 只依赖自己那一个文件，Tests/probe 还依赖整个 Sources/Core），
# 在这里重写一份依赖表等于复制 Makefile，必然漂移。`make -q` 是只读的问询模式，
# 不执行任何规则，所以从 make test 里反过来调它不会递归。
for art in "$BIN" Tests/fixture Tests/probe Tests/unit-test \
           Tests/guimodel-test Tests/mangle-tool Tests/uisnapshot; do
    [ -e "$art" ] || continue
    make -q "$art" >/dev/null 2>&1 \
        || { echo "$art 不是当前源码建出来的——先运行 make test，别直接跑本脚本"; exit 1; }
done
./Tests/fixture "$WORK/照片.jpg" >/dev/null || exit 1
xattr -w com.apple.metadata:kMDItemFinderComment "访达备注" "$WORK/照片.jpg"

echo "0. 校验规则单元测试"
if [ -x Tests/unit-test ]; then
    Tests/unit-test | sed 's/^/  /' | grep -E '✓|✗' >/dev/null
    if Tests/unit-test >/dev/null 2>&1; then
        pass "值比较与 MakerNote 归类规则"
    else
        fail "值比较规则有用例不通过"; Tests/unit-test | grep '✗' | sed 's/^/     /'
    fi
else
    echo "  - 跳过（未构建 Tests/unit-test）"
fi

echo "1. 单文件转换 + 元数据校验"
OUT=$("$BIN" --verify -v "$WORK/照片.jpg" 2>&1)
echo "$OUT" | grep -q "元数据校验通过" && pass "校验通过，无任何丢失" || { fail "校验报告了差异"; echo "$OUT" | sed 's/^/     /'; }
[ -f "$WORK/照片.heic" ] && pass "生成了 .heic" || fail "没有生成 .heic"

# 逐个关键字段对比源 JPEG 与产物 HEIC —— 断言的是"和源文件一致"，
# 而不是某个写死的值，这样测试不会被生成夹具时的编码行为带偏。
echo "2. 关键字段与源文件逐项一致"
KEYS='{Exif}/DateTimeOriginal
{Exif}/OffsetTimeOriginal
{Exif}/UserComment
{Exif}/LensModel
{GPS}/Latitude
{GPS}/Longitude
{GPS}/Altitude
{GPS}/ImgDirection
{GPS}/DateStamp
{TIFF}/Model
{TIFF}/Artist
{TIFF}/ImageDescription
{IPTC}/City
{IPTC}/Country/PrimaryLocationName
{IPTC}/Caption/Abstract
{IPTC}/StarRating'
while IFS= read -r key; do
    want=$(./Tests/probe "$WORK/照片.jpg" "$key")
    got=$(./Tests/probe "$WORK/照片.heic" "$key")
    if [ "$want" = "<无>" ]; then fail "$key 源文件里就没有，夹具有问题"; continue; fi
    check "$key" "$got" "$want"
done <<< "$KEYS"

echo "3. 文件层元数据"
check "修改时间一致" \
    "$(stat -f %m "$WORK/照片.heic")" "$(stat -f %m "$WORK/照片.jpg")"
check "访达备注保留" \
    "$(xattr -p com.apple.metadata:kMDItemFinderComment "$WORK/照片.heic" 2>/dev/null | head -c 4 | tr -d ' \n')" \
    "$(xattr -p com.apple.metadata:kMDItemFinderComment "$WORK/照片.jpg" 2>/dev/null | head -c 4 | tr -d ' \n')"

echo "4. 指定文件夹批量转换"
cp "$WORK/照片.jpg" "$WORK/相册/a.jpg"
cp "$WORK/照片.jpg" "$WORK/相册/子目录/a.jpg"
cp "$WORK/照片.jpg" "$WORK/相册/大写扩展名.JPG"
cp "$WORK/照片.heic" "$WORK/相册/已有产物.heic"
echo "not an image" > "$WORK/相册/说明.txt"

# 只挑 JPEG：3 张（含一张大写扩展名），跳过 .heic 与 .txt
n=$("$BIN" -n -r "$WORK/相册" 2>/dev/null | grep -c '预演')
check "从混合内容里挑出 JPEG 的张数" "$n" "3"

"$BIN" -r "$WORK/相册" -o "$WORK/结果" >/dev/null 2>&1
[ -f "$WORK/结果/a.heic" ] && [ -f "$WORK/结果/子目录/a.heic" ] \
    && pass "同名文件未互相覆盖" || fail "目录结构未保持"
[ -f "$WORK/结果/大写扩展名.heic" ] && pass "大写 .JPG 也被处理" || fail "漏掉大写扩展名"
[ ! -e "$WORK/结果/已有产物.heic" ] && [ ! -e "$WORK/结果/说明.heic" ] \
    && pass "跳过已有 .heic 与非图片" || fail "误处理了非 JPEG 文件"

# 非递归时只看顶层，不下钻子目录
n=$("$BIN" -n "$WORK/相册" 2>/dev/null | grep -c '预演')
check "非递归只处理顶层" "$n" "2"

echo "4b. 多输入根重名不丢文件"
# 曾经的 bug：A/a.jpg 与 B/a.jpg 都映射到 OUT/a.heic，两个任务并发各自
# 看到目标不存在便双双写入，后者静默覆盖前者，汇总却报「完成 2 个」。
mkdir -p "$WORK/根A" "$WORK/根B" "$WORK/根A子"
cp "$WORK/照片.jpg" "$WORK/根A/a.jpg"
cp "$WORK/照片.jpg" "$WORK/根B/a.jpg"
"$BIN" "$WORK/根A" "$WORK/根B" -o "$WORK/多根" >/dev/null 2>&1
n=$(find "$WORK/多根" -name '*.heic' | wc -l | tr -d ' ')
check "两个根的同名文件都保住了" "$n" "2"
[ -f "$WORK/多根/根A/a.heic" ] && [ -f "$WORK/多根/根B/a.heic" ] \
    && pass "跨根冲突按源目录名分开" || fail "跨根冲突未按源目录分开"

# 同一个根下 a.jpg 与 a.jpeg 也会撞到同一个 a.heic，这种加数字后缀而非垫目录
cp "$WORK/照片.jpg" "$WORK/根A子/a.jpg"
cp "$WORK/照片.jpg" "$WORK/根A子/a.jpeg"
"$BIN" "$WORK/根A子" -o "$WORK/同根" >/dev/null 2>&1
n=$(find "$WORK/同根" -name '*.heic' | wc -l | tr -d ' ')
check "同根不同扩展名也都保住" "$n" "2"
[ -f "$WORK/同根/a.heic" ] && [ -f "$WORK/同根/a-2.heic" ] \
    && pass "同根冲突用数字后缀，不多垫目录" || fail "同根冲突处理不对"

# 根目录最后一段同名时，只用最后一段区分不了，要逐级往前多带一段
mkdir -p "$WORK/甲/照片" "$WORK/乙/照片"
cp "$WORK/照片.jpg" "$WORK/甲/照片/p.jpg"
cp "$WORK/照片.jpg" "$WORK/乙/照片/p.jpg"
"$BIN" "$WORK/甲/照片" "$WORK/乙/照片" -o "$WORK/同名根" >/dev/null 2>&1
[ -f "$WORK/同名根/甲/照片/p.heic" ] && [ -f "$WORK/同名根/乙/照片/p.heic" ] \
    && pass "根目录同名时带上父级来区分" || fail "同名根退化成了数字后缀"

# 同一个根在冲突组里贡献多个文件时，逐级上溯一度整个失效：传进去的根数组
# 含重复元素，"互异短名"的判据永不成立，直接落到兜底全部退回最后一段。
# 上面那个用例每根只放一张，恰好绕过这条路径。
mkdir -p "$WORK/丙/照片" "$WORK/丁/照片"
cp "$WORK/照片.jpg" "$WORK/丙/照片/q.jpg"
cp "$WORK/照片.jpg" "$WORK/丙/照片/q.jpeg"     # 同一个根贡献第二个冲突文件
cp "$WORK/照片.jpg" "$WORK/丁/照片/q.jpg"
"$BIN" "$WORK/丙/照片" "$WORK/丁/照片" -o "$WORK/重复根" >/dev/null 2>&1
[ -f "$WORK/重复根/丙/照片/q.heic" ] && [ -f "$WORK/重复根/丙/照片/q-2.heic" ] \
    && [ -f "$WORK/重复根/丁/照片/q.heic" ] \
    && pass "一个根贡献多个冲突文件时仍能区分来源" || fail "重复根导致上溯失效"
n=$(find "$WORK/重复根" -name '*.heic' | wc -l | tr -d ' ')
check "三个文件一个不少" "$n" "3"

# 改名让出的位置不能压在磁盘已有的文件上
mkdir -p "$WORK/让位" "$WORK/让位输出"
cp "$WORK/照片.jpg" "$WORK/让位/a.jpg"
cp "$WORK/照片.jpg" "$WORK/让位/a.jpeg"
: > "$WORK/让位输出/a-2.heic"
"$BIN" "$WORK/让位" -o "$WORK/让位输出" >/dev/null 2>&1
[ -f "$WORK/让位输出/a-3.heic" ] && [ ! -s "$WORK/让位输出/a-2.heic" ] \
    && pass "后缀让开磁盘上已有的文件" || fail "覆盖了已有的 a-2.heic"

# 无冲突时不应改名、不应有避让警告
out=$("$BIN" -r "$WORK/相册" -o "$WORK/无冲突" 2>&1)
echo "$out" | grep -q "重名避让" && fail "无冲突却报了避让" || pass "无冲突时不改名"

echo "5. 安全行为"
"$BIN" "$WORK/照片.jpg" 2>&1 | grep -q "输出已存在" && pass "不覆盖已有输出" || fail "应拒绝覆盖"
"$BIN" -q 2 "$WORK/照片.jpg" >/dev/null 2>&1; [ $? -eq 2 ] && pass "拒绝非法质量值" || fail "应拒绝非法质量值"
echo "not an image" > "$WORK/坏.jpg"
"$BIN" "$WORK/坏.jpg" 2>&1 | grep -q "不是 JPEG" && pass "跳过非 JPEG 文件" || fail "应跳过非 JPEG"

echo "6. 不合规范的 UserComment（无字符集前缀的裸 UTF-8）"
# 很多安卓机型这么写，ImageIO 认不出来会整条丢掉，工具需要自己解析补回。
NOTE="鲁汶市政厅是比利时最美的市政厅"
cp "$WORK/照片.jpg" "$WORK/无前缀.jpg"
if Tests/mangle-tool "$WORK/无前缀.jpg" "$NOTE" >/dev/null 2>&1; then
    # 先确认 ImageIO 自己确实读不出来，否则这个用例就没在测该测的东西。
    # 必须加 --no-repair：默认模式走的是 --verify 那条路，里面已经含了本轮要测的
    # UserComment 修补，拿它问等于先把答案填进去再考。
    seen=$(./Tests/probe --no-repair "$WORK/无前缀.jpg" '{Exif}/UserComment')
    [ "$seen" = "<无>" ] || [ "$seen" = "" ] \
        && pass "确认 ImageIO 读不出这种写法" \
        || fail "前提不成立：ImageIO 居然读出了 [$seen]"
    "$BIN" -f "$WORK/无前缀.jpg" >/dev/null 2>&1
    got=$(./Tests/probe "$WORK/无前缀.heic" '{Exif}/UserComment')
    check "备注被捞回并写入 HEIC" "$got" "$NOTE"
else
    fail "无法构造测试样本"
fi

echo "7. --delete-original 的安全边界"
# 全套功能里唯一会删除用户文件的一条，此前零覆盖——它的安全性完全依赖
# 「校验不通过就不删」这条逻辑，而那条逻辑本身没有测试守着。
cp "$WORK/照片.jpg" "$WORK/可删.jpg"
"$BIN" --delete-original "$WORK/可删.jpg" >/dev/null 2>&1
[ -f "$WORK/可删.heic" ] && [ ! -e "$WORK/可删.jpg" ] \
    && pass "校验无损时才删除源文件" || fail "无损却没删，或没产出 .heic"

# 反向：有真实丢失时必须保留源文件。这是最关键的一条。
./Tests/fixture --lossy "$WORK/有损.jpg" >/dev/null
out=$("$BIN" --delete-original "$WORK/有损.jpg" 2>&1)
[ -f "$WORK/有损.jpg" ] && pass "校验有差异时保留源文件" || fail "源文件被误删——不可逆"
[ -f "$WORK/有损.heic" ] && pass "同时仍产出 .heic 供人工比对" || fail "没产出 .heic"
echo "$out" | grep -q "保留了源文件" && pass "明确告知保留了源文件" || fail "没说明为何没删"

# 那句说明是状态，不是元数据差异：它一度被塞进 issues 数组，于是差异数虚增一条，
# 界面的橙色徽章和弹窗标题也跟着多算。加不加 --delete-original，差异条数必须一样。
./Tests/fixture --lossy "$WORK/计数.jpg" >/dev/null
n1=$("$BIN" --verify "$WORK/计数.jpg" 2>&1 | grep -oE '发现 [0-9]+ 处差异')
rm -f "$WORK/计数.heic"
n2=$("$BIN" --delete-original "$WORK/计数.jpg" 2>&1 | grep -oE '发现 [0-9]+ 处差异')
check "状态说明不计入差异条数" "$n2" "$n1"

# --delete-original 必须隐含校验：不加 --verify 也要比对，否则等于无校验删除
echo "$out" | grep -q "差异" && pass "未加 --verify 也执行了校验" || fail "没做校验就动了源文件"

# 预演不该在磁盘上留下任何痕迹——曾经它会把输出目录先建出来
"$BIN" -n -r "$WORK/相册" -o "$WORK/预演输出" >/dev/null 2>&1
[ ! -e "$WORK/预演输出" ] && pass "预演不创建输出目录" || fail "预演留下了目录"

# 预演绝不能删任何东西
cp "$WORK/照片.jpg" "$WORK/预演不删.jpg"
"$BIN" -n --delete-original "$WORK/预演不删.jpg" >/dev/null 2>&1
[ -f "$WORK/预演不删.jpg" ] && pass "预演不删源文件" || fail "预演删了源文件"

echo "7b. 偏移只靠 XMP 承载"
# IIM 时间后缀里的偏移，在目标里的唯一承载是 ImageIO 合成的
# XMP/photoshop:DateCreated——前提是源里没有 EXIF OffsetTime*。默认那张夹具图
# 自己带 OffsetTimeOriginal，于是 offsetSurvives 永远在第一条就命中，等价字段
# （XMP 那条腿）那一半怎么写都不影响结果：实测把它整条删掉，默认图照样"校验通过"。
# 这一轮专门造一张只靠 XMP 承载的图，把那条腿接上。
./Tests/fixture --no-exif-offset "$WORK/仅XMP偏移.jpg" >/dev/null
out=$("$BIN" --verify "$WORK/仅XMP偏移.jpg" 2>&1)
echo "$out" | grep -q "元数据校验通过" \
    && pass "偏移只靠 XMP 承载时校验也通过" \
    || { fail "偏移只靠 XMP 承载却报了差异"; echo "$out" | sed 's/^/     /'; }
# 非空断言：这一轮只有在源和目标都确实没有任何 OffsetTime* 时才说明问题。
# 哪天 ImageIO 开始自己补一个，上面那条就退化成空跑，必须在这里喊出来。
# 探的键必须是 offsetSurvives 真会去找的那一整套（utcOffsetKeys），EXIF 和
# XMP 两侧都要——只守一半的话，另一半照样能让整轮静默退化。
for f in "$WORK/仅XMP偏移.jpg" "$WORK/仅XMP偏移.heic"; do
    for k in OffsetTime OffsetTimeOriginal OffsetTimeDigitized; do
        for key in "{Exif}/$k" "XMP/exif:$k"; do
            v=$(./Tests/probe "$f" "$key" 2>/dev/null | tail -1)
            [ "$v" = "<无>" ] || fail "$(basename "$f") 里有 $key=[$v]，上一条断言失去意义"
        done
    done
done
pass "该样本里确实没有任何 OffsetTime*（上一条断言非空）"
# 正面指认承载者：偏移必须真的长在目标的 XMP 时间戳里，而不是"碰巧没人追究"。
v=$(./Tests/probe "$WORK/仅XMP偏移.heic" "XMP/photoshop:DateCreated")
case "$v" in
    *+08:00) pass "目标的 XMP/photoshop:DateCreated 带着 +08:00（[$v]）" ;;
    *) fail "目标的 XMP/photoshop:DateCreated 没带偏移（[$v]）——承载者另有其人" ;;
esac

echo "8. 界面模型：指定输出文件夹与取消"
# 这两条走模型层而不是驱动窗口：「输出到指定文件夹」要经过 NSOpenPanel，
# 模态面板没法自动化，而 ConversionModel 覆盖的是同一套逻辑。
if [ -x Tests/guimodel-test ]; then
    mkdir -p "$WORK/界面模型/源" "$WORK/界面模型/取消" "$WORK/界面模型/中途取消" \
             "$WORK/界面模型/递归/子目录"
    ./Tests/fixture "$WORK/界面模型/源/一.jpg" >/dev/null
    ./Tests/fixture "$WORK/界面模型/源/二.jpg" >/dev/null
    # 递归开关的素材：顶层一张、子目录一张，勾与不勾的张数必须不同
    ./Tests/fixture "$WORK/界面模型/递归/顶层.jpg" >/dev/null
    ./Tests/fixture "$WORK/界面模型/递归/子目录/深处.jpg" >/dev/null
    # 素材数远多于并发度，取消才能确定性地拦下后续任务
    for i in $(seq 1 40); do
        cp "$WORK/界面模型/源/一.jpg" "$WORK/界面模型/取消/c$i.jpg"
        cp "$WORK/界面模型/源/一.jpg" "$WORK/界面模型/中途取消/d$i.jpg"
    done
    if out=$(./Tests/guimodel-test "$WORK/界面模型" 2>&1); then
        echo "$out" | grep -c '✓' | xargs -I{} echo "  ✓ 模型层集成测试 {} 项全过"
    else
        fail "界面模型测试未通过"; echo "$out" | grep '✗' | sed 's/^/     /'
    fi
else
    echo "  - 跳过（未构建 Tests/guimodel-test）"
fi

echo "9. 图形界面端到端"
if [ -x Tests/uisnapshot ]; then
    mkdir -p "$WORK/界面"
    cp "$WORK/照片.jpg" "$WORK/界面/拖入的照片.jpg"
    # 截图工具会驱动真实的窗口：加载文件、点"开始转换"、把窗口渲染成 PNG。
    Tests/uisnapshot "$WORK/界面.png" --convert "$WORK/界面" >/dev/null 2>&1
    [ -f "$WORK/界面/拖入的照片.heic" ] && pass "界面转换产出了 .heic" || fail "界面没有产出 .heic"
    [ -s "$WORK/界面.png" ] && pass "窗口渲染正常" || fail "窗口渲染失败"
    want=$(./Tests/probe "$WORK/界面/拖入的照片.jpg" '{GPS}/Latitude')
    got=$(./Tests/probe "$WORK/界面/拖入的照片.heic" '{GPS}/Latitude')
    check "界面产物同样保留 GPS" "$got" "$want"
else
    echo "  - 跳过（未构建 Tests/uisnapshot）"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "全部通过"; else echo "$FAILED 项失败"; fi
exit $((FAILED > 0))

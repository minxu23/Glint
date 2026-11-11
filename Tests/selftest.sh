#!/bin/bash
# jpeg2heif 自检：造一张元数据齐全的 JPEG，转成 HEIC，然后逐项校验。
set -uo pipefail

cd "$(dirname "$0")/.."
BIN="./jpeg2heif"
# 每次运行一个独立的工作目录（见下面 mktemp），并发的两次运行互不相干。
# 成功结束时删掉；失败或提前退出时留着供诊断，并打印路径。
WORK=""
FAILED=0
PASSED=0
ROUNDS=0
# 「少跑了却宣布通过」光看 FAILED 看不出来——没跑就没失败。下面几道守卫各管一种：
#   整轮消失 / 正文被跳过 -> 执行的断言条数对不上（EXPECTED_ASSERTIONS）
#   子套件自己缩水        -> 它自己的条数对不上（EXPECTED_UNIT / EXPECTED_GUI；
#                            子套件各自只产出 1 个 pass，总数看不见它们缩水）
#   脚本中途死掉          -> trap 兜底（结尾的检查本身都执行不到）
# 加断言时要同步改这几个数。用精确值而不是下限：下限挡不住「加了几条、
# 同时静默少了几条」。
EXPECTED_ASSERTIONS=197
EXPECTED_UNIT=415
EXPECTED_GUI=48

# 没跑到结尾就退出时，结论不可信，必须出声——哪怕 FAILED 是 0。
# 本脚本没开 `set -e`，所以它实际兜住的是：`set -u` 撞上未定义变量而中止、
# 收到信号、以及将来有人加一条不走 bail() 的 exit。前置检查是**有意**的早退
# （环境没准备好，还没开始测），走 bail() 自己说清原因，不需要 trap 再补一句。
REACHED_END=0
on_exit() {
    local status=$?
    if [ "$REACHED_END" -ne 1 ]; then
        printf '  ✗ %s\n' "脚本没有跑到结尾（提前退出），上面的结论不可信"
        status=1
    fi
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        if [ "$status" -eq 0 ]; then
            rm -rf "$WORK"
        else
            printf '工作目录保留在 %s，供诊断\n' "$WORK"
        fi
    fi
    exit "$status"
}
trap on_exit EXIT
bail() { printf '%s\n' "$1"; REACHED_END=1; exit 1; }

pass() { printf '  ✓ %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  ✗ %s\n' "$1"; FAILED=$((FAILED + 1)); }
round() { ROUNDS=$((ROUNDS + 1)); printf '%s\n' "$1"; }
# 「某一组断言有没有少跑」只有这一处实现。成功时也出声，好让这条守卫自己
# 落在 EXPECTED_ASSERTIONS 的覆盖范围里——否则它被静默删掉时没人发现。
expect_count() {
    [ "$2" -eq "$3" ] \
        && pass "$1跑满 $2 条，没有静默缩水" \
        || fail "$1跑了 $2 条，预期 $3 条（改动断言后请同步 $4）"
}
# 数「执行了多少条」而不是「通过了多少条」：一条用例失败就少一个 ✓，
# 于是守卫会跟着报「跑少了」——那是误诊。锚到行首，免得正文里出现
# ✓/✗ 的说明文字虚增计数、反而掩盖缩水。
count_assertions() { printf '%s\n' "$1" | grep -cE '^ *[✓✗]'; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (期望 [$3]，实际 [$2])"; fi; }
# 两侧都从被测对象读出来的比较用这个，不用 check：期望侧为空或是探针的
# 哨兵值（<无>、<无法读取>）时，两侧同空、同哨兵也会"相等"，比较不说明任何事。
check_same() {
    case "$3" in
        ""|"<无>"|"<无法读取>")
            fail "$1 (期望侧是 [$3]，没有可比的值)" ;;
        *)  check "$1" "$2" "$3" ;;
    esac
}
# 否定式断言（"没有…""不该…"）：命令没成功跑完时，"没看到"不说明任何事。
# 用法：refute 描述 退出码 条件命令...；退出码非 0 判失败，条件命令成立也判失败。
refute() {
    local what=$1 status=$2; shift 2
    if [ "$status" -ne 0 ]; then
        fail "$what (命令退出码 $status，没有成功跑完，否定式断言不成立)"
    elif "$@"; then
        fail "$what"
    else
        pass "$what"
    fi
}
# 一张必有差异的样本走 --delete-original：校验必须报出每一条期望文本，源文件必须留着。
# 用法：expect_reported 描述 文件 期望文本...（每条期望文本一条断言，另加源文件一条）
expect_reported() {
    local what=$1 file=$2 out st want; shift 2
    out=$("$BIN" -v --delete-original "$file" 2>&1); st=$?
    for want in "$@"; do
        if grep -qF -- "$want" <<< "$out"; then
            pass "$what：报出「$want」"
        else
            fail "$what：没报出「$want」"; sed 's/^/     /' <<< "$out"
        fi
    done
    refute "$what：源文件保留" "$st" test ! -f "$file"
}
# 造样本的那一步失败要出声，否则后面的断言测的是一张没改过的图。
make_sample() { "$@" >/dev/null 2>&1 || fail "造不出样本：$*"; }

[ -x "$BIN" ] || bail "先运行 make 构建 $BIN"

# 所有测试工具都由 Makefile 构建，这里只管用。
for tool in fixture probe; do
    [ -x "Tests/$tool" ] || bail "先运行 make test（缺 Tests/$tool）"
done
# 产物不仅要存在，还得是当前源码建出来的：绕过 make 直接 `bash Tests/selftest.sh`
# 时，几个来自不同源码版本的二进制一起跑，会得出任何单一版本都不会给出的结论。
#
# 清单和依赖都交给 make，不在这里自己攒：
#   清单——只有 Makefile 的 ARTIFACTS 一份。`make -q` 对「文件存在但不属于任何
#     规则」也退出 0，所以这里抄一份名字、一旦对不上，守卫会静默退化成空跑。
#   依赖——每个产物依赖哪些源文件只有 Makefile 知道（Tests/fixture 只依赖
#     自己那一个文件，Tests/probe 还依赖整个 Sources/Core），自己比 mtime 等于
#     重写一份依赖表。`make -q` 是只读的问询模式，不执行任何规则，所以从
#     make test 里反过来调它不会递归。
# 不吞 stderr：Makefile 真出语法错时，错误本身比「问不到清单」有用得多。
artifacts=$(make --no-print-directory print-artifacts) \
    || bail "问不到产物清单（make print-artifacts 失败，原因见上）"
[ -n "$artifacts" ] || bail "产物清单是空的（print-artifacts 没出声）"
for art in $artifacts; do
    # 缺产物在这里就停：跳过等于「缺了就算通过」。
    [ -e "$art" ] || bail "缺 $art——先运行 make test"
    # 从 make test 里调用时，外层的标志经 MAKEFLAGS/MFLAGS 传进来；`-B` 会让
    # `make -q` 把一切都当成过期。问询只问文件本身新不新，所以清掉继承的标志。
    env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL make -q "$art" >/dev/null 2>&1 \
        || bail "$art 不是当前源码建出来的——先运行 make test，别直接跑本脚本"
done
WORK=$(mktemp -d Tests/.work.XXXXXX) || bail "建不出工作目录"
mkdir -p "$WORK/相册/子目录"
./Tests/fixture "$WORK/照片.jpg" >/dev/null || bail "造不出测试图，环境不对"
xattr -w com.apple.metadata:kMDItemFinderComment "访达备注" "$WORK/照片.jpg"

round "0. 校验规则单元测试"
# 把子套件自己的断言条数也钉住：这一轮对总数只贡献 1 个 pass，单测缩水
# 在总数里看不出来。
unit_out=$(Tests/unit-test 2>&1); unit_ok=$?
unit_n=$(count_assertions "$unit_out")
if [ "$unit_ok" -eq 0 ]; then
    pass "值比较与 MakerNote 归类规则"
else
    fail "值比较规则有用例不通过"; printf '%s\n' "$unit_out" | grep '✗' | sed 's/^/     /'
fi
expect_count "单测" "$unit_n" "$EXPECTED_UNIT" EXPECTED_UNIT

round "1. 单文件转换 + 元数据校验"
OUT=$("$BIN" --verify -v "$WORK/照片.jpg" 2>&1)
echo "$OUT" | grep -q "元数据校验通过" && pass "校验通过，无任何丢失" || { fail "校验报告了差异"; echo "$OUT" | sed 's/^/     /'; }
[ -f "$WORK/照片.heic" ] && pass "生成了 .heic" || fail "没有生成 .heic"

# 逐个关键字段对比源 JPEG 与产物 HEIC —— 断言的是"和源文件一致"，
# 而不是某个写死的值，这样测试不会被生成夹具时的编码行为带偏。
round "2. 关键字段与源文件逐项一致"
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
{IPTC}/StarRating
XMP/xmp:Label'
while IFS= read -r key; do
    want=$(./Tests/probe "$WORK/照片.jpg" "$key")
    got=$(./Tests/probe "$WORK/照片.heic" "$key")
    check_same "$key" "$got" "$want"
done <<< "$KEYS"

# 属性字典表达不了的 XMP：多语言标题、层级关键词、人脸区域、xmpMM、自定义命名空间。
./Tests/fixture --rich-xmp "$WORK/富XMP.jpg" >/dev/null
check "前提：富 XMP 样本里确实有人脸区域的名字" \
    "$(./Tests/probe "$WORK/富XMP.jpg" 'XMP/mwg-rs:Regions.RegionList[0].Name')" "张三"
rich_out=$("$BIN" --verify -v "$WORK/富XMP.jpg" 2>&1)
grep -q "元数据校验通过" <<< "$rich_out" \
    && pass "富 XMP 整包搬过去，校验通过" \
    || { fail "富 XMP 有标签没搬过去"; sed 's/^/     /' <<< "$rich_out"; }
# 扩展 XMP 段：ImageIO 读源时把它并进 XMP，转换时随 XMP 一起搬走，所以这个段
# 不算"搬不走"；里面的标签真丢了由键空间比对报。
./Tests/fixture --extended-xmp "$WORK/扩展XMP.jpg" >/dev/null
check "前提：扩展 XMP 里的标签读得到" \
    "$(./Tests/probe "$WORK/扩展XMP.jpg" 'XMP/jt:Extended')" "只在扩展包里的值"
ext_out=$("$BIN" --verify -v "$WORK/扩展XMP.jpg" 2>&1)
grep -q "元数据校验通过" <<< "$ext_out" \
    && pass "扩展 XMP 搬过去，校验通过" \
    || { fail "扩展 XMP 的样本报了差异"; sed 's/^/     /' <<< "$ext_out"; }

round "3. 文件层元数据"
check_same "修改时间一致" \
    "$(stat -f %m "$WORK/照片.heic")" "$(stat -f %m "$WORK/照片.jpg")"
check_same "访达备注保留" \
    "$(xattr -p com.apple.metadata:kMDItemFinderComment "$WORK/照片.heic" 2>/dev/null)" \
    "$(xattr -p com.apple.metadata:kMDItemFinderComment "$WORK/照片.jpg" 2>/dev/null)"

round "4. 指定文件夹批量转换"
cp "$WORK/照片.jpg" "$WORK/相册/a.jpg"
cp "$WORK/照片.jpg" "$WORK/相册/子目录/a.jpg"
cp "$WORK/照片.jpg" "$WORK/相册/大写扩展名.JPG"
cp "$WORK/照片.heic" "$WORK/相册/已有产物.heic"
echo "not an image" > "$WORK/相册/说明.txt"

# 只挑 JPEG：3 张（含一张大写扩展名），跳过 .heic 与 .txt
n=$("$BIN" -n -r "$WORK/相册" 2>/dev/null | grep -c '预演')
check "从混合内容里挑出 JPEG 的张数" "$n" "3"

"$BIN" -r "$WORK/相册" -o "$WORK/结果" >/dev/null 2>&1; st=$?
[ -f "$WORK/结果/a.heic" ] && [ -f "$WORK/结果/子目录/a.heic" ] \
    && pass "同名文件未互相覆盖" || fail "目录结构未保持"
[ -f "$WORK/结果/大写扩展名.heic" ] && pass "大写 .JPG 也被处理" || fail "漏掉大写扩展名"
refute "跳过已有 .heic 与非图片" "$st" \
    test -e "$WORK/结果/已有产物.heic" -o -e "$WORK/结果/说明.heic"

# 非递归时只看顶层，不下钻子目录
n=$("$BIN" -n "$WORK/相册" 2>/dev/null | grep -c '预演')
check "非递归只处理顶层" "$n" "2"

round "4b. 多输入根重名不丢文件"
# A/a.jpg 与 B/a.jpg 都会映射到 OUT/a.heic；两个任务并发时各自看到目标不存在
# 便双双写入，后者会静默覆盖前者。
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

# 同一个根在冲突组里贡献多个文件：传给逐级上溯的根数组含重复元素，"互异短名"
# 的判据要按去重后的根算。上面那个用例每根只放一张，走不到这条路径。
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
out=$("$BIN" -r "$WORK/相册" -o "$WORK/无冲突" 2>&1); st=$?
refute "无冲突时不改名、不报避让" "$st" grep -q "重名避让" <<< "$out"

round "5. 安全行为"
"$BIN" "$WORK/照片.jpg" 2>&1 | grep -q "输出已存在" && pass "不覆盖已有输出" || fail "应拒绝覆盖"
"$BIN" -q 2 "$WORK/照片.jpg" >/dev/null 2>&1; [ $? -eq 2 ] && pass "拒绝非法质量值" || fail "应拒绝非法质量值"
echo "not an image" > "$WORK/坏.jpg"
"$BIN" "$WORK/坏.jpg" 2>&1 | grep -q "不是 JPEG" && pass "跳过非 JPEG 文件" || fail "应跳过非 JPEG"
# 探针自己也得分清「整个文件读不出来」和「这个键不存在」。两者都报「无」时，
# 不合规范 UserComment 那一轮的前提断言（seen = <无> 即算「ImageIO 读不出这种
# 写法」）在文件整体读不出来时也会通过。CGImageSourceCreateWithURL 对垃圾文件
# 会成功，所以这条必须拿一个真的垃圾文件来验，不能拿不存在的路径。
for mode in "" "--no-repair"; do
    v=$(./Tests/probe $mode "$WORK/坏.jpg" '{Exif}/UserComment')
    [ "$v" = "<无法读取>" ] \
        && pass "探针对垃圾文件报「无法读取」而不是「无」${mode:+（$mode）}" \
        || fail "探针把读取失败报成了 [$v]${mode:+（$mode）}"
done

round "6. 不合规范的 UserComment（无字符集前缀的裸 UTF-8）"
# 很多安卓机型这么写，ImageIO 认不出来会整条丢掉，工具需要自己解析补回。
NOTE="鲁汶市政厅是比利时最美的市政厅"
cp "$WORK/照片.jpg" "$WORK/无前缀.jpg"
if Tests/mangle-tool "$WORK/无前缀.jpg" "$NOTE" >/dev/null 2>&1; then
    # 先确认 ImageIO 自己确实读不出来，否则这个用例就没在测该测的东西。
    # 必须加 --no-repair：默认模式走的是 --verify 那条路，里面已经含了本轮要测的
    # UserComment 修补，拿它问等于先把答案填进去再考。
    seen=$(./Tests/probe --no-repair "$WORK/无前缀.jpg" '{Exif}/UserComment')
    # 只接受恰好的「无」：空串可能是 probe 本身没出声，那会让这条前提在工具
    # 坏掉时也通过。
    [ "$seen" = "<无>" ] \
        && pass "确认 ImageIO 读不出这种写法" \
        || fail "前提不成立：ImageIO 读出了 [$seen]"
    # 非空守卫：上面那条只有在文件**本身读得出来**时才说明问题。同一个文件、
    # 换一个键必须读得到值。
    alive=$(./Tests/probe --no-repair "$WORK/无前缀.jpg" '{Exif}/DateTimeOriginal')
    case "$alive" in
        2024*) pass "该文件本身读得出来（上一条前提非空）" ;;
        *) fail "换个键也读不到值（[$alive]）——上一条前提失去意义" ;;
    esac
    "$BIN" -f "$WORK/无前缀.jpg" >/dev/null 2>&1
    got=$(./Tests/probe "$WORK/无前缀.heic" '{Exif}/UserComment')
    check "备注被捞回并写入 HEIC" "$got" "$NOTE"
else
    fail "无法构造测试样本"
fi

round "6b. 带 UNICODE 前缀的非 ASCII UserComment，字段里填充不够"
# 字段长度沿用夹具的 48 字节正文区，文本原地写进去：B 型剩 2 字节 NUL，D 型正好
# 占满。ImageIO 的 HEIC 写入器只写进传给它的 UTF-16 单元数的一半，ASCII 打头的
# 文本还会被当成 ASCII 写、汉字变成「?」（规则见 userCommentForHEIFWriter）。
# 比的是产物与写进去的原文，不是与源的探针值：两边同样读错时探针值也相等。
i=0
while IFS='|' read -r what text; do
    i=$((i + 1))
    f="$WORK/UNICODE备注$i.jpg"
    cp "$WORK/照片.jpg" "$f"
    make_sample ./Tests/mangle-tool --unicode-comment "$f" "$text"
    check "$what：前提，ImageIO 从源里读得出全文" \
        "$(./Tests/probe --no-repair "$f" '{Exif}/UserComment')" "$text"
    out=$("$BIN" --verify -v "$f" 2>&1)
    grep -q "元数据校验通过" <<< "$out" \
        && pass "$what：校验通过" \
        || { fail "$what：校验报了差异"; sed 's/^/     /' <<< "$out"; }
    check "$what：产物里的备注与原文逐字相同" \
        "$(./Tests/probe "${f%.jpg}.heic" '{Exif}/UserComment')" "$text"
done <<'EOF'
B 型（23 个字，剩 2 字节填充）|备注：这是拍摄当时写下的一段说明文字，用于测试
D 型（24 个字，零填充）|备注：这是拍摄当时写下的一段说明文字，用于测试啊
含 emoji（代理对）|🎉拍照😀好看👍今天天气很好适合出门啊啊
ASCII 打头的中英混排|Leuven 鲁汶 City Hall 市政厅
汉字打头的中英混排|鲁汶市政厅 City Hall 2024
EOF

round "7. --delete-original 的安全边界"
# 全套功能里唯一会删除用户文件的一条，它的安全性完全依赖「校验不通过就不删」。
cp "$WORK/照片.jpg" "$WORK/可删.jpg"
"$BIN" --delete-original "$WORK/可删.jpg" >/dev/null 2>&1
[ -f "$WORK/可删.heic" ] && [ ! -e "$WORK/可删.jpg" ] \
    && pass "校验无损时才删除源文件" || fail "无损却没删，或没产出 .heic"

# 反向：有真实丢失时必须保留源文件。这是最关键的一条。
./Tests/fixture --lossy "$WORK/有损.jpg" >/dev/null
out=$("$BIN" --delete-original "$WORK/有损.jpg" 2>&1); st=$?
refute "校验有差异时保留源文件（反例即源文件被误删，不可逆）" "$st" test ! -f "$WORK/有损.jpg"
[ -f "$WORK/有损.heic" ] && pass "同时仍产出 .heic 供人工比对" || fail "没产出 .heic"
echo "$out" | grep -q "保留了源文件" && pass "明确告知保留了源文件" || fail "没说明为何没删"
# --delete-original 必须隐含校验：不加 --verify 也要比对，否则等于无校验删除
echo "$out" | grep -q "差异" && pass "未加 --verify 也执行了校验" || fail "没做校验就动了源文件"

# 那句说明是状态，不是元数据差异，不能计入差异条数（界面的橙色徽章和弹窗标题
# 也用这个数）。加不加 --delete-original，差异条数必须一样。
./Tests/fixture --lossy "$WORK/计数.jpg" >/dev/null
n1=$("$BIN" --verify "$WORK/计数.jpg" 2>&1 | grep -oE '发现 [0-9]+ 处差异')
rm -f "$WORK/计数.heic"
n2=$("$BIN" --delete-original "$WORK/计数.jpg" 2>&1 | grep -oE '发现 [0-9]+ 处差异')
check_same "状态说明不计入差异条数" "$n2" "$n1"

# 预演不该在磁盘上留下任何痕迹，包括输出目录
"$BIN" -n -r "$WORK/相册" -o "$WORK/预演输出" >/dev/null 2>&1; st=$?
refute "预演不创建输出目录" "$st" test -e "$WORK/预演输出"

# 预演绝不能删任何东西
cp "$WORK/照片.jpg" "$WORK/预演不删.jpg"
"$BIN" -n --delete-original "$WORK/预演不删.jpg" >/dev/null 2>&1; st=$?
refute "预演不删源文件" "$st" test ! -f "$WORK/预演不删.jpg"

# 真实相机照片：MakerNote 必然丢失，校验必须报出汇总行，--delete-original 不能删源。
# 用拷贝，test_pic/ 里的原件不可再生。截掉 EOI 之后的 MPF 预览图，让 MakerNote
# 成为这张图唯一的差异——"源文件保留"这条于是只由 MakerNote 那一行撑着。
cp test_pic/P1130939.JPG "$WORK/相机.jpg"
make_sample ./Tests/mangle-tool --strip-trailer "$WORK/相机.jpg"
expect_reported "相机照片丢失 MakerNote" "$WORK/相机.jpg" "丢失 厂商私有数据 MakerNote"

round "7b. 偏移只靠 XMP 承载"
# IIM 时间后缀里的偏移，在目标里的唯一承载是 ImageIO 合成的
# XMP/photoshop:DateCreated——前提是源里没有 EXIF OffsetTime*。默认那张夹具图
# 自己带 OffsetTimeOriginal，offsetSurvives 在第一条就命中，等价字段（XMP 那条
# 腿）怎么写都不影响结果。这一轮专门造一张只靠 XMP 承载的图，把那条腿接上。
./Tests/fixture --no-exif-offset "$WORK/仅XMP偏移.jpg" >/dev/null
xmp_out=$("$BIN" --verify "$WORK/仅XMP偏移.jpg" 2>&1)
echo "$xmp_out" | grep -q "元数据校验通过" \
    && pass "偏移只靠 XMP 承载时校验也通过" \
    || { fail "偏移只靠 XMP 承载却报了差异"; echo "$xmp_out" | sed 's/^/     /'; }
# 非空断言：这一轮只有在源和目标都确实没有任何 OffsetTime* 时才说明问题。
# 哪天 ImageIO 开始自己补一个，上面那条就退化成空跑，必须在这里喊出来。
# 探的键必须是 offsetSurvives 真会去找的那一整套（utcOffsetKeys），EXIF 和
# XMP 两侧都要——只守一半的话，另一半照样能让整轮静默退化。
# 循环里只收集，循环后恰好发一条结论。
present=""
for f in "$WORK/仅XMP偏移.jpg" "$WORK/仅XMP偏移.heic"; do
    for k in OffsetTime OffsetTimeOriginal OffsetTimeDigitized; do
        for key in "{Exif}/$k" "XMP/exif:$k"; do
            v=$(./Tests/probe "$f" "$key" 2>/dev/null | tail -1)
            [ "$v" = "<无>" ] || present="$present $(basename "$f"):$key=[$v]"
        done
    done
done
[ -z "$present" ] \
    && pass "该样本里确实没有任何 OffsetTime*（上一条断言非空）" \
    || fail "样本里有 OffsetTime*，上一条断言失去意义:$present"
# 正面指认承载者：偏移必须真的长在目标的 XMP 时间戳里，而不是"碰巧没人追究"。
v=$(./Tests/probe "$WORK/仅XMP偏移.heic" "XMP/photoshop:DateCreated")
case "$v" in
    *+08:00) pass "目标的 XMP/photoshop:DateCreated 带着 +08:00（[$v]）" ;;
    *) fail "目标的 XMP/photoshop:DateCreated 没带偏移（[$v]）——承载者另有其人" ;;
esac

round "7c. ImageIO 视图之外的源数据"
# 源侧的时间以原始字节为准。ImageIO 读 JPEG 时会把 EXIF、IIM、XMP 的时间互相
# 调和，只看它的属性视图，源文件里实际写着的时间与偏移会在比对前被抹掉。
# 只改 EXIF：EXIF 里的时间等长改成 18:42:08，IIM 的 184207+0800 与 XMP 的 +08:00 不动。
./Tests/fixture --no-exif-offset "$WORK/只改EXIF.jpg" >/dev/null
make_sample ./Tests/mangle-tool --replace "$WORK/只改EXIF.jpg" "2024:09:15 18:42:07" "2024:09:15 18:42:08"
# 前提：视图里 IIM 时间确实被调和掉了，否则这张图测不到源侧读原始字节那一路。
check "前提：ImageIO 视图把 IIM 时间调和成 EXIF 的 184208" \
    "$(./Tests/probe "$WORK/只改EXIF.jpg" '{IPTC}/TimeCreated')" "184208"
expect_reported "只改过 EXIF 时间" "$WORK/只改EXIF.jpg" "丢失 {IPTC}/TimeCreated = 184207+0800"
# 只改 IIM：视图里的 EXIF 拍摄时间会跟着 IIM 变成 10:42:07。
./Tests/fixture "$WORK/只改IIM.jpg" >/dev/null
make_sample ./Tests/mangle-tool --replace "$WORK/只改IIM.jpg" "184207+0800" "104207+0000"
check "前提：ImageIO 视图把 EXIF 拍摄时间调和成 IIM 的 10:42:07" \
    "$(./Tests/probe "$WORK/只改IIM.jpg" '{Exif}/DateTimeOriginal')" "2024:09:15 10:42:07"
expect_reported "只改过 IIM 时间" "$WORK/只改IIM.jpg" \
    "变化 {Exif}/DateTimeOriginal: 2024:09:15 18:42:07 → 2024:09:15 10:42:07"

# ImageIO 不读的段：COM 注释、不认识的 APPn（APP11 是 C2PA 用的）、EOI 之后的数据。
cp "$WORK/照片.jpg" "$WORK/注释段.jpg"
make_sample ./Tests/mangle-tool --segment "$WORK/注释段.jpg" FE "JPEG 注释段里的备注"
expect_reported "COM 注释段" "$WORK/注释段.jpg" "丢失 JPEG 注释段（COM）= JPEG 注释段里的备注"
cp "$WORK/照片.jpg" "$WORK/APP11.jpg"
make_sample ./Tests/mangle-tool --segment "$WORK/APP11.jpg" EB "JP c2pa 内容凭证"
expect_reported "APP11 段" "$WORK/APP11.jpg" "丢失 APP11 段（JP c2pa "
cp "$WORK/照片.jpg" "$WORK/尾部数据.jpg"
make_sample ./Tests/mangle-tool --append "$WORK/尾部数据.jpg" "动态照片的视频放在这里"
expect_reported "EOI 之后的数据" "$WORK/尾部数据.jpg" "丢失 EOI 之后的 33 字节"

# CMYK 的 ICC 描述文件和色彩模型被换成 sRGB/RGB，必须报。
./Tests/fixture --cmyk "$WORK/CMYK.jpg" >/dev/null
expect_reported "CMYK 被转成 RGB" "$WORK/CMYK.jpg" \
    "变化 ColorModel: CMYK → RGB" "变化 ProfileName: Generic CMYK Profile → sRGB"

round "7d. ImageIO 不读的 Windows 标签与 Photoshop 资源"
# Windows 资源管理器写在 IFD0 的 XP 标签和评级，ImageIO 不读也不搬。目标里有等价字段
# 带着同一个值才算承载。三张样本：没有等价字段、等价字段同值、等价字段不同值。
./Tests/fixture --no-text "$WORK/只有XP.jpg" >/dev/null
make_sample ./Tests/mangle-tool --ifd0 "$WORK/只有XP.jpg" '9C9B=XP标题' '9C9C=XP备注' \
    '9C9D=作者甲;作者乙' '9C9E=关键词一;关键词二' '9C9F=XP主题' '4746=4' '4749=75'
expect_reported "只有 Windows 标签" "$WORK/只有XP.jpg" \
    "丢失 Windows 标题 XPTitle（IFD0 0x9C9B） = XP标题" \
    "丢失 Windows 备注 XPComment（IFD0 0x9C9C） = XP备注" \
    "丢失 Windows 作者 XPAuthor（IFD0 0x9C9D） = 作者甲;作者乙" \
    "丢失 Windows 关键词 XPKeywords（IFD0 0x9C9E） = 关键词一;关键词二" \
    "丢失 Windows 主题 XPSubject（IFD0 0x9C9F） = XP主题" \
    "丢失 Windows 评级 Rating（IFD0 0x4746） = 4" \
    "丢失 Windows 评级百分比 RatingPercent（IFD0 0x4749） = 75"
# 同值：每个标签都抄一份目标里会有的标准字段。Artist 改成带分号的两个作者，
# 和 test_pic/IMG_1225.JPG 的情形一样；XPComment 抄源里 UserComment 实际存的值。
./Tests/fixture --ms-rating "$WORK/XP同值.jpg" >/dev/null
note=$(./Tests/probe "$WORK/XP同值.jpg" '{Exif}/UserComment')
make_sample ./Tests/mangle-tool --ifd0 "$WORK/XP同值.jpg" '013B=作者甲;作者乙' \
    '9C9B=西湖日落 sunset at West Lake' "9C9C=$note" '9C9D=作者甲;作者乙' '9C9E=sunset;hangzhou' \
    '4746=5' '4749=99'
same_out=$("$BIN" --verify "$WORK/XP同值.jpg" 2>&1)
case "$note" in
    ""|"<无>"|"<无法读取>") fail "前提：源里读不出 UserComment（[$note]），XPComment 那一行没测到" ;;
    *) grep -q "元数据校验通过" <<< "$same_out" \
           && pass "Windows 标签与等价字段同值，不报" \
           || { fail "Windows 标签与等价字段同值却报了差异"; sed 's/^/     /' <<< "$same_out"; } ;;
esac
./Tests/fixture --ms-rating "$WORK/XP不同值.jpg" >/dev/null
make_sample ./Tests/mangle-tool --ifd0 "$WORK/XP不同值.jpg" '9C9B=另一个标题' '9C9C=另一段备注' \
    '9C9D=另一个作者' '9C9E=sunset;另一个关键词' '4746=2' '4749=25'
expect_reported "Windows 标签与等价字段不同值" "$WORK/XP不同值.jpg" \
    "丢失 Windows 标题 XPTitle（IFD0 0x9C9B） = 另一个标题" \
    "丢失 Windows 备注 XPComment（IFD0 0x9C9C） = 另一段备注" \
    "丢失 Windows 作者 XPAuthor（IFD0 0x9C9D） = 另一个作者" \
    "丢失 Windows 关键词 XPKeywords（IFD0 0x9C9E） = sunset;另一个关键词" \
    "丢失 Windows 评级 Rating（IFD0 0x4746） = 2" \
    "丢失 Windows 评级百分比 RatingPercent（IFD0 0x4749） = 25"
# 真实照片：IMG_1225 的 XPAuthor 与 Artist 同值，不能报；把 Artist 改掉就必须报——
# 后一条同时证明前一条不是因为根本没读到 XPAuthor 才安静。
cp test_pic/IMG_1225.JPG "$WORK/XP作者.jpg"
out=$("$BIN" --verify "$WORK/XP作者.jpg" 2>&1); st=$?
refute "IMG_1225 的 XPAuthor 由同值的 Artist 承载，不报" "$st" grep -qF "XPAuthor" <<< "$out"
cp test_pic/IMG_1225.JPG "$WORK/XP作者改.jpg"
make_sample ./Tests/mangle-tool --ifd0 "$WORK/XP作者改.jpg" '013B=Someone Else'
expect_reported "IMG_1225 改掉 Artist" "$WORK/XP作者改.jpg" \
    "丢失 Windows 作者 XPAuthor（IFD0 0x9C9D） = Zhang San;Li Si"
# APP13 里 IPTC 以外的资源：默认夹具本来就有 0x0404 和 0x0425，第 1 轮守着它们不报；
# 追加一个 0x0BB7 就必须报出汇总行。
cp "$WORK/照片.jpg" "$WORK/PS资源.jpg"
make_sample ./Tests/mangle-tool --8bim "$WORK/PS资源.jpg" 0BB7 "Photoshop 资源里的标记串"
expect_reported "APP13 里的其它 Photoshop 资源" "$WORK/PS资源.jpg" \
    "丢失 APP13 里的 1 个 Photoshop 资源（0x0BB7）"

round "7e. 辅助图搬进产物"
# 每种辅助图一张合成样本，内容有纹理（每种图案不同）。逐张断言：产物里有同类型、
# 同尺寸、同像素格式的辅助图；数据与源的最大差不超过 AUX_MAX_DIFF；附带元数据的标签
# 与源相同；校验通过、--delete-original 删了源。源的副本放在另一个目录里留作比对。
# AUX_MAX_DIFF 的单位是 8 位级数（浮点类型按源取值范围的 1/255 为一级，见 probe）。
# 8 位与浮点类型都被重新有损编码：这些样本上量到 3，四张真实 HDR 照片的增益图量到
# 5–8；质量参数（-q 0 到 1）不影响辅助图，产物里的辅助图数据逐字节相同。
AUX_MAX_DIFF=8
mkdir -p "$WORK/辅助图/源副本"
while IFS='|' read -r what type flags; do
    f="$WORK/辅助图/$type.jpg" ref="$WORK/辅助图/源副本/$type.jpg"
    # shellcheck disable=SC2086  # flags 是要拆开的多个参数
    make_sample ./Tests/fixture $flags "$f"
    cp "$f" "$ref"
    out=$("$BIN" -v --delete-original "$f" 2>&1); st=$?
    grep -q "元数据校验通过" <<< "$out" \
        && pass "$what：校验通过" \
        || { fail "$what：校验报了差异"; sed 's/^/     /' <<< "$out"; }
    refute "$what：校验通过后删了源" "$st" test -e "$f"
    heic="${f%.jpg}.heic"
    check_same "$what：产物里有同类型的辅助图，尺寸与像素格式相同" \
        "$(./Tests/probe --aux "$heic" "$type")" "$(./Tests/probe --aux "$ref" "$type")"
    diff=$(./Tests/probe --aux-diff "$ref" "$heic" "$type")
    [[ "$diff" =~ ^[0-9]+$ ]] && [ "$diff" -le "$AUX_MAX_DIFF" ] \
        && pass "$what：数据与源的最大差 $diff 级，不超过 $AUX_MAX_DIFF" \
        || fail "$what：数据与源的最大差是 [$diff]，上界 $AUX_MAX_DIFF"
    check_same "$what：附带元数据的标签与源相同" \
        "$(./Tests/probe --aux-tags "$heic" "$type")" "$(./Tests/probe --aux-tags "$ref" "$type")"
    # ImageIO 的视图每种辅助图只给一份；同一张图写了两份（增益图既随主图带、又单独加一次）
    # 只能数 HEIF 里的辅助图项。
    check "$what：产物里只有 1 个辅助图项" "$(./Tests/probe --aux-items "$heic")" "1"
done <<'EOF'
深度图|Depth|--aux depth
视差图|Disparity|--aux disparity
人像蒙版|PortraitEffectsMatte|--aux matte
皮肤蒙版|SemanticSegmentationSkinMatte|--aux skin
增益图（带缩略图）|HDRGainMap|--aux gainmap --thumbnail
EOF
# 增益图那张：元数据是真的苹果增益图标签，值要和夹具写进去的一样；按 HDR 解码，
# 产物的内容余量要和源一样（源的余量就是夹具写的 HDRGainMapHeadroom）。
gain="$WORK/辅助图/HDRGainMap.heic" gain_ref="$WORK/辅助图/源副本/HDRGainMap.jpg"
tags=$(./Tests/probe --aux-tags "$gain" HDRGainMap)
for want in "XMP/HDRGainMap:HDRGainMapVersion=131072" "XMP/HDRGainMap:HDRGainMapHeadroom=3.5"; do
    grep -qxF "$want" <<< "$tags" && pass "增益图：产物里 $want" || fail "增益图：产物里没有 $want（[$tags]）"
done
check "增益图：前提，源按 HDR 解码的内容余量" "$(./Tests/probe --headroom "$gain_ref")" "3.50"
check_same "增益图：产物按 HDR 解码的内容余量与源相同" \
    "$(./Tests/probe --headroom "$gain")" "$(./Tests/probe --headroom "$gain_ref")"
# 缩略图：带辅助图的 JPEG 在 {FileContents}/Images[n]/ThumbnailImages[m]/… 下列出
# 内嵌缩略图，产物里没有。缩略图有意不报（README），这组键也不报。
v=$(./Tests/probe "$gain_ref" '{FileContents}/Images[0]/ThumbnailImages[0]/Width')
case "$v" in
    ""|"<无>"|"<无法读取>") fail "缩略图：前提不成立，源里没有 ThumbnailImages 这组键（[$v]）" ;;
    *) pass "缩略图：前提，源里有 ThumbnailImages 这组键（Width = $v）" ;;
esac
out=$("$BIN" --verify "$gain_ref" -o "$WORK/辅助图/缩略图.heic" 2>&1); st=$?
refute "缩略图：校验不报 ThumbnailImages 这组键" "$st" grep -qF "ThumbnailImages" <<< "$out"

# 尾部记账：辅助图在 JPEG 里放在 EOI 之后、由 MPF 登记。搬进产物的那几段不报，其余照报。
# 真实相机照片的 EOI 之后是一张大尺寸预览图，不是辅助图，搬不走。
cp test_pic/P1130939.JPG "$WORK/辅助图/带预览图.jpg"
expect_reported "EOI 之后是预览图" "$WORK/辅助图/带预览图.jpg" \
    "丢失 EOI 之后的 845456 字节（MPF 多图格式的附加图像）"
./Tests/fixture --aux gainmap "$WORK/辅助图/辅助图加尾巴.jpg" >/dev/null
make_sample ./Tests/mangle-tool --append "$WORK/辅助图/辅助图加尾巴.jpg" "动态照片的视频放在这里"
expect_reported "辅助图后面另有数据" "$WORK/辅助图/辅助图加尾巴.jpg" "丢失 EOI 之后的 33 字节（尾部共 "
# 增益图随主图一起写（排在别的辅助图前面），别的辅助图逐个加，产物里的先后与源不同。
# 校验按辅助图类型对齐，不能因为换了顺序报一串变化。
./Tests/fixture --aux depth --aux matte --aux gainmap "$WORK/辅助图/三种.jpg" >/dev/null
out=$("$BIN" --verify "$WORK/辅助图/三种.jpg" 2>&1)
grep -q "元数据校验通过" <<< "$out" \
    && pass "深度图、蒙版、增益图同在：校验通过" \
    || { fail "深度图、蒙版、增益图同在却报了差异"; sed 's/^/     /' <<< "$out"; }

round "7f. 3 通道的 ISO 增益图"
# 手机 HDR 照片的增益图可以是 3 通道的（像素格式 '420f'）。ImageIO 取出的字典里没有
# 数据键，交给 AddAuxiliaryDataInfo 时收尾照样成功、产物里却没有增益图；要靠
# PreserveGainMap 带过去。单通道的 ISO 增益图同一条路，一并验。
mkdir -p "$WORK/ISO增益图/源副本"
./Tests/fixture --iso-gainmap "$WORK/ISO增益图/单通道.jpg" >/dev/null || fail "造不出带 ISO 增益图的样本"
cp "$WORK/ISO增益图/单通道.jpg" "$WORK/ISO增益图/彩色.jpg"
make_sample ./Tests/mangle-tool --color-gainmap "$WORK/ISO增益图/彩色.jpg"
check "前提：彩色那张的增益图像素格式是 420f（875704422）" \
    "$(./Tests/probe --aux "$WORK/ISO增益图/彩色.jpg" ISOGainMap)" "600x450 875704422"
check "前提：单通道那张的增益图像素格式是 L008（1278226488）" \
    "$(./Tests/probe --aux "$WORK/ISO增益图/单通道.jpg" ISOGainMap)" "600x450 1278226488"
for what in 彩色 单通道; do
    f="$WORK/ISO增益图/$what.jpg" ref="$WORK/ISO增益图/源副本/$what.jpg"
    cp "$f" "$ref"
    check "$what：前提，源按 HDR 解码的内容余量" "$(./Tests/probe --headroom "$ref")" "4.00"
    # 校验通过同时说明主图里的 ISO 21496 版本标记段不再报成丢失。
    out=$("$BIN" -v --delete-original "$f" 2>&1); st=$?
    grep -q "元数据校验通过" <<< "$out" \
        && pass "$what：校验通过（含 ISO 21496 版本标记段不报）" \
        || { fail "$what：校验报了差异"; sed 's/^/     /' <<< "$out"; }
    refute "$what：校验通过后删了源" "$st" test -e "$f"
    heic="${f%.jpg}.heic"
    check_same "$what：产物里有 ISO 增益图，尺寸与像素格式相同" \
        "$(./Tests/probe --aux "$heic" ISOGainMap)" "$(./Tests/probe --aux "$ref" ISOGainMap)"
    check_same "$what：产物按 HDR 解码的内容余量与源相同" \
        "$(./Tests/probe --headroom "$heic")" "$(./Tests/probe --headroom "$ref")"
    # 余量只是元数据里的数；按 HDR 解码出来的最亮像素才说明增益图在起作用。
    # 单位是 SDR 白的百分之一；没有增益图时只剩 SDR 的亮度（这张图上约 80）。
    peak_src=$(./Tests/probe --hdr-peak "$ref") peak_dst=$(./Tests/probe --hdr-peak "$heic")
    if [[ "$peak_src" =~ ^[0-9]+$ && "$peak_dst" =~ ^[0-9]+$ ]] && [ "$peak_src" -gt 200 ] \
        && [ $(( (peak_dst - peak_src) * (peak_dst - peak_src) * 100 )) -le $(( peak_src * peak_src )) ]; then
        pass "$what：按 HDR 解码的最亮值与源相差不到 10%（$peak_src → $peak_dst）"
    else
        fail "$what：按 HDR 解码的最亮值 [$peak_src] → [$peak_dst]，源要明显高于 SDR、两边相差不到 10%"
    fi
done
# 版本标记段只在产物里真有 ISO 增益图时才算带过去。截掉增益图（EOI 之后），只剩主图里
# 孤立的标记段——真实照片里也有这样的——必须照报。
cp "$WORK/ISO增益图/源副本/单通道.jpg" "$WORK/ISO增益图/只有标记段.jpg"
make_sample ./Tests/mangle-tool --strip-trailer "$WORK/ISO增益图/只有标记段.jpg"
check "前提：截掉之后源里没有增益图" "$(./Tests/probe --aux "$WORK/ISO增益图/只有标记段.jpg" ISOGainMap)" "<无>"
expect_reported "只有 ISO 21496 标记段、没有增益图" "$WORK/ISO增益图/只有标记段.jpg" \
    "丢失 APP2 段（urn:iso:std:iso:ts:21496:-1，32 字节）"

round "7g. ImageIO 读不出的 EXIF 标签"
# 两边都走 ImageIO 视图时，ImageIO 在源一侧就读不出的标签两边都看不见。原始清点直接
# 读两边的 TIFF 结构。必须报：ASCII 类型的 GPSProcessingMethod、LONG 类型的 LightSource、
# 不认识的私有标签、放在 Exif 子 IFD 里的 DocumentName（实测 ImageIO 不读它，也不会把它
# 挪到 IFD0）、重复三次的短 MakerNote（合成一行）。
./Tests/fixture "$WORK/读不出的标签.jpg" >/dev/null
make_sample ./Tests/mangle-tool --tags "$WORK/读不出的标签.jpg" 'gps:001B:ascii=CELLID' 'exif:9208:long=0' \
    'exif:C000:ascii=私有串' 'exif:010D:ascii=放错位置的文档名' \
    'exif:927C:undef=J' 'exif:927C:undef=##**N4206_vivi' 'exif:927C:undef=Auto'
expect_reported "ImageIO 读不出的 EXIF 标签" "$WORK/读不出的标签.jpg" \
    '丢失 EXIF 标签 GPSProcessingMethod（GPS 0x001B，ASCII，"CELLID"）——类型不合规范' \
    '丢失 EXIF 标签 LightSource（ExifIFD 0x9208，LONG，0）——类型不合规范' \
    '丢失 EXIF 标签 未知标签（ExifIFD 0xC000，ASCII，"私有串"）' \
    '丢失 EXIF 标签 DocumentName（ExifIFD 0x010D，ASCII，"放错位置的文档名"）——放错了 IFD' \
    '丢失 EXIF 标签 MakerNote（ExifIFD 0x927C，UNDEFINED，"J"、"##**N4206_vivi"、"Auto"，同号条目 3 个）'
# 必须不报：没有数据的条目（长度 0 的 DocumentName、类型 0 长度 0 的空条目、8 字节全 0
# 字符集头加 248 个空格的 UserComment）。同一张图里另放一个必须报的 LightSource，差异
# 恰好一处——证明清点确实跑了，只是把空条目滤掉了。
./Tests/fixture "$WORK/空条目.jpg" >/dev/null
make_sample ./Tests/mangle-tool --tags "$WORK/空条目.jpg" 'exif:010D:ascii=' 'exif:0000:none=' \
    "exif:9286:undef=$(printf '\\0%.0s' 1 2 3 4 5 6 7 8)$(printf '%248s' '')" 'exif:9208:long=0'
out=$("$BIN" --verify "$WORK/空条目.jpg" 2>&1)
grep -q "发现 1 处差异" <<< "$out" && grep -qF "LightSource（ExifIFD 0x9208" <<< "$out" \
    && pass "没有数据的条目不报，同一张图里该报的照报（恰好 1 处）" \
    || { fail "空条目被报了，或该报的没报"; sed 's/^/     /' <<< "$out"; }

round "7h. GPS 按原始分数比"
# 源的秒存成分母 1000000 的分数，HEIF 写入器存成分母 100。ImageIO 视图里的经度只在截断
# 跨过它的舍入档时才变——这一张的 XMP/exif:GPSLongitude 恰好会变，用来证明同一处变化
# 只报原始分数那一行。
./Tests/fixture "$WORK/GPS精度.jpg" >/dev/null
make_sample ./Tests/mangle-tool --tags "$WORK/GPS精度.jpg" 'gps:0004:rational=120/1,8/1,55304567/1000000'
cp "$WORK/GPS精度.jpg" "$WORK/GPS精度副本.jpg"
out=$("$BIN" --verify "$WORK/GPS精度.jpg" 2>&1); st=$?
grep -qF "变化 GPS 经度：120°8′55.304567″ → 120°8′55.3″（HEIF 写入器只保留到 1/100 秒）" <<< "$out" \
    && pass "GPS 经度按原始分数报出截断" \
    || { fail "GPS 经度的截断没报出来"; sed 's/^/     /' <<< "$out"; }
v_src=$(./Tests/probe "$WORK/GPS精度副本.jpg" 'XMP/exif:GPSLongitude')
v_dst=$(./Tests/probe "$WORK/GPS精度.heic" 'XMP/exif:GPSLongitude')
[ -n "$v_src" ] && [ "$v_src" != "<无>" ] && [ "$v_src" != "$v_dst" ] \
    && pass "前提：ImageIO 视图里同一处也变了（$v_src → $v_dst）" \
    || fail "前提不成立：视图里的经度没变（[$v_src] → [$v_dst]），去重那条测不到"
refute "同一处变化不在视图那边重复报" "$st" grep -qE "GPSLongitude|\{GPS\}/Longitude" <<< "$out"
grep -q "发现 1 处差异" <<< "$out" && pass "这张图恰好 1 处差异" || { fail "差异条数不是 1"; sed 's/^/     /' <<< "$out"; }
# 秒本来就是分母 100 的源：写入器原样写下，不报。
./Tests/fixture "$WORK/GPS百分秒.jpg" >/dev/null
make_sample ./Tests/mangle-tool --tags "$WORK/GPS百分秒.jpg" 'gps:0002:rational=30/1,14/1,3251/100'
out=$("$BIN" --verify "$WORK/GPS百分秒.jpg" 2>&1)
grep -q "元数据校验通过" <<< "$out" \
    && pass "秒是分母 100 的 GPS 不报" || { fail "分母 100 的 GPS 报了差异"; sed 's/^/     /' <<< "$out"; }

round "7i. 产物比原图大"
# 噪声图按质量 0.2 存的 JPEG，转出来稳定地变大（--noise 夹具）。提示要出现；
# --delete-original 下校验通过也不删源，并说明原因；批量汇总单列变大的个数。
./Tests/fixture --noise "$WORK/变大.jpg" >/dev/null
out=$("$BIN" --delete-original "$WORK/变大.jpg" 2>&1); st=$?
grep -q "元数据校验通过" <<< "$out" \
    && pass "前提：变大的那张校验通过（不删只因为变大）" || { fail "变大的那张校验没通过"; sed 's/^/     /' <<< "$out"; }
grep -qE "HEIF 比原图大 [0-9]+%" <<< "$out" && pass "提示 HEIF 比原图大" || { fail "没提示变大"; sed 's/^/     /' <<< "$out"; }
grep -qF "因产物比原图大，保留了源文件" <<< "$out" && pass "说明为什么没删源" || fail "没说明为什么没删源"
refute "变大时不删源" "$st" test ! -f "$WORK/变大.jpg"
grep -qF "1 个比原图大" <<< "$out" && pass "汇总单列变大的个数" || fail "汇总里没有变大的个数"

round "7j. 带辅助图的 4:2:2 照片"
# 带辅助图的 JPEG 才有 {FileContents}；4:2:2 的源转成 HEIF 是 4:2:0，这是编码参数，
# 不报。ImageIO 重新编码 JPEG 只会出 4:2:0 或 4:4:4，所以拿 4:2:2 的相机照片，原样接上
# 夹具的深度图。
./Tests/fixture --aux depth "$WORK/深度图供体.jpg" >/dev/null
cp test_pic/P1130939.JPG "$WORK/四二二.jpg"
make_sample ./Tests/mangle-tool --graft-aux "$WORK/四二二.jpg" "$WORK/深度图供体.jpg"
check "前提：源是 4:2:2" "$(./Tests/probe "$WORK/四二二.jpg" '{FileContents}/Images[0]/ChromaSubsampling')" "4:2:2"
check "前提：源里接上了深度图" "$(./Tests/probe --aux "$WORK/四二二.jpg" Depth)" "150x120 1717855600"
out=$("$BIN" --verify "$WORK/四二二.jpg" 2>&1); st=$?
check "前提：产物是 4:2:0" "$(./Tests/probe "$WORK/四二二.heic" '{FileContents}/Images[0]/ChromaSubsampling')" "4:2:0"
refute "色度抽样不报" "$st" grep -qF "ChromaSubsampling" <<< "$out"

round "8. 界面模型：指定输出文件夹与取消"
# 这一轮走模型层而不是驱动窗口：「输出到指定文件夹」要经过 NSOpenPanel，
# 模态面板没法自动化，而 ConversionModel 覆盖的是同一套逻辑。
mkdir -p "$WORK/界面模型/源" "$WORK/界面模型/取消" "$WORK/界面模型/中途取消" \
         "$WORK/界面模型/递归/子目录" "$WORK/界面模型/未校验" "$WORK/界面模型/变大"
./Tests/fixture "$WORK/界面模型/源/一.jpg" >/dev/null
# 转出来必然变大的那张：校验通过、勾着删源也不能删
./Tests/fixture --noise "$WORK/界面模型/变大/噪声.jpg" >/dev/null
# 关掉校验时必然丢数据的那张，不能显示「校验无差异」
./Tests/fixture --lossy "$WORK/界面模型/未校验/有损.jpg" >/dev/null
./Tests/fixture "$WORK/界面模型/源/二.jpg" >/dev/null
# 递归开关的素材：顶层一张、子目录一张，勾与不勾的张数必须不同
./Tests/fixture "$WORK/界面模型/递归/顶层.jpg" >/dev/null
./Tests/fixture "$WORK/界面模型/递归/子目录/深处.jpg" >/dev/null
# 素材数远多于并发度，取消才能确定性地拦下后续任务
for i in $(seq 1 40); do
    cp "$WORK/界面模型/源/一.jpg" "$WORK/界面模型/取消/c$i.jpg"
    cp "$WORK/界面模型/源/一.jpg" "$WORK/界面模型/中途取消/d$i.jpg"
done
# 同单测那一轮：子套件的 ✓ 数要进断言，否则打印 0 条也算「全过」。
if out=$(./Tests/guimodel-test "$WORK/界面模型" 2>&1); then
    pass "模型层集成测试通过"
else
    fail "界面模型测试未通过"; echo "$out" | grep '✗' | sed 's/^/     /'
fi
expect_count "模型层" "$(count_assertions "$out")" "$EXPECTED_GUI" EXPECTED_GUI

round "9. 图形界面端到端"
mkdir -p "$WORK/界面"
cp "$WORK/照片.jpg" "$WORK/界面/拖入的照片.jpg"
# 截图工具会驱动真实的窗口：加载文件、点"开始转换"、把窗口渲染成 PNG。
Tests/uisnapshot "$WORK/界面.png" --convert "$WORK/界面" >/dev/null 2>&1
[ -f "$WORK/界面/拖入的照片.heic" ] && pass "界面转换产出了 .heic" || fail "界面没有产出 .heic"
[ -s "$WORK/界面.png" ] && pass "窗口渲染正常" || fail "窗口渲染失败"
want=$(./Tests/probe "$WORK/界面/拖入的照片.jpg" '{GPS}/Latitude')
got=$(./Tests/probe "$WORK/界面/拖入的照片.heic" '{GPS}/Latitude')
check_same "界面产物同样保留 GPS" "$got" "$want"

echo
# 数的是「执行了多少条」= PASSED + FAILED，不是「通过了多少条」：比 PASSED 的话，
# 真失败会被再报一次「有断言没有执行」，那是误诊。
# 这一条不走 expect_count：它要是也发一个 pass，就会把自己要比的那个数顶高
# 一位。所以只在不符时出声，下面的结论打印的就是它比过的那个数。它是最外层
# 那一条，没有更外层的守卫罩着它。
executed=$((PASSED + FAILED))
[ "$executed" -eq "$EXPECTED_ASSERTIONS" ] \
    || fail "执行了 $executed 项断言，预期 $EXPECTED_ASSERTIONS 项（改动断言后请同步 EXPECTED_ASSERTIONS）"
if [ "$FAILED" -eq 0 ]; then
    echo "全部通过（$ROUNDS 轮，$executed 项断言）"
else
    echo "$FAILED 项失败（$ROUNDS 轮，$executed 项断言、$PASSED 项通过）"
fi
REACHED_END=1
exit $((FAILED > 0))

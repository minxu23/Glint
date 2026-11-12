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
EXPECTED_ASSERTIONS=613
EXPECTED_UNIT=883
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
# 要走 EXIF 交给系统重写的那条路时在前面写 XFLAGS=--no-raw-exif。
XFLAGS=""
expect_reported() {
    local what=$1 file=$2 out st want; shift 2
    # shellcheck disable=SC2086  # XFLAGS 为空时不能变成一个空参数
    out=$("$BIN" -v --delete-original $XFLAGS "$file" 2>&1); st=$?
    for want in "$@"; do
        if grep -qF -- "$want" <<< "$out"; then
            pass "$what：报出「$want」"
        else
            fail "$what：没报出「$want」"; sed 's/^/     /' <<< "$out"
        fi
    done
    refute "$what：源文件保留" "$st" test ! -f "$file"
}
# 默认路径（EXIF 整块照搬）：拷一份走 --verify，校验必须通过，产物的 EXIF 必须与源逐字节相同。
# 用在「EXIF 交给系统重写时会报丢失」的样本旁边，要在那张样本被转换之前调用（拷的是原样）。
# 用法：expect_carried 描述 文件（两条断言）
expect_carried() {
    local what=$1 copy="${2%.*}-照搬.jpg" out
    cp "$2" "$copy"
    out=$("$BIN" -v --verify "$copy" 2>&1)
    grep -q "元数据校验通过" <<< "$out" \
        && pass "$what（默认路径）：校验通过" \
        || { fail "$what（默认路径）：校验报了差异"; sed 's/^/     /' <<< "$out"; }
    check "$what（默认路径）：产物的 EXIF 与源逐字节相同" \
        "$(./Tests/probe --exif-same "$copy" "${copy%.jpg}.heic")" "相同"
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
OUT=$("$BIN" --verify -v "$WORK/照片.jpg" 2>&1); st=$?
echo "$OUT" | grep -q "元数据校验通过" && pass "校验通过，无任何丢失" || { fail "校验报告了差异"; echo "$OUT" | sed 's/^/     /'; }
[ -f "$WORK/照片.heic" ] && pass "生成了 .heic" || fail "没有生成 .heic"
refute "产物不比原图大时不重编（-v 里没有重编那一行）" "$st" grep -qF "重编了一次" <<< "$OUT"

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

round "3b. 扩展属性进校验"
# 「照片」的说明、访达备注、访达标签（后两个按访达的写法存成二进制 plist）和一个自定义属性。
# 产物上四个都得在、值逐字节相同，校验通过；校验也核对它们（单测逐条钉着报法）。
mkdir -p "$WORK/扩展属性"
XA="$WORK/扩展属性/带属性.jpg"
cp "$WORK/照片.jpg" "$XA"
# 把一段 plist 的 XML 转成二进制，写成扩展属性 $1 到文件 $2。
xattr_plist() {
    plutil -convert binary1 -o "$WORK/扩展属性/tmp.plist" - <<< "$3" \
        && xattr -wx "$1" "$(xxd -p "$WORK/扩展属性/tmp.plist" | tr -d '\n')" "$2"
}
PL_HEAD='<?xml version="1.0" encoding="UTF-8"?><plist version="1.0">'
make_sample xattr -w com.apple.assetsd.description "西湖日落，和外婆一起" "$XA"
make_sample xattr_plist com.apple.metadata:kMDItemFinderComment "$XA" "$PL_HEAD<string>访达里的备注</string></plist>"
make_sample xattr_plist com.apple.metadata:_kMDItemUserTags "$XA" "$PL_HEAD<array><string>红色
6</string><string>旅行</string></array></plist>"
make_sample xattr -w user.jpeg2heif.custom "自定义的值" "$XA"
XATTRS4='com.apple.assetsd.description
com.apple.metadata:kMDItemFinderComment
com.apple.metadata:_kMDItemUserTags
user.jpeg2heif.custom'
cp "$XA" "$WORK/扩展属性/删源.jpg"
xa_out=$("$BIN" --verify -v "$XA" 2>&1)
grep -q "元数据校验通过" <<< "$xa_out" \
    && pass "带四个扩展属性：校验通过" \
    || { fail "带四个扩展属性：校验报了差异"; sed 's/^/     /' <<< "$xa_out"; }
while IFS= read -r name; do
    check_same "产物上有 $name，值逐字节相同" \
        "$(xattr -px "$name" "${XA%.jpg}.heic" 2>/dev/null)" "$(xattr -px "$name" "$XA" 2>/dev/null)"
done <<< "$XATTRS4"
"$BIN" --delete-original "$WORK/扩展属性/删源.jpg" >/dev/null 2>&1
[ -f "$WORK/扩展属性/删源.heic" ] && [ ! -e "$WORK/扩展属性/删源.jpg" ] \
    && pass "扩展属性都在：--delete-original 删了源" || fail "扩展属性都在，却没删源或没产出 .heic"
# 隔离标记转换时不拷，校验也不核对它。
QA="$WORK/扩展属性/隔离.jpg"
cp "$WORK/照片.jpg" "$QA"
make_sample xattr -w com.apple.quarantine "0081;00000000;Safari;" "$QA"
qa_out=$("$BIN" --verify "$QA" 2>&1); st=$?
grep -q "元数据校验通过" <<< "$qa_out" \
    && pass "源带隔离标记：校验不报" \
    || { fail "源带隔离标记：校验报了差异"; sed 's/^/     /' <<< "$qa_out"; }
refute "源带隔离标记：产物上没有隔离标记" "$st" \
    sh -c 'xattr -p com.apple.quarantine "$1" >/dev/null 2>&1' _ "${QA%.jpg}.heic"

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
# 默认路径整块照搬 EXIF，MakerNote 原样在产物里；交给系统重写时才丢。
expect_carried "相机照片的 MakerNote" "$WORK/相机.jpg"
XFLAGS=--no-raw-exif expect_reported "相机照片丢失 MakerNote" "$WORK/相机.jpg" "丢失 厂商私有数据 MakerNote"

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
# IIM 摘要对不上，说明也按 IIM 调和：时间打架让照搬退回系统重写，EXIF 里的说明被换成 IIM 那份，
# 两边视图相同，由说明的原文核对报出来。
expect_reported "只改过 IIM 时间" "$WORK/只改IIM.jpg" \
    "变化 {Exif}/DateTimeOriginal: 2024:09:15 18:42:07 → 2024:09:15 10:42:07" \
    "变化 EXIF 说明 ImageDescription 的原文：西湖日落 sunset at West Lake → IPTC 备注字段"

# ImageIO 不读的段：COM 注释、不认识的 APPn（APP11 是 C2PA 用的）、EOI 之后的数据。
cp "$WORK/照片.jpg" "$WORK/注释段.jpg"
make_sample ./Tests/mangle-tool --segment "$WORK/注释段.jpg" FE "JPEG 注释段里的备注"
expect_reported "COM 注释段" "$WORK/注释段.jpg" "丢失 JPEG 注释段（COM）= JPEG 注释段里的备注"
cp "$WORK/照片.jpg" "$WORK/APP11.jpg"
make_sample ./Tests/mangle-tool --segment "$WORK/APP11.jpg" EB "JP c2pa 内容凭证"
expect_reported "APP11 段" "$WORK/APP11.jpg" "丢失 APP11 段（JP c2pa "
# APP10 `AROT\0\0` 是 ImageIO 写的 JPEG 码流逐行索引，转成 HEIF 后本就不该在，不报；
# 别的 APP10（包括 AROT 后面不是两个 0 的）照报。
cp "$WORK/照片.jpg" "$WORK/AROT.jpg"
make_sample ./Tests/mangle-tool --segment "$WORK/AROT.jpg" EA 'AROT\0\0\0\0\0\x10\0\0\0\x20\0\0\0\x30'
arot_out=$("$BIN" --verify "$WORK/AROT.jpg" 2>&1)
grep -q "元数据校验通过" <<< "$arot_out" \
    && pass "APP10 AROT 段：不报，校验通过" \
    || { fail "APP10 AROT 段：校验报了差异"; sed 's/^/     /' <<< "$arot_out"; }
cp "$WORK/照片.jpg" "$WORK/APP10.jpg"
make_sample ./Tests/mangle-tool --segment "$WORK/APP10.jpg" EA "XYZ1 别的内容"
expect_reported "别的 APP10 段" "$WORK/APP10.jpg" "丢失 APP10 段（XYZ1 "
cp "$WORK/照片.jpg" "$WORK/AROT不对.jpg"
make_sample ./Tests/mangle-tool --segment "$WORK/AROT不对.jpg" EA 'AROT\x01\0\0\0\0\x10'
expect_reported "AROT 后面不是两个 0 的 APP10 段" "$WORK/AROT不对.jpg" "丢失 APP10 段（AROT，10 字节）"
cp "$WORK/照片.jpg" "$WORK/尾部数据.jpg"
make_sample ./Tests/mangle-tool --append "$WORK/尾部数据.jpg" "动态照片的视频放在这里"
expect_reported "EOI 之后的数据" "$WORK/尾部数据.jpg" "丢失 EOI 之后的 33 字节"
# 没有可带信息的几种不报：FlashPix 扩展（APP2 `FPXR\0`）、只有保存质量的 Ducky 段（APP12）、
# 微信加在 EOI 之后的 `tyf-` 加 4 个 0。三样放在同一张图里，校验通过、--delete-original 删源。
# 差一点的形状由单测逐条管；这里各留一条端到端的照报。
f="$WORK/没有价值.jpg"
cp "$WORK/照片.jpg" "$f"
make_sample ./Tests/mangle-tool --segment "$f" E2 'FPXR\0\x01\0\x02\0\0\0\x10Contents'
make_sample ./Tests/mangle-tool --segment "$f" EC 'Ducky\0\x01\0\x04\0\0\0\x50\0\0'
make_sample ./Tests/mangle-tool --append "$f" 'tyf-\0\0\0\0'
out=$("$BIN" -v --delete-original "$f" 2>&1); st=$?
grep -q "元数据校验通过" <<< "$out" \
    && pass "FlashPix、只有质量的 Ducky、tyf- 标记：不报，校验通过" \
    || { fail "FlashPix、只有质量的 Ducky、tyf- 标记：校验报了差异"; sed 's/^/     /' <<< "$out"; }
refute "FlashPix、只有质量的 Ducky、tyf- 标记：校验通过后删了源" "$st" test -e "$f"
f="$WORK/差一点.jpg"
cp "$WORK/照片.jpg" "$f"
make_sample ./Tests/mangle-tool --segment "$f" E2 'FPXQ\0\x01\0\x02'
make_sample ./Tests/mangle-tool --segment "$f" EC 'Ducky\0\x01\0\x04\0\0\0\x50\0\x02\0\x05hello\0\0'
make_sample ./Tests/mangle-tool --append "$f" 'tyf-\0\0\0\x01'
expect_reported "差一点的 FlashPix、Ducky、tyf- 标记" "$f" \
    "丢失 APP2 段（FPXQ，8 字节）" "丢失 APP12 段（Ducky，24 字节）" "丢失 EOI 之后的 8 字节"

# CMYK 的 ICC 描述文件和色彩模型被换成 sRGB/RGB，必须报。
./Tests/fixture --cmyk "$WORK/CMYK.jpg" >/dev/null
expect_reported "CMYK 被转成 RGB" "$WORK/CMYK.jpg" \
    "变化 ColorModel: CMYK → RGB" "变化 ProfileName: Generic CMYK Profile → sRGB"

round "7d. ImageIO 不读的 Windows 标签与 Photoshop 资源"
# Windows 资源管理器写在 IFD0 的 XP 标签和评级，ImageIO 不读也不搬。目标里有等价字段
# 带着同一个值才算承载。三张样本：没有等价字段、等价字段同值、等价字段不同值。
# 默认路径整块照搬，XP 标签原样在产物的 IFD0 里，同值就算承载；下面「必须报」的是 EXIF 交给
# 系统重写的那条路。
./Tests/fixture --no-text "$WORK/只有XP.jpg" >/dev/null
make_sample ./Tests/mangle-tool --ifd0 "$WORK/只有XP.jpg" '9C9B=XP标题' '9C9C=XP备注' \
    '9C9D=作者甲;作者乙' '9C9E=关键词一;关键词二' '9C9F=XP主题' '4746=4' '4749=75'
expect_carried "只有 Windows 标签" "$WORK/只有XP.jpg"
XFLAGS=--no-raw-exif expect_reported "只有 Windows 标签" "$WORK/只有XP.jpg" \
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
expect_carried "Windows 标签与等价字段不同值" "$WORK/XP不同值.jpg"
XFLAGS=--no-raw-exif expect_reported "Windows 标签与等价字段不同值" "$WORK/XP不同值.jpg" \
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
expect_carried "IMG_1225 改掉 Artist" "$WORK/XP作者改.jpg"
XFLAGS=--no-raw-exif expect_reported "IMG_1225 改掉 Artist" "$WORK/XP作者改.jpg" \
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

# 尾部记账：辅助图在 JPEG 里放在 EOI 之后、由 MPF 登记。搬进产物的那几段、MPF 登记的
# 大尺寸预览图不报，其余照报。这张相机照片的 EOI 之后是一张预览图（类型码 0x010002，
# 845023 字节），前面 16 字节 0xFF 加 128 字节、后面 33 字节 0xFF 加 256 字节 MPF 没登记的
# 相机数据（含非填充字节），连同夹着的填充一共 433 字节照报。
cp test_pic/P1130939.JPG "$WORK/辅助图/带预览图.jpg"
expect_reported "EOI 之后是预览图加相机数据" "$WORK/辅助图/带预览图.jpg" \
    "丢失 EOI 之后的 433 字节（尾部共 845456 字节，其中 845023 字节是 MPF 登记的预览图，不需要带）"
# 把 MPF 没登记的字节都改成填充，只剩预览图：不报。
cp test_pic/P1130939.JPG "$WORK/辅助图/只有预览图.jpg"
make_sample ./Tests/mangle-tool --pad-trailer "$WORK/辅助图/只有预览图.jpg"
out=$("$BIN" -v --delete-original "$WORK/辅助图/只有预览图.jpg" 2>&1); st=$?
grep -q "元数据校验通过" <<< "$out" \
    && pass "EOI 之后只有预览图和填充：校验通过" \
    || { fail "EOI 之后只有预览图和填充：校验报了差异"; sed 's/^/     /' <<< "$out"; }
refute "EOI 之后只有预览图和填充：校验通过后删了源" "$st" test -e "$WORK/辅助图/只有预览图.jpg"
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
# 版本标记段只有版本号，一律不报。截掉增益图（EOI 之后），只剩主图里孤立的标记段——
# 编辑软件重存时扔了增益图的真实照片就是这样：源里本来就没有增益图，转换什么也没丢，
# 校验通过。增益图本身在源里而产物里没有时，由尾部记账和辅助图的键比对报（7e）。
cp "$WORK/ISO增益图/源副本/单通道.jpg" "$WORK/ISO增益图/只有标记段.jpg"
make_sample ./Tests/mangle-tool --strip-trailer "$WORK/ISO增益图/只有标记段.jpg"
check "前提：截掉之后源里没有增益图" "$(./Tests/probe --aux "$WORK/ISO增益图/只有标记段.jpg" ISOGainMap)" "<无>"
out=$("$BIN" -v --verify "$WORK/ISO增益图/只有标记段.jpg" 2>&1)
grep -q "元数据校验通过" <<< "$out" \
    && pass "只有 ISO 21496 标记段、没有增益图：标记段不报，校验通过" \
    || { fail "只有 ISO 21496 标记段、没有增益图：校验报了差异"; sed 's/^/     /' <<< "$out"; }
# 新版 MPF 给增益图的类型码 0x050000（华为的 HDR 照片用它）：搬进产物了就不计入尾部的丢失。
# 0x040000（编辑前的原图）不是辅助图，照报。
for code in 050000 040000; do
    f="$WORK/ISO增益图/类型码$code.jpg"
    cp "$WORK/ISO增益图/源副本/单通道.jpg" "$f"
    make_sample ./Tests/mangle-tool --mpf-type "$f" 1 "$code"
    check "类型码 $code：前提，ImageIO 照样读得出源里的 ISO 增益图" "$(./Tests/probe --aux "$f" ISOGainMap)" "600x450 1278226488"
done
f="$WORK/ISO增益图/类型码050000.jpg"
out=$("$BIN" -v --delete-original "$f" 2>&1); st=$?
grep -q "元数据校验通过" <<< "$out" \
    && pass "类型码 0x050000 的增益图搬进产物：校验通过" \
    || { fail "类型码 0x050000 的增益图搬进产物：校验报了差异"; sed 's/^/     /' <<< "$out"; }
refute "类型码 0x050000 的增益图搬进产物：校验通过后删了源" "$st" test -e "$f"
check "类型码 0x050000：产物里有 ISO 增益图" "$(./Tests/probe --aux "${f%.jpg}.heic" ISOGainMap)" "600x450 1278226488"
expect_reported "类型码 0x040000 的附加图像" "$WORK/ISO增益图/类型码040000.jpg" "字节（MPF 多图格式的附加图像）"

round "7g. ImageIO 读不出的 EXIF 标签"
# 两边都走 ImageIO 视图时，ImageIO 在源一侧就读不出的标签两边都看不见。原始清点直接
# 读两边的 TIFF 结构。必须报：ASCII 类型的 GPSProcessingMethod、LONG 类型的 LightSource、
# 不认识的私有标签、放在 Exif 子 IFD 里的 DocumentName（实测 ImageIO 不读它，也不会把它
# 挪到 IFD0）、重复三次的短 MakerNote（合成一行）。
./Tests/fixture "$WORK/读不出的标签.jpg" >/dev/null
make_sample ./Tests/mangle-tool --tags "$WORK/读不出的标签.jpg" 'gps:001B:ascii=CELLID' 'exif:9208:long=0' \
    'exif:C000:ascii=私有串' 'exif:010D:ascii=放错位置的文档名' \
    'exif:927C:undef=J' 'exif:927C:undef=##**N4206_vivi' 'exif:927C:undef=Auto'
# 默认路径整块照搬，这些标签原样在产物里；下面的「必须报」是 EXIF 交给系统重写的那条路。
expect_carried "ImageIO 读不出的 EXIF 标签" "$WORK/读不出的标签.jpg"
XFLAGS=--no-raw-exif expect_reported "ImageIO 读不出的 EXIF 标签" "$WORK/读不出的标签.jpg" \
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
expect_carried "空条目与一个类型不合规范的标签" "$WORK/空条目.jpg"
out=$("$BIN" --verify --no-raw-exif "$WORK/空条目.jpg" 2>&1)
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
# 默认路径整块照搬，GPS 的原始分数原样在产物里；截断只发生在 EXIF 交给系统重写的那条路上。
expect_carried "秒是分母 1000000 的 GPS" "$WORK/GPS精度.jpg"
out=$("$BIN" --verify --no-raw-exif "$WORK/GPS精度.jpg" 2>&1); st=$?
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
# 变大的产物重编一次，-v 说出来。
./Tests/fixture --noise "$WORK/变大.jpg" >/dev/null
out=$("$BIN" -v --delete-original "$WORK/变大.jpg" 2>&1); st=$?
grep -qE "^    产物比原图大，重编了一次：.+ → .+（(用了较小的一份|两次一样大)）$" <<< "$out" \
    && pass "变大时重编一次，-v 说了两次的大小" || { fail "-v 里没有重编那一行"; sed 's/^/     /' <<< "$out"; }
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

round "7k. ImageIO 读不出的 ImageUniqueID"
# ImageIO 只读恰好 33 字节的 ImageUniqueID，写入器却什么长度都照写。别的长度的值转换时从
# 原始字节补写进产物，校验按两边的原始字节比值（ImageIO 视图两边都读不出它）。源的副本
# 放在另一个目录里留作比对。
# 默认路径整块照搬，值跟着整个 EXIF 过去；--no-raw-exif 时走转换时的补写。两条路各跑一遍。
mkdir -p "$WORK/唯一标识/源副本"
for mode in "" --no-raw-exif; do
i=0
while IFS='|' read -r what value; do
    i=$((i + 1))
    what="$what${mode:+（$mode）}"
    f="$WORK/唯一标识/$i${mode}.jpg" ref="$WORK/唯一标识/源副本/$i${mode}.jpg"
    make_sample ./Tests/fixture --unique-id "$value" "$f"
    cp "$f" "$ref"
    check "$what：前提，源的 ImageIO 视图里没有 ImageUniqueID" "$(./Tests/probe "$f" '{Exif}/ImageUniqueID')" "<无>"
    # shellcheck disable=SC2086  # mode 为空时不能变成一个空参数
    out=$("$BIN" -v --delete-original $mode "$f" 2>&1); st=$?
    grep -q "元数据校验通过" <<< "$out" \
        && pass "$what：校验通过" \
        || { fail "$what：校验报了差异"; sed 's/^/     /' <<< "$out"; }
    refute "$what：校验通过后删了源" "$st" test -e "$f"
    check_same "$what：产物原始 EXIF 里的 0xA420 与源逐字节相同" \
        "$(./Tests/probe --raw-exif "${f%.jpg}.heic" A420)" "$(./Tests/probe --raw-exif "$ref" A420)"
done <<'EOF'
24 字节|J12LLKF00SM J12LLKL01GM
26 字节|OPPO_20201019_204116_0001
含非 ASCII 字符|唯一标识
EOF
done
# 33 字节：ImageIO 自己读得到，键空间比对管它的值，补写那一路什么都不做。
make_sample ./Tests/fixture --unique-id 0123456789abcdef0123456789abcdef "$WORK/唯一标识/33字节.jpg"
check "33 字节：前提，源的 ImageIO 视图里读得到" \
    "$(./Tests/probe "$WORK/唯一标识/33字节.jpg" '{Exif}/ImageUniqueID')" "0123456789abcdef0123456789abcdef"
cp "$WORK/唯一标识/33字节.jpg" "$WORK/唯一标识/源副本/33字节.jpg"
out=$("$BIN" --verify "$WORK/唯一标识/33字节.jpg" 2>&1)
grep -q "元数据校验通过" <<< "$out" && pass "33 字节：校验通过" || { fail "33 字节：校验报了差异"; sed 's/^/     /' <<< "$out"; }
check_same "33 字节：产物原始 EXIF 里的 0xA420 与源逐字节相同" \
    "$(./Tests/probe --raw-exif "$WORK/唯一标识/33字节.heic" A420)" \
    "$(./Tests/probe --raw-exif "$WORK/唯一标识/源副本/33字节.jpg" A420)"
# 写不回原样的不补，EXIF 交给系统重写时照报丢失：不是合法 UTF-8 的值、UNDEFINED 类型。
# 默认路径整块照搬，它们原样在产物里。
./Tests/fixture "$WORK/唯一标识/非UTF8.jpg" >/dev/null
make_sample ./Tests/mangle-tool --tags "$WORK/唯一标识/非UTF8.jpg" 'exif:A420:ascii=J12LLKF00SM\xffJ12'
expect_carried "ImageUniqueID 不是合法 UTF-8" "$WORK/唯一标识/非UTF8.jpg"
XFLAGS=--no-raw-exif expect_reported "ImageUniqueID 不是合法 UTF-8" "$WORK/唯一标识/非UTF8.jpg" \
    '丢失 EXIF 标签 ImageUniqueID（ExifIFD 0xA420，ASCII，"J12LLKF00SM'
check "ImageUniqueID 不是合法 UTF-8：产物里没有补写" \
    "$(./Tests/probe --raw-exif "$WORK/唯一标识/非UTF8.heic" A420)" "<无>"
./Tests/fixture "$WORK/唯一标识/UNDEFINED.jpg" >/dev/null
make_sample ./Tests/mangle-tool --tags "$WORK/唯一标识/UNDEFINED.jpg" 'exif:A420:undef=J12LLKF00SM J12LLKL01GM'
expect_carried "UNDEFINED 类型的 ImageUniqueID" "$WORK/唯一标识/UNDEFINED.jpg"
XFLAGS=--no-raw-exif expect_reported "UNDEFINED 类型的 ImageUniqueID" "$WORK/唯一标识/UNDEFINED.jpg" \
    '丢失 EXIF 标签 ImageUniqueID（ExifIFD 0xA420，UNDEFINED，"J12LLKF00SM J12LLKL01GM"）——类型不合规范'
# 个数离谱、值越出 EXIF：不崩，EXIF 交给系统重写时照报；默认路径原样照搬。
while IFS='|' read -r what spec; do
    f="$WORK/唯一标识/$what.jpg"
    ./Tests/fixture "$f" >/dev/null
    make_sample ./Tests/mangle-tool --tags "$f" "$spec"
    expect_carried "ImageUniqueID $what" "$f"
    XFLAGS=--no-raw-exif expect_reported "ImageUniqueID $what" "$f" '丢失 EXIF 标签 ImageUniqueID（ExifIFD 0xA420，ASCII，值读不出）——值越界'
done <<'EOF'
个数离谱|exif:A420:ascii#99999=J12LLKF00SM
值偏移越出EXIF|exif:A420:ascii@7FFFFFF0=J12LLKF00SM J12LLKL01GM
EOF

round "7l. EXIF 整块照搬"
# 默认路径：ImageIO 写完 HEIC 后，产物里 Exif 项的内容换成源 EXIF 段的原始字节。照搬会让
# 视图退步的（EXIF 与 IIM 打架）退回 ImageIO 重写的产物，与 --no-raw-exif 逐字节相同。凡是要逐字节比两个产物的，两次转换前后紧挨着跑（编码结果受负载影响）。
mkdir -p "$WORK/照搬/源副本" "$WORK/照搬/重写"
# 1. ImageIO 读不出的标签、GPS 秒的精度、24 字节的 ImageUniqueID 放在同一张图里。
UID24="J12LLKF00SM J12LLKL01GM"
f="$WORK/照搬/整块.jpg" ref="$WORK/照搬/源副本/整块.jpg" rw="$WORK/照搬/重写/整块.jpg"
make_sample ./Tests/fixture --unique-id "$UID24" "$f"
make_sample ./Tests/mangle-tool --tags "$f" 'gps:001B:ascii=CELLID' 'exif:9208:long=0' \
    'exif:C000:ascii=私有串' 'exif:010D:ascii=放错位置的文档名' \
    'exif:927C:undef=J' 'exif:927C:undef=##**N4206_vivi' 'exif:927C:undef=Auto' \
    'gps:0004:rational=120/1,8/1,55304567/1000000'
cp "$f" "$ref"; cp "$f" "$rw"
out=$("$BIN" -v --delete-original "$f" 2>&1); st=$?
grep -q "元数据校验通过" <<< "$out" \
    && pass "整块照搬：校验通过" || { fail "整块照搬：校验报了差异"; sed 's/^/     /' <<< "$out"; }
refute "整块照搬：校验通过后删了源" "$st" test -e "$f"
grep -qE "EXIF 整块照搬（[0-9]+ 字节）" <<< "$out" \
    && pass "整块照搬：-v 说照搬了多少字节" || { fail "整块照搬：-v 没说照搬了"; sed 's/^/     /' <<< "$out"; }
check "整块照搬：产物的 EXIF 与源逐字节相同" "$(./Tests/probe --exif-same "$ref" "${f%.jpg}.heic")" "相同"
# 7. 没有死数据：源 EXIF 里那个 24 字节的 ImageUniqueID 在产物里恰好出现一次（旧内容清零了）。
check "整块照搬：产物里 ImageUniqueID 的字节串恰好出现一次" \
    "$(LC_ALL=C grep -aoF "$UID24" "${f%.jpg}.heic" | wc -l | tr -d ' ')" "1"
# 校验靠「Exif 项在文件末尾」认出照搬过的产物（见 carriedExifIssues），前提是 ImageIO 自己写的
# 产物里它不在末尾。
check "整块照搬：照搬过的产物 Exif 项在文件末尾" "$(./Tests/probe --exif-at-end "${f%.jpg}.heic")" "末尾"
XFLAGS=--no-raw-exif expect_reported "整块照搬（--no-raw-exif）" "$rw" \
    '丢失 EXIF 标签 GPSProcessingMethod（GPS 0x001B，ASCII，"CELLID"）——类型不合规范' \
    '丢失 EXIF 标签 LightSource（ExifIFD 0x9208，LONG，0）——类型不合规范' \
    '丢失 EXIF 标签 未知标签（ExifIFD 0xC000，ASCII，"私有串"）' \
    '丢失 EXIF 标签 DocumentName（ExifIFD 0x010D，ASCII，"放错位置的文档名"）——放错了 IFD' \
    '丢失 EXIF 标签 MakerNote（ExifIFD 0x927C，UNDEFINED，"J"、"##**N4206_vivi"、"Auto"，同号条目 3 个）' \
    "变化 GPS 经度：120°8′55.304567″ → 120°8′55.3″（HEIF 写入器只保留到 1/100 秒）"
# 照搬了的产物比 ImageIO 重写的恰好大「4 字节偏移 + Exif\0\0 + 源的 TIFF」。
n=$(grep -oE "EXIF 整块照搬（[0-9]+ 字节）" <<< "$out" | grep -oE "[0-9]+")
check "整块照搬：前提，ImageIO 写的产物 Exif 项不在文件末尾" "$(./Tests/probe --exif-at-end "${rw%.jpg}.heic")" "不在末尾"
check_same "整块照搬：产物比 --no-raw-exif 的恰好大 10 + 源 TIFF 的字节数" \
    "$(( $(stat -f %z "${f%.jpg}.heic") - $(stat -f %z "${rw%.jpg}.heic") ))" "$(( 10 + ${n:-0} ))"

# 2. 真实的 MakerNote：两张相机照片都带 IFD1 缩略图，逐字节相同就说明缩略图也过去了。
for name in IMG_1225 P1130939; do
    cp "test_pic/$name.JPG" "$WORK/照搬/$name.jpg"
    out=$("$BIN" --verify "$WORK/照搬/$name.jpg" 2>&1)
    check "$name：产物的 EXIF 与源逐字节相同" \
        "$(./Tests/probe --exif-same "$WORK/照搬/$name.jpg" "$WORK/照搬/$name.heic")" "相同"
    if [ "$name" = IMG_1225 ]; then
        grep -q "元数据校验通过" <<< "$out" \
            && pass "$name：校验通过" || { fail "$name：校验报了差异"; sed 's/^/     /' <<< "$out"; }
        check_same "$name：产物里读得出 {MakerCanon}/LensModel，与源相同" \
            "$(./Tests/probe "$WORK/照搬/$name.heic" '{MakerCanon}/LensModel')" \
            "$(./Tests/probe "$WORK/照搬/$name.jpg" '{MakerCanon}/LensModel')"
    else
        grep -q "发现 1 处差异" <<< "$out" && grep -qF "丢失 EOI 之后的 433 字节（尾部共 845456 字节" <<< "$out" \
            && pass "$name：只剩 EOI 之后那一行" || { fail "$name：差异不止 EOI 之后那一行"; sed 's/^/     /' <<< "$out"; }
    fi
done

# 3. 方向：产物里的 irot/imir 由 ImageIO 按源的方向写，照搬不改 EXIF 里的方向。
for o in 3 6 8 5; do
    for mode in "" --no-raw-exif; do
        d="$WORK/照搬/方向$o${mode}"
        mkdir -p "$d"
        ./Tests/fixture "$d/图.jpg" >/dev/null
        make_sample ./Tests/mangle-tool --tags "$d/图.jpg" "ifd0:0112:short=$o"
        # shellcheck disable=SC2086
        "$BIN" $mode "$d/图.jpg" >/dev/null 2>&1
    done
    a="$WORK/照搬/方向$o/图.heic" b="$WORK/照搬/方向$o--no-raw-exif/图.heic"
    check "方向 $o：默认路径照搬了" "$(./Tests/probe --exif-same "$WORK/照搬/方向$o/图.jpg" "$a")" "相同"
    check_same "方向 $o：两条路的产物 Orientation 相同" "$(./Tests/probe "$a" Orientation)" "$(./Tests/probe "$b" Orientation)"
    check_same "方向 $o：两条路的产物解码像素相同" "$(./Tests/probe --pixels "$a")" "$(./Tests/probe --pixels "$b")"
done

# 4. 退回旧路：照搬会让视图退步的两张，产物与 --no-raw-exif 逐字节相同，校验输出逐行相同。
# EXIF 与 IIM 的时间打架让视图退步（说明打架放行，时间的不放行）；第二张另有一条无前缀备注，
# 备注改写了，照样退回。系统重写把 EXIF 的说明换成了 IIM 那份，两条路都由原文核对报出来。
for what in 只改IIM 无前缀加只改IIM; do
    for mode in "" --no-raw-exif; do
        d="$WORK/照搬/$what${mode}"
        mkdir -p "$d"
        ./Tests/fixture "$d/样本.jpg" >/dev/null
        [ "$what" = 无前缀加只改IIM ] && make_sample ./Tests/mangle-tool "$d/样本.jpg" "$NOTE"
        make_sample ./Tests/mangle-tool --replace "$d/样本.jpg" "184207+0800" "104207+0000"
    done
    a="$WORK/照搬/$what" b="$WORK/照搬/$what--no-raw-exif"
    out_a=$(cd "$a" && "$OLDPWD/$BIN" -v --verify 样本.jpg 2>&1)
    out_b=$(cd "$b" && "$OLDPWD/$BIN" -v --verify --no-raw-exif 样本.jpg 2>&1)
    cmp -s "$a/样本.heic" "$b/样本.heic" && [ -s "$a/样本.heic" ] \
        && pass "$what：默认路径的产物与 --no-raw-exif 的逐字节相同" || fail "$what：两条路的产物不同"
    grep -qE "EXIF 没有照搬：照搬后 .+" <<< "$out_a" \
        && pass "$what：-v 说了没照搬的原因" || { fail "$what：-v 没说没照搬的原因"; sed 's/^/     /' <<< "$out_a"; }
    check_same "$what：校验输出逐行相同" "$(grep -v "EXIF 没有照搬" <<< "$out_a")" "$out_b"
    grep -qF "变化 EXIF 说明 ImageDescription 的原文：西湖日落 sunset at West Lake → IPTC 备注字段" <<< "$out_b" \
        && pass "$what（--no-raw-exif）：报出说明的原文被换成 IIM 那份" \
        || { fail "$what（--no-raw-exif）：没报说明的原文"; sed 's/^/     /' <<< "$out_b"; }
done

# 6. 增益图与辅助图：照搬只动 EXIF，辅助图与 HDR 解码与 --no-raw-exif 的产物相同。3 通道的
# ISO 增益图（像素格式 420f）--aux-diff 读不了，那一张只比 HDR 解码出来的最亮值。
mkdir -p "$WORK/照搬/辅助图" "$WORK/照搬/辅助图重写"
./Tests/fixture --aux depth --aux matte --aux gainmap "$WORK/照搬/辅助图/三种.jpg" >/dev/null
./Tests/fixture --iso-gainmap "$WORK/照搬/辅助图/ISO.jpg" >/dev/null
cp "$WORK/照搬/辅助图/ISO.jpg" "$WORK/照搬/辅助图/彩色.jpg"
make_sample ./Tests/mangle-tool --color-gainmap "$WORK/照搬/辅助图/彩色.jpg"
while IFS='|' read -r name types; do
    a="$WORK/照搬/辅助图/$name" b="$WORK/照搬/辅助图重写/$name"
    cp "$a.jpg" "$b.jpg"
    "$BIN" "$a.jpg" >/dev/null 2>&1
    "$BIN" --no-raw-exif "$b.jpg" >/dev/null 2>&1
    check "$name：产物的 EXIF 与源逐字节相同" "$(./Tests/probe --exif-same "$a.jpg" "$a.heic")" "相同"
    for type in $types; do
        check "$name：$type 与 --no-raw-exif 的产物相差 0 级" "$(./Tests/probe --aux-diff "$b.heic" "$a.heic" "$type")" "0"
    done
    check_same "$name：内容余量与 --no-raw-exif 的产物相同" \
        "$(./Tests/probe --headroom "$a.heic")" "$(./Tests/probe --headroom "$b.heic")"
    check_same "$name：按 HDR 解码的最亮值与 --no-raw-exif 的产物相同" \
        "$(./Tests/probe --hdr-peak "$a.heic")" "$(./Tests/probe --hdr-peak "$b.heic")"
done <<'EOF'
三种|Depth PortraitEffectsMatte HDRGainMap
ISO|ISOGainMap
彩色|
EOF

round "7m. 带无前缀备注的照片也整块照搬"
# ImageIO 读不出的无前缀 UserComment：照搬的块上只改备注那一条（新值接在块末尾，条目的
# type/count/offset 指过去），改成 ImageIO 读得出的写法。纯 ASCII 用 ASCII 头；否则 UNICODE 头
# 加 BOM 加与 TIFF 同字节序的 UTF-16（ImageIO 没有 BOM 时一律当大端读）。
mkdir -p "$WORK/备注改写/源副本" "$WORK/备注改写/重写"
# 用法：expect_rewritten 描述 文件 原文 新值头部的十六进制（九条断言）
# 同时把同一张图的拷贝走 --no-raw-exif（紧挨着跑），输出留在 RW_OUT 里。
expect_rewritten() {
    local what=$1 f=$2 text=$3 head=$4 out n raw count name
    name=$(basename "$f")
    local ref="$WORK/备注改写/源副本/$name" rw="$WORK/备注改写/重写/$name"
    cp "$f" "$ref"; cp "$f" "$rw"
    out=$("$BIN" -v --delete-original "$f" 2>&1); st=$?
    RW_OUT=$("$BIN" -v --delete-original --no-raw-exif "$rw" 2>&1)
    grep -qE "EXIF 整块照搬（[0-9]+ 字节，备注改写成 ImageIO 读得出的写法）" <<< "$out" \
        && pass "$what：-v 说照搬了并改写了备注" || { fail "$what：-v 没说改写了备注"; sed 's/^/     /' <<< "$out"; }
    grep -q "元数据校验通过" <<< "$out" \
        && pass "$what：校验通过" || { fail "$what：校验报了差异"; sed 's/^/     /' <<< "$out"; }
    refute "$what：校验通过后删了源" "$st" test -e "$f"
    check "$what：产物里 ImageIO 读得出备注，等于原文" \
        "$(./Tests/probe --no-repair "${f%.jpg}.heic" '{Exif}/UserComment')" "$text"
    check "$what：产物的 EXIF 只差备注改写" "$(./Tests/probe --exif-same "$ref" "${f%.jpg}.heic")" "只差备注改写"
    check "$what：Exif 项在文件末尾" "$(./Tests/probe --exif-at-end "${f%.jpg}.heic")" "末尾"
    raw=$(./Tests/probe --raw-exif "${f%.jpg}.heic" 9286)
    [[ "$raw" == "ExifIFD UNDEFINED "*" $head"* ]] \
        && pass "$what：新值是 UNDEFINED，以 $head 开头" || fail "$what：新值的写法不对（[$raw]）"
    grep -q "元数据校验通过" <<< "$RW_OUT" || grep -q "元数据校验发现" <<< "$RW_OUT" \
        && pass "$what（--no-raw-exif）：转换并校验了" || { fail "$what（--no-raw-exif）：没转换"; sed 's/^/     /' <<< "$RW_OUT"; }
    # 照搬了的产物比 ImageIO 重写的恰好大「4 字节偏移 + Exif\0\0 + 源 TIFF + 补齐 + 新值」。
    n=$(grep -oE "EXIF 整块照搬（[0-9]+ 字节" <<< "$out" | grep -oE "[0-9]+")
    count=$(cut -d' ' -f3 <<< "$raw")
    check_same "$what：产物比 --no-raw-exif 的恰好大 10 + 源 TIFF + 补齐 + 新值的字节数" \
        "$(( $(stat -f %z "${f%.jpg}.heic") - $(stat -f %z "${rw%.jpg}.heic") ))" \
        "$(( 10 + ${n:-0} + ${n:-0} % 2 + ${count:-0} ))"
}
UNICODE_MM="554e49434f444500feff" UNICODE_II="554e49434f444500fffe" ASCII_HEAD="4153434949000000"
# 1. 大端，中文备注，加上 ImageIO 读不出的那组标签和秒是分母 1000000 的 GPS。
f="$WORK/备注改写/大端中文.jpg"
./Tests/fixture "$f" >/dev/null
make_sample ./Tests/mangle-tool "$f" "$NOTE"
make_sample ./Tests/mangle-tool --tags "$f" 'gps:001B:ascii=CELLID' 'exif:9208:long=0' \
    'exif:C000:ascii=私有串' 'exif:010D:ascii=放错位置的文档名' \
    'exif:927C:undef=J' 'exif:927C:undef=##**N4206_vivi' 'exif:927C:undef=Auto' \
    'gps:0004:rational=120/1,8/1,55304567/1000000'
check "大端中文：前提，ImageIO 读不出源里的备注" "$(./Tests/probe --no-repair "$f" '{Exif}/UserComment')" "<无>"
expect_rewritten "大端中文" "$f" "$NOTE" "$UNICODE_MM"
for want in '丢失 EXIF 标签 GPSProcessingMethod（GPS 0x001B，ASCII，"CELLID"）——类型不合规范' \
    '丢失 EXIF 标签 MakerNote（ExifIFD 0x927C，UNDEFINED，"J"、"##**N4206_vivi"、"Auto"，同号条目 3 个）' \
    "变化 GPS 经度：120°8′55.304567″ → 120°8′55.3″（HEIF 写入器只保留到 1/100 秒）"; do
    grep -qF -- "$want" <<< "$RW_OUT" \
        && pass "大端中文（--no-raw-exif）：照报「$want」" || { fail "大端中文（--no-raw-exif）：没报「$want」"; sed 's/^/     /' <<< "$RW_OUT"; }
done
# 2. 小端：真实相机照片（没有 UserComment）加一条无前缀的中文备注。MakerNote 原样过去，
#    {ExifAux}/ImageStabilization 读得出；交给系统重写时它没了。
f="$WORK/备注改写/小端中文.jpg"
cp test_pic/P1130939.JPG "$f"
make_sample ./Tests/mangle-tool --strip-trailer "$f"
make_sample ./Tests/mangle-tool --tags "$f" "exif:9286:undef=$NOTE"
# P1130939 的第一个段就是 EXIF 的 APP1：TIFF 头在文件的第 12 个字节。
check "小端中文：前提，TIFF 是小端" "$(dd if="$f" bs=1 skip=6 count=4 2>/dev/null; dd if="$f" bs=1 skip=12 count=2 2>/dev/null)" "ExifII"
check "小端中文：前提，ImageIO 读不出源里的备注" "$(./Tests/probe --no-repair "$f" '{Exif}/UserComment')" "<无>"
stab=$(./Tests/probe "$f" '{ExifAux}/ImageStabilization')
expect_rewritten "小端中文" "$f" "$NOTE" "$UNICODE_II"
check_same "小端中文：产物里 {ExifAux}/ImageStabilization 与源相同" \
    "$(./Tests/probe "$WORK/备注改写/小端中文.heic" '{ExifAux}/ImageStabilization')" "$stab"
check "小端中文（--no-raw-exif）：前提，系统重写的产物里没有 {ExifAux}/ImageStabilization" \
    "$(./Tests/probe "$WORK/备注改写/重写/小端中文.heic" '{ExifAux}/ImageStabilization')" "<无>"
# 3. 纯 ASCII 的无前缀备注，大端、小端各一。
f="$WORK/备注改写/大端ASCII.jpg"
./Tests/fixture "$f" >/dev/null
make_sample ./Tests/mangle-tool "$f" "Leuven City Hall 2024"
expect_rewritten "大端 ASCII" "$f" "Leuven City Hall 2024" "$ASCII_HEAD"
f="$WORK/备注改写/小端ASCII.jpg"
cp test_pic/P1130939.JPG "$f"
make_sample ./Tests/mangle-tool --strip-trailer "$f"
make_sample ./Tests/mangle-tool --tags "$f" "exif:9286:undef=Leuven City Hall 2024"
expect_rewritten "小端 ASCII" "$f" "Leuven City Hall 2024" "$ASCII_HEAD"
# 4. BMP 之外的字符（代理对）。
f="$WORK/备注改写/表情.jpg"
./Tests/fixture "$f" >/dev/null
make_sample ./Tests/mangle-tool "$f" "🎉拍照😀好看👍"
expect_rewritten "表情符号" "$f" "🎉拍照😀好看👍" "$UNICODE_MM"
# 6. 不该改写的不改写：普通夹具（备注本来就有 UNICODE 头）、改成另一段带 UNICODE 头的备注、没有备注。
mkdir -p "$WORK/备注改写/不改写"
./Tests/fixture "$WORK/备注改写/不改写/普通.jpg" >/dev/null
./Tests/fixture "$WORK/备注改写/不改写/UNICODE头.jpg" >/dev/null
make_sample ./Tests/mangle-tool --unicode-comment "$WORK/备注改写/不改写/UNICODE头.jpg" "备注：带合规头的中文备注"
# 没有备注的用相机照片：夹具 --no-text 那张的 EXIF 与 ImageIO 写的逐字节相同，不走照搬。
cp test_pic/P1130939.JPG "$WORK/备注改写/不改写/没有备注.jpg"
check "没有备注：前提，源里没有 0x9286" "$(./Tests/probe --raw-exif "$WORK/备注改写/不改写/没有备注.jpg" 9286)" "<无>"
for what in 普通 UNICODE头 没有备注; do
    f="$WORK/备注改写/不改写/$what.jpg"
    cp "$f" "${f%.jpg}-源.jpg"
    out=$("$BIN" -v --verify "$f" 2>&1)
    grep -qE "^    EXIF 整块照搬（[0-9]+ 字节）$" <<< "$out" \
        && pass "$what：照搬了，-v 里没有「改写」" || { fail "$what：没照搬，或说了改写"; sed 's/^/     /' <<< "$out"; }
    check "$what：产物的 EXIF 与源逐字节相同" "$(./Tests/probe --exif-same "${f%.jpg}-源.jpg" "${f%.jpg}.heic")" "相同"
done

round "7n. 备注的读法：可靠的文本照原文修补，猜的原样照搬"
# 备注的各种存法，大端（夹具）、小端（相机照片）各一份。`ASCII` 头里装 UTF-8 的，ImageIO 按
# Latin-1 读成乱码，要修补；字节不是合法 UTF-8 的（GBK、Latin-1 写的西欧文字），工具分不出是
# 哪种编码，默认路径原样照搬、一个字节不动。
mkdir -p "$WORK/备注读法"
# 用法：comment_sample 文件 大端|小端 值（--tags 的 undef 写法，`\0` 是 NUL、`\xHH` 是一个字节）
comment_sample() {
    if [ "$2" = 大端 ]; then
        ./Tests/fixture "$1" >/dev/null || fail "造不出样本：$1"
    else
        cp test_pic/P1130939.JPG "$1"
        make_sample ./Tests/mangle-tool --strip-trailer "$1"
    fi
    make_sample ./Tests/mangle-tool --tags "$1" "exif:9286:undef=$3"
}
# 用法：expect_repaired 描述 文件 原文 通过|无备注行（七条断言）。默认路径与 --no-raw-exif 各转一份；第四个参数是 --no-raw-exif 的校验要求。
expect_repaired() {
    local what=$1 f=$2 text=$3 out rw="${2%.jpg}-重写.jpg" ref="${2%.jpg}-源副本.jpg"
    cp "$f" "$rw"; cp "$f" "$ref"
    out=$("$BIN" -v --verify "$f" 2>&1)
    grep -qE "EXIF 整块照搬（[0-9]+ 字节，备注改写成 ImageIO 读得出的写法）" <<< "$out" \
        && pass "$what：-v 说照搬了并改写了备注" || { fail "$what：-v 没说改写了备注"; sed 's/^/     /' <<< "$out"; }
    grep -q "元数据校验通过" <<< "$out" \
        && pass "$what：校验通过" || { fail "$what：校验报了差异"; sed 's/^/     /' <<< "$out"; }
    check "$what：产物里 ImageIO 读出的备注等于原文" \
        "$(./Tests/probe --no-repair "${f%.jpg}.heic" '{Exif}/UserComment')" "$text"
    check "$what：产物的 EXIF 只差备注改写" "$(./Tests/probe --exif-same "$ref" "${f%.jpg}.heic")" "只差备注改写"
    out=$("$BIN" -v --verify --no-raw-exif "$rw" 2>&1)
    # 相机照片交给系统重写本来就丢 MakerNote 等，那时只要求校验里没有关于备注的行。
    if [ "$4" = 通过 ]; then
        grep -q "元数据校验通过" <<< "$out" \
            && pass "$what（--no-raw-exif）：校验通过" || { fail "$what（--no-raw-exif）：校验报了差异"; sed 's/^/     /' <<< "$out"; }
    elif grep -q "元数据校验" <<< "$out" && ! grep -q "UserComment" <<< "$out"; then
        pass "$what（--no-raw-exif）：校验了，没有关于备注的差异行"
    else
        fail "$what（--no-raw-exif）：没校验，或报了备注"; sed 's/^/     /' <<< "$out"
    fi
    check "$what（--no-raw-exif）：产物里 ImageIO 读出的备注等于原文" \
        "$(./Tests/probe --no-repair "${rw%.jpg}.heic" '{Exif}/UserComment')" "$text"
    check "$what（--no-raw-exif）：产物的备注是 UNICODE 头加 BOM" \
        "$(./Tests/probe --raw-exif "${rw%.jpg}.heic" 9286 | cut -d' ' -f4 | cut -c1-20)" "$UNICODE_MM"
}
# 用法：expect_untouched 描述 文件（四条断言）。默认路径原样照搬、不改写，校验通过，删了源。
# 转换之前先拷一份 <文件>-重写.jpg 留给 --no-raw-exif。
expect_untouched() {
    local what=$1 f=$2 out st ref="${2%.jpg}-源副本.jpg"
    cp "$f" "$ref"; cp "$f" "${f%.jpg}-重写.jpg"
    out=$("$BIN" -v --delete-original "$f" 2>&1); st=$?
    grep -qE "^    EXIF 整块照搬（[0-9]+ 字节）$" <<< "$out" \
        && pass "$what：照搬了，-v 里没有「改写」" || { fail "$what：没照搬，或说了改写"; sed 's/^/     /' <<< "$out"; }
    check "$what：产物的 EXIF 与源逐字节相同" "$(./Tests/probe --exif-same "$ref" "${f%.jpg}.heic")" "相同"
    grep -q "元数据校验通过" <<< "$out" \
        && pass "$what：校验通过" || { fail "$what：校验报了差异"; sed 's/^/     /' <<< "$out"; }
    refute "$what：校验通过后删了源" "$st" test -e "$f"
}
GBK='\xCE\xF7\xBA\xFE\xC3\xC0\xBE\xB0'   # 「西湖美景」的 GBK 字节
for endian in 大端 小端; do
    d="$WORK/备注读法/$endian"
    mkdir -p "$d"
    # 1. ASCII 头 + UTF-8 中文。
    f="$d/ASCII头UTF8.jpg"
    comment_sample "$f" "$endian" "ASCII\\0\\0\\0$NOTE"
    seen=$(./Tests/probe --no-repair "$f" '{Exif}/UserComment')
    case "$seen" in
        ""|"<无>"|"<无法读取>"|"$NOTE") fail "$endian ASCII 头 + UTF-8：前提，ImageIO 把源里的备注读成乱码（实际 [$seen]）" ;;
        *) pass "$endian ASCII 头 + UTF-8：前提，ImageIO 把源里的备注读成乱码" ;;
    esac
    expect_repaired "$endian ASCII 头 + UTF-8" "$f" "$NOTE" "$([ "$endian" = 大端 ] && echo 通过 || echo 无备注行)"
    # 2–4. 字节不是合法 UTF-8 的：无前缀 GBK、ASCII 头 GBK、无前缀 Latin-1（café）。
    #    交给系统重写时按 Latin-1 猜出来的那串写进产物，备注原文核对报出来、不删源。
    while IFS='|' read -r name value hex n; do
        f="$d/$name.jpg"
        comment_sample "$f" "$endian" "$value"
        check "$endian $name：前提，源里 0x9286 的值是造的那些字节" \
            "$(./Tests/probe --raw-exif "$f" 9286 | cut -d' ' -f4 | cut -c1-${#hex})" "$hex"
        expect_untouched "$endian $name" "$f"
        XFLAGS=--no-raw-exif expect_reported "$endian $name（--no-raw-exif）" "${f%.jpg}-重写.jpg" \
            "变化 备注 UserComment：源里的字节不是合法的 UTF-8（$n 字节），产物里换了一种写法，原文无法核对"
    done <<EOF
无前缀GBK|$GBK|cef7bafec3c0beb0|8
ASCII头GBK|ASCII\\0\\0\\0$GBK|4153434949000000cef7bafe|16
无前缀Latin1|caf\\xE9 au lait|636166e9|12
EOF
done
# 5. 纯中文的 UNICODE 备注（普通夹具）：系统重写时带 BOM。
f="$WORK/备注读法/普通.jpg"
./Tests/fixture "$f" >/dev/null
out=$("$BIN" -v --verify --no-raw-exif "$f" 2>&1)
grep -q "元数据校验通过" <<< "$out" \
    && pass "普通夹具（--no-raw-exif）：校验通过" || { fail "普通夹具（--no-raw-exif）：校验报了差异"; sed 's/^/     /' <<< "$out"; }
check "普通夹具（--no-raw-exif）：产物的备注是 UNICODE 头加 BOM" \
    "$(./Tests/probe --raw-exif "${f%.jpg}.heic" 9286 | cut -d' ' -f4 | cut -c1-20)" "$UNICODE_MM"
check_same "普通夹具（--no-raw-exif）：产物里 ImageIO 读出的备注与源相同" \
    "$(./Tests/probe --no-repair "${f%.jpg}.heic" '{Exif}/UserComment')" "$(./Tests/probe --no-repair "$f" '{Exif}/UserComment')"
# 7. 小端 EXIF 里没有 BOM 的小端 UNICODE 备注：ImageIO 当大端读成乱码（不改），默认路径照旧原样照搬。
f="$WORK/备注读法/小端UNICODE无BOM.jpg"
comment_sample "$f" 小端 'UNICODE\0\x81\x9C\x76\x6C\x02\x5E\x3F\x65\x85\x53'
seen=$(./Tests/probe --no-repair "$f" '{Exif}/UserComment')
case "$seen" in
    ""|"<无>"|"<无法读取>"|"鲁汶市政厅") fail "小端 UNICODE 无 BOM：前提，ImageIO 读成乱码（实际 [$seen]）" ;;
    *) pass "小端 UNICODE 无 BOM：前提，ImageIO 读成乱码" ;;
esac
expect_untouched "小端 UNICODE 无 BOM" "$f"
# 6–7. 备注原文核对对正常样本零噪声：两条路的校验都没有「备注 UserComment」那几行。
# 用法：expect_no_comment_line 描述 文件（两条断言）：默认路径、--no-raw-exif 各转一份拷贝。
expect_no_comment_line() {
    local what=$1 flags out copy
    for flags in "" --no-raw-exif; do
        copy="${2%.jpg}${flags:+-重写}.jpg"
        [ -f "$copy" ] || cp "$2" "$copy"
        # shellcheck disable=SC2086  # flags 为空时不能变成一个空参数
        out=$("$BIN" -v --verify -f $flags "$copy" 2>&1)
        if grep -q "元数据校验" <<< "$out" && ! grep -q "备注 UserComment" <<< "$out"; then
            pass "$what${flags:+（$flags）}：校验了，没有备注原文的行"
        else
            fail "$what${flags:+（$flags）}：没校验，或报了备注原文"; sed 's/^/     /' <<< "$out"
        fi
    done
}
# 默认路径：再转一份，没有备注原文的行。系统重写：ImageIO 把读出的乱码带着 BOM（声明了大端）
# 写进产物，原文（按小端 TIFF 的字节序解）没了，备注原文核对报出来，不删源。
cp "${f%.jpg}-重写.jpg" "${f%.jpg}-再照搬.jpg"
out=$("$BIN" -v --verify "${f%.jpg}-再照搬.jpg" 2>&1)
if grep -q "元数据校验" <<< "$out" && ! grep -q "备注 UserComment" <<< "$out"; then
    pass "小端 UNICODE 无 BOM：校验了，没有备注原文的行"
else
    fail "小端 UNICODE 无 BOM：没校验，或报了备注原文"; sed 's/^/     /' <<< "$out"
fi
XFLAGS=--no-raw-exif expect_reported "小端 UNICODE 无 BOM（--no-raw-exif）" "${f%.jpg}-重写.jpg" \
    "变化 备注 UserComment 的原文：鲁汶市政厅 → "
mkdir -p "$WORK/备注读法/零噪声"
z="$WORK/备注读法/零噪声"
./Tests/fixture "$z/普通.jpg" >/dev/null
while IFS='|' read -r name text; do
    ./Tests/fixture "$z/$name.jpg" >/dev/null
    make_sample ./Tests/mangle-tool --unicode-comment "$z/$name.jpg" "$text"
done <<'EOF'
UNICODE备注|备注：带合规头的中文备注
中英混排|鲁汶市政厅 City Hall 2024
ASCII开头的中文|Leuven 鲁汶 City Hall 市政厅
大端无BOM带emoji|🎉拍照😀好看👍今天天气很好适合出门啊啊
EOF
while IFS='|' read -r name value; do
    ./Tests/fixture "$z/$name.jpg" >/dev/null
    make_sample ./Tests/mangle-tool --tags "$z/$name.jpg" "exif:9286:undef=$value"
done <<'EOF'
纯ASCII|ASCII\0\0\0Leuven City Hall 2024
尾部NUL填充|ASCII\0\0\0Leuven\0\0\0\0\0\0
尾部空格填充|鲁汶市政厅\x20\x20\x20\x20\x20\x20
EOF
cp test_pic/IMG_1225.JPG "$z/IMG_1225.jpg"
cp test_pic/P1130939.JPG "$z/P1130939.jpg"
for name in 普通 UNICODE备注 中英混排 ASCII开头的中文 大端无BOM带emoji 纯ASCII 尾部NUL填充 尾部空格填充 IMG_1225 P1130939; do
    expect_no_comment_line "零噪声 $name" "$z/$name.jpg"
done

round "7o. 把「照片」的说明写进文件（--embed-caption）"
C="$WORK/写说明"
mkdir -p "$C"
CAPX=com.apple.assetsd.description
DESC='XMP/dc:description[x-default]'
# 没有任何文本字段的夹具加上「照片」的说明：不带选项不写，带选项写进 XMP。
./Tests/fixture --no-text "$C/无文本.jpg" >/dev/null
make_sample xattr -w "$CAPX" "西湖日落，和外婆一起" "$C/无文本.jpg"
cp "$C/无文本.jpg" "$C/不带.jpg"
cp "$C/无文本.jpg" "$C/带.jpg"
no_out=$("$BIN" --verify -v "$C/不带.jpg" 2>&1); st=$?
check "不带选项：产物里没有 dc:description" "$(./Tests/probe "$C/不带.heic" "$DESC")" "<无>"
refute "不带选项：-v 里没有说明那一行" "$st" grep -qF "「照片」的说明" <<< "$no_out"
yes_out=$("$BIN" --verify -v --embed-caption "$C/带.jpg" 2>&1)
check "带选项：产物的 $DESC 是说明" "$(./Tests/probe "$C/带.heic" "$DESC")" "西湖日落，和外婆一起"
check "带选项：产物的 {IPTC}/Caption/Abstract 也是说明" \
    "$(./Tests/probe "$C/带.heic" '{IPTC}/Caption/Abstract')" "西湖日落，和外婆一起"
grep -q "元数据校验通过" <<< "$yes_out" \
    && pass "带选项：校验通过" || { fail "带选项：校验报了差异"; sed 's/^/     /' <<< "$yes_out"; }
grep -qF "「照片」的说明：写进了 XMP 的 dc:description（10 个字符）" <<< "$yes_out" \
    && pass "带选项：-v 说写了 10 个字符" || { fail "带选项：-v 没说写了"; sed 's/^/     /' <<< "$yes_out"; }
check_same "带选项：产物上的扩展属性还在" \
    "$(xattr -px "$CAPX" "$C/带.heic" 2>/dev/null)" "$(xattr -px "$CAPX" "$C/带.jpg" 2>/dev/null)"
check_same "带选项：-v 里 EXIF 那一行与不带选项时相同" \
    "$(grep EXIF <<< "$yes_out")" "$(grep EXIF <<< "$no_out")"
check_same "带选项：--exif-same 与不带选项时相同" \
    "$(./Tests/probe --exif-same "$C/带.jpg" "$C/带.heic")" "$(./Tests/probe --exif-same "$C/不带.jpg" "$C/不带.heic")"
# 换行、emoji、很长的说明。用法：caption_variant 名字 说明 字符数（两条断言）
caption_variant() {
    local f="$C/$1.jpg" out
    ./Tests/fixture --no-text "$f" >/dev/null
    make_sample xattr -w "$CAPX" "$2" "$f"
    out=$("$BIN" --verify -v --embed-caption "$f" 2>&1)
    check "$1：产物的 $DESC 是说明" "$(./Tests/probe "${f%.jpg}.heic" "$DESC")" "$2"
    if grep -q "元数据校验通过" <<< "$out" && grep -qF "dc:description（$3 个字符）" <<< "$out"; then
        pass "$1：校验通过，-v 说写了 $3 个字符"
    else
        fail "$1：校验没通过或 -v 没说写了 $3 个字符"; sed 's/^/     /' <<< "$out" | head -20
    fi
}
caption_variant "带换行和emoji" $'第一行：西湖\n第二行：日落 🌅😀' 16
caption_variant "很长的说明" "$(printf '长说明%.0s' $(seq 1 1200))" 3600
# 源里没有 XMP 包的相机照片（截掉尾部的 MPF 预览图，让校验能通过）：照样写得进去，EXIF 照常整块照搬。
cp test_pic/P1130939.JPG "$C/相机-不带.jpg"
chmod u+w "$C/相机-不带.jpg"
make_sample ./Tests/mangle-tool --strip-trailer "$C/相机-不带.jpg"
make_sample xattr -w "$CAPX" "松下相机拍的" "$C/相机-不带.jpg"
cp "$C/相机-不带.jpg" "$C/相机-带.jpg"
check "前提：相机照片里没有 XMP 包" "$(./Tests/probe "$C/相机-不带.jpg" 'XMP/iio:hasXMP')" "<无>"
cam_no=$("$BIN" --verify -v "$C/相机-不带.jpg" 2>&1)
cam_yes=$("$BIN" --verify -v --embed-caption "$C/相机-带.jpg" 2>&1)
check "没有 XMP 包的源：产物的 $DESC 是说明" "$(./Tests/probe "$C/相机-带.heic" "$DESC")" "松下相机拍的"
grep -q "元数据校验通过" <<< "$cam_yes" \
    && pass "没有 XMP 包的源：校验通过" || { fail "没有 XMP 包的源：校验报了差异"; sed 's/^/     /' <<< "$cam_yes"; }
check_same "没有 XMP 包的源：EXIF 照常整块照搬（-v 那一行与不带选项时相同）" \
    "$(grep EXIF <<< "$cam_yes")" "$(grep EXIF <<< "$cam_no" | grep -F '整块照搬')"
check "没有 XMP 包的源：产物的 EXIF 与源逐字节相同" \
    "$(./Tests/probe --exif-same "$C/相机-带.jpg" "$C/相机-带.heic")" "相同"
# 文件里已有说明：不写、不崩，产物里的说明字段与不带选项时相同。
./Tests/fixture "$C/已有.jpg" >/dev/null
make_sample xattr -w "$CAPX" "扩展属性里的说明" "$C/已有.jpg"
cp "$C/已有.jpg" "$C/已有-不带.jpg"
out=$("$BIN" --verify -v --embed-caption "$C/已有.jpg" 2>&1); st=$?
check "已有三个说明字段：不崩（退出码 0，产出了 .heic）" "$st $([ -f "$C/已有.heic" ] && echo 有)" "0 有"
"$BIN" --verify "$C/已有-不带.jpg" >/dev/null 2>&1
for k in "$DESC" '{IPTC}/Caption/Abstract' '{TIFF}/ImageDescription'; do
    check_same "已有三个说明字段：产物的 $k 与不带选项时相同" \
        "$(./Tests/probe "$C/已有.heic" "$k")" "$(./Tests/probe "$C/已有-不带.heic" "$k")"
done
grep -qF "「照片」的说明：没写（文件里已有说明）" <<< "$out" \
    && pass "已有三个说明字段：-v 说文件里已有说明" || { fail "已有三个说明字段：-v 没说原因"; sed 's/^/     /' <<< "$out"; }
# 只有一个说明字段（写在哪一处不同；ImageIO 的视图会把三处调和成一样，原始存放用 --raw-exif 区分）。
for only in tiff iptc xmp; do
    f="$C/只有$only.jpg"
    ./Tests/fixture --no-text --caption-only "$only" "$f" >/dev/null
    make_sample xattr -w "$CAPX" "扩展属性里的说明" "$f"
    cp "$f" "${f%.jpg}-不带.jpg"
    raw=$(./Tests/probe --raw-exif "$f" 10E)
    if [ "$only" = tiff ]; then
        [ "$raw" != "<无>" ] && pass "前提：只有 tiff 的样本原始 EXIF 里有 ImageDescription" \
            || fail "前提：只有 tiff 的样本原始 EXIF 里没有 ImageDescription"
    else
        check "前提：只有 $only 的样本原始 EXIF 里没有 ImageDescription" "$raw" "<无>"
    fi
    out=$("$BIN" --verify -v --embed-caption "$f" 2>&1); st=$?
    check "只有 $only：不崩（退出码 0，产出了 .heic）" "$st $([ -f "${f%.jpg}.heic" ] && echo 有)" "0 有"
    "$BIN" --verify "${f%.jpg}-不带.jpg" >/dev/null 2>&1
    check_same "只有 $only：产物的 $DESC 与不带选项时相同" \
        "$(./Tests/probe "${f%.jpg}.heic" "$DESC")" "$(./Tests/probe "${f%.jpg}-不带.heic" "$DESC")"
    grep -qF "「照片」的说明：没写（文件里已有说明）" <<< "$out" \
        && pass "只有 $only：-v 说文件里已有说明" || { fail "只有 $only：-v 没说原因"; sed 's/^/     /' <<< "$out"; }
done
# 不写的其它情形：没有这个扩展属性、值是空白、值不是合法的 UTF-8。用法：caption_skipped 名字 原因
caption_skipped() {
    local f="$C/$1.jpg" out
    out=$("$BIN" --verify -v --embed-caption "$f" 2>&1)
    check "$1：产物里没有 dc:description" "$(./Tests/probe "${f%.jpg}.heic" "$DESC")" "<无>"
    grep -qF "「照片」的说明：没写（$2）" <<< "$out" \
        && pass "$1：-v 说$2" || { fail "$1：-v 没说$2"; sed 's/^/     /' <<< "$out"; }
}
./Tests/fixture --no-text "$C/没有属性.jpg" >/dev/null
caption_skipped 没有属性 "没有说明"
./Tests/fixture --no-text "$C/空白.jpg" >/dev/null
make_sample xattr -w "$CAPX" $'  \n\t ' "$C/空白.jpg"
caption_skipped 空白 "没有说明"
./Tests/fixture --no-text "$C/不是UTF8.jpg" >/dev/null
make_sample xattr -wx "$CAPX" "E8A5BFE6" "$C/不是UTF8.jpg"
caption_skipped 不是UTF8 "不是合法的 UTF-8"

round "7p. EXIF 与 IPTC 打架的照片也整块照搬"
# ImageIO 读 JPEG 时用 IIM 的值调和说明、作者、版权：IIM 摘要对不上时视图显示 IIM 的值，系统重写
# 把它写进产物的 EXIF。默认路径照搬，保留 EXIF 的原值，产物视图里显示的就是 EXIF 的原值。
# 样本是普通夹具只改 IIM（mangle --iim），别处不动，IIM 摘要于是对不上。夹具里 IIM 的说明本来
# 就与 EXIF 的不同（「IPTC 备注字段」），作者相同，没有版权。
P="$WORK/打架"
mkdir -p "$P"
EXIF_DESC="西湖日落 sunset at West Lake" EXIF_ARTIST="测试作者" EXIF_CR="(C) 2024 测试"
# 用法：conflict_sample 名字 IIM 改法...（造 $P/名字.jpg，另拷一份 $P/名字-重写.jpg 留给 --no-raw-exif）
conflict_sample() {
    local f="$P/$1.jpg"; shift
    ./Tests/fixture "$f" >/dev/null || fail "造不出样本：$f"
    make_sample ./Tests/mangle-tool --iim "$f" "$@"
    cp "$f" "${f%.jpg}-重写.jpg"
}
# 用法：expect_kept_original 描述 文件 组 键=EXIF 的原值...（两条断言，另加每个键一条）
# 默认路径走 -v --delete-original，输出留在 KEPT_OUT、退出码留在 KEPT_ST。
expect_kept_original() {
    local what=$1 f=$2 groups=$3 ref="${2%.jpg}-源副本.jpg" kv; shift 3
    cp "$f" "$ref"
    KEPT_OUT=$("$BIN" -v --delete-original "$f" 2>&1); KEPT_ST=$?
    grep -qE "^    EXIF 整块照搬（[0-9]+ 字节；${groups}与 IPTC 不一致，保留 EXIF 的原值）$" <<< "$KEPT_OUT" \
        && pass "$what：照搬了，-v 说${groups}保留 EXIF 的原值" \
        || { fail "$what：没照搬，或 -v 没说保留了哪几组"; sed 's/^/     /' <<< "$KEPT_OUT"; }
    check "$what：产物的 EXIF 与源逐字节相同" "$(./Tests/probe --exif-same "$ref" "${f%.jpg}.heic")" "相同"
    for kv in "$@"; do
        check "$what：产物里 ${kv%%=*} 是 EXIF 的原值" "$(./Tests/probe "${f%.jpg}.heic" "${kv%%=*}")" "${kv#*=}"
    done
}
# 用法：expect_conflict_lines 描述 文件 组:ImageIO原来显示的值...（接在 expect_kept_original 后面，
# 查 KEPT_OUT：校验恰好每组一处差异、每组一行合成的说明，源文件保留）
expect_conflict_lines() {
    local what=$1 f=$2 item group want; shift 2
    grep -qF "元数据校验发现 $# 处差异" <<< "$KEPT_OUT" \
        && pass "$what：校验恰好 $# 处差异" || { fail "$what：差异不是恰好 $# 处"; sed 's/^/     /' <<< "$KEPT_OUT"; }
    for item in "$@"; do
        group=${item%%:*}
        case "$group" in 说明) want=$EXIF_DESC ;; 作者) want=$EXIF_ARTIST ;; *) want=$EXIF_CR ;; esac
        grep -qF -- "- 变化 $group：源里 EXIF 与 IPTC 不一致，ImageIO 原来显示「${item#*:}」，产物显示 EXIF 的原值「$want」" \
            <<< "$KEPT_OUT" && pass "$what：$group 合成一行，说清原来显示什么、产物显示 EXIF 的原值" \
            || { fail "$what：$group 没有合成的那一行"; sed 's/^/     /' <<< "$KEPT_OUT"; }
    done
    refute "$what：源文件保留" "$KEPT_ST" test ! -f "$f"
}
# 1. 只有说明打架。
conflict_sample 说明 "2:120=IIM 里改过的说明"
check "说明：前提，源的 {TIFF}/ImageDescription 是 IIM 那份" \
    "$(./Tests/probe "$P/说明.jpg" '{TIFF}/ImageDescription')" "IIM 里改过的说明"
expect_kept_original "说明" "$P/说明.jpg" "说明" "{TIFF}/ImageDescription=$EXIF_DESC"
expect_conflict_lines "说明" "$P/说明.jpg" "说明:IIM 里改过的说明"
XFLAGS=--no-raw-exif expect_reported "说明（--no-raw-exif）" "$P/说明-重写.jpg" \
    "变化 EXIF 说明 ImageDescription 的原文：$EXIF_DESC → IIM 里改过的说明"
# 2. 作者打架、版权打架（IIM 的说明改成与 EXIF 相同，只剩这一组打架），三组一起打架。
conflict_sample 作者 "2:120=$EXIF_DESC" "2:80=IIM 作者"
check "作者：前提，源的 {TIFF}/Artist 是 IIM 那份、说明不打架" \
    "$(./Tests/probe "$P/作者.jpg" '{TIFF}/Artist')|$(./Tests/probe "$P/作者.jpg" '{TIFF}/ImageDescription')" \
    "IIM 作者|$EXIF_DESC"
expect_kept_original "作者" "$P/作者.jpg" "作者" "{TIFF}/Artist=$EXIF_ARTIST" "{IPTC}/Byline[0]=$EXIF_ARTIST"
expect_conflict_lines "作者" "$P/作者.jpg" "作者:IIM 作者"
XFLAGS=--no-raw-exif expect_reported "作者（--no-raw-exif）" "$P/作者-重写.jpg" \
    "变化 EXIF 作者 Artist 的原文：$EXIF_ARTIST → IIM 作者"
conflict_sample 版权 "2:120=$EXIF_DESC" "2:116=IIM 版权"
check "版权：前提，源的 {TIFF}/Copyright 是 IIM 那份、说明不打架" \
    "$(./Tests/probe "$P/版权.jpg" '{TIFF}/Copyright')|$(./Tests/probe "$P/版权.jpg" '{TIFF}/ImageDescription')" \
    "IIM 版权|$EXIF_DESC"
expect_kept_original "版权" "$P/版权.jpg" "版权" "{TIFF}/Copyright=$EXIF_CR" "XMP/dc:rights[x-default]=$EXIF_CR"
expect_conflict_lines "版权" "$P/版权.jpg" "版权:IIM 版权"
XFLAGS=--no-raw-exif expect_reported "版权（--no-raw-exif）" "$P/版权-重写.jpg" \
    "变化 EXIF 版权 Copyright 的原文：$EXIF_CR → IIM 版权"
conflict_sample 三组 "2:120=IIM 说明" "2:80=IIM 作者" "2:116=IIM 版权"
expect_kept_original "三组" "$P/三组.jpg" "说明、作者、版权" \
    "{TIFF}/ImageDescription=$EXIF_DESC" "{TIFF}/Artist=$EXIF_ARTIST" "{TIFF}/Copyright=$EXIF_CR"
expect_conflict_lines "三组" "$P/三组.jpg" "说明:IIM 说明" "作者:IIM 作者" "版权:IIM 版权"
# 3. IIM 声明 UTF-8 的 1:90 去掉：ImageIO 把 IIM 读成乱码，EXIF 里是好的中文。
conflict_sample 乱码 "1:90"
seen=$(./Tests/probe "$P/乱码.jpg" '{TIFF}/Artist')
seen_desc=$(./Tests/probe "$P/乱码.jpg" '{TIFF}/ImageDescription')
case "$seen|$seen_desc" in
    "|"*|"<无>|"*|"<无法读取>|"*|"$EXIF_ARTIST|"*|*"|"|*"|<无>"|*"|<无法读取>"|*"|$EXIF_DESC")
        fail "乱码：前提，源的 {TIFF}/Artist、{TIFF}/ImageDescription 是乱码（实际 [$seen]、[$seen_desc]）" ;;
    *) pass "乱码：前提，源的 {TIFF}/Artist、{TIFF}/ImageDescription 是乱码" ;;
esac
expect_kept_original "乱码" "$P/乱码.jpg" "说明、作者" "{TIFF}/ImageDescription=$EXIF_DESC" "{TIFF}/Artist=$EXIF_ARTIST"
expect_conflict_lines "乱码" "$P/乱码.jpg" "说明:$seen_desc" "作者:$seen"
XFLAGS=--no-raw-exif expect_reported "乱码（--no-raw-exif）" "$P/乱码-重写.jpg" \
    "变化 EXIF 说明 ImageDescription 的原文：$EXIF_DESC → $seen_desc" "变化 EXIF 作者 Artist 的原文：$EXIF_ARTIST → $seen"
# 5. 不放行的。EXIF 的说明是 GBK 字节（原文不可靠）又与 IIM 打架：ImageIO 读 HEIC 时不认这种说明，
#    照搬后视图照旧显示 XMP 里 IIM 那份，没有退步，照搬了，也没有放行哪一组。
conflict_sample GBK说明 "2:120=IIM 里改过的说明"
make_sample ./Tests/mangle-tool --tags "$P/GBK说明.jpg" 'ifd0:010E:ascii=\xCE\xF7\xBA\xFE'
cp "$P/GBK说明.jpg" "$P/GBK说明-重写.jpg"
out=$("$BIN" -v --verify "$P/GBK说明.jpg" 2>&1)
grep -qE "^    EXIF 整块照搬（[0-9]+ 字节）$" <<< "$out" \
    && pass "GBK 说明：照搬了，没有放行哪一组" || { fail "GBK 说明：没照搬，或说了保留 EXIF 的原值"; sed 's/^/     /' <<< "$out"; }
grep -q "元数据校验通过" <<< "$out" \
    && pass "GBK 说明：照搬的产物校验通过" || { fail "GBK 说明：照搬的产物校验报了差异"; sed 's/^/     /' <<< "$out"; }
#    系统重写把 IIM 那份写进 EXIF，GBK 的原文没了：源的字节不可靠，比字节。
XFLAGS=--no-raw-exif expect_reported "GBK 说明（--no-raw-exif）" "$P/GBK说明-重写.jpg" \
    "变化 EXIF 说明 ImageDescription：源里的字节不是合法的 UTF-8（5 字节），产物里换了一种写法，原文无法核对"
#    说明打架之外另有一个键退步（两条 0x9286 的无前缀备注改写不了，照搬后 ImageIO 读不出）：照旧退回。
conflict_sample 另有退步 "2:120=IIM 里改过的说明"
make_sample ./Tests/mangle-tool --tags "$P/另有退步.jpg" "exif:9286:undef=$NOTE" "exif:9286:undef=$NOTE"
out=$("$BIN" -v --verify "$P/另有退步.jpg" 2>&1)
grep -qF "EXIF 没有照搬：照搬后 {Exif}/UserComment 会读不出" <<< "$out" \
    && pass "另有退步：照旧退回系统重写，-v 说的是备注" || { fail "另有退步：照搬了，或原因不对"; sed 's/^/     /' <<< "$out"; }
# Copyright 写成「摄影师\0编辑者\0」两段：系统重写只留第一段，原文核对报出来；照搬的不报。
./Tests/fixture "$P/两段版权.jpg" >/dev/null
make_sample ./Tests/mangle-tool --tags "$P/两段版权.jpg" 'ifd0:8298:ascii=Photographer\0Editor'
cp "$P/两段版权.jpg" "$P/两段版权-重写.jpg"
out=$("$BIN" -v --verify "$P/两段版权.jpg" 2>&1)
grep -q "元数据校验通过" <<< "$out" \
    && pass "两段版权：照搬的产物校验通过" || { fail "两段版权：照搬的产物校验报了差异"; sed 's/^/     /' <<< "$out"; }
XFLAGS=--no-raw-exif expect_reported "两段版权（--no-raw-exif）" "$P/两段版权-重写.jpg" \
    '变化 EXIF 版权 Copyright 的原文：Photographer\0Editor → Photographer'
# 6. 不打架的零噪声：两条路的校验都没有这一轮的行（合成的一行、三个文字标签的原文核对）。
mkdir -p "$P/零噪声"
for v in 普通 no-exif-offset lossy rich-xmp no-text; do
    if [ "$v" = 普通 ]; then ./Tests/fixture "$P/零噪声/$v.jpg" >/dev/null; else ./Tests/fixture "--$v" "$P/零噪声/$v.jpg" >/dev/null; fi
done
cp test_pic/IMG_1225.JPG "$P/零噪声/IMG_1225.jpg"
cp test_pic/P1130939.JPG "$P/零噪声/P1130939.jpg"
for name in 普通 no-exif-offset lossy rich-xmp no-text IMG_1225 P1130939; do
    for flags in "" --no-raw-exif; do
        copy="$P/零噪声/$name${flags:+-重写}.jpg"
        [ -f "$copy" ] || cp "$P/零噪声/$name.jpg" "$copy"
        # shellcheck disable=SC2086  # flags 为空时不能变成一个空参数
        out=$("$BIN" -v --verify $flags "$copy" 2>&1)
        if grep -q "元数据校验" <<< "$out" && ! grep -qE "EXIF (说明|作者|版权) |与 IPTC 不一致" <<< "$out"; then
            pass "零噪声 $name${flags:+（$flags）}：校验了，没有这一轮的行"
        else
            fail "零噪声 $name${flags:+（$flags）}：没校验，或报了这一轮的行"; sed 's/^/     /' <<< "$out"
        fi
    done
done

round "7q. XMP 的键按命名空间认，不按 ImageIO 临时给的前缀"
# 富 XMP 的样本改出四种：photoshop 前缀配两种非标准 URI（p1、p2），jt 前缀配两种 URI（j1 原样、j2）。
# ImageIO 给前缀时，前缀被别的 URI 占着就改叫 `前缀_N_`，要不要加、加几取决于同一进程里同时还有
# 哪些 XMP 对象；并发转换时源读一次、产物读一次可能拿到不同的前缀。键按 URI 定才对得上。
N="$WORK/命名空间"
mkdir -p "$N/源"
./Tests/fixture --rich-xmp "$N/源/j1.jpg" >/dev/null
for n in 1 2; do
    cp "$N/源/j1.jpg" "$N/源/p$n.jpg"
    make_sample ./Tests/mangle-tool --replace "$N/源/p$n.jpg" \
        'xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"' "xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.$n/\""
done
cp "$N/源/j1.jpg" "$N/源/j2.jpg"
make_sample ./Tests/mangle-tool --replace "$N/源/j2.jpg" \
    'xmlns:jt="http://example.com/jpeg2heif/test/1.0/"' 'xmlns:jt="http://example.com/jpeg2heif/test/2.0/"'
ps_key() { printf 'XMP/photoshop{http%%3A%%2F%%2Fns.adobe.com%%2Fphotoshop%%2F1.%s%%2F}:City' "$1"; }
# 1. 确定性的见证：非标准 URI 借用标准前缀的那张单独转。键里带 URI，产物上同一个键同值；
#    URI 换成另一个的那张，产物上没有这个键。
mkdir -p "$N/单张"
cp "$N/源/p1.jpg" "$N/源/p2.jpg" "$N/源/j2.jpg" "$N/单张/"
out=$("$BIN" -v --verify "$N/单张/p1.jpg" 2>&1)
grep -q "元数据校验通过" <<< "$out" \
    && pass "借用标准前缀的命名空间：单独转，校验通过" || { fail "借用标准前缀的命名空间：单独转，校验报了差异"; sed 's/^/     /' <<< "$out"; }
check "借用标准前缀的命名空间：源的键带 URI" "$(./Tests/probe "$N/单张/p1.jpg" "$(ps_key 1)")" "杭州"
check_same "借用标准前缀的命名空间：产物上同一个键同值" \
    "$(./Tests/probe "$N/单张/p1.heic" "$(ps_key 1)")" "$(./Tests/probe "$N/单张/p1.jpg" "$(ps_key 1)")"
"$BIN" "$N/单张/p2.jpg" >/dev/null 2>&1 || fail "p2 转换失败"
check "URI 不同的那张：自己的键读得出" "$(./Tests/probe "$N/单张/p2.heic" "$(ps_key 2)")" "杭州"
check "URI 不同的那张：产物上没有 p1 的键" "$(./Tests/probe "$N/单张/p2.heic" "$(ps_key 1)")" "<无>"
check "jt 前缀配另一个 URI：键仍是 XMP/jt:Custom" "$(./Tests/probe "$N/单张/j2.jpg" 'XMP/jt:Custom')" "自定义命名空间的值"
# 2. 并发见证：四种各 10 份，-j 18 跑 3 批，每一批每一张都校验通过、都整块照搬。
for b in 1 2 3; do
    mkdir -p "$N/批$b"
    for i in $(seq 1 10); do for v in p1 p2 j1 j2; do cp "$N/源/$v.jpg" "$N/批$b/${v}_$i.jpg"; done; done
    out=$("$BIN" -v --verify -j 18 "$N/批$b" 2>&1)
    ok=$(grep -c "元数据校验通过" <<< "$out")
    check "并发第 $b 批：40 张都校验通过" "$ok" "40"
    [ "$ok" = 40 ] || grep -E "丢失|变化" <<< "$out" | sort | uniq -c | sed 's/^/     /'
    carried=$(grep -cE "^    EXIF 整块照搬（[0-9]+ 字节）$" <<< "$out")
    check "并发第 $b 批：40 张都整块照搬" "$carried" "40"
    [ "$carried" = 40 ] || grep -F "EXIF 没有照搬" <<< "$out" | sort | uniq -c | sed 's/^/     /'
    rm -rf "$N/批$b"
done

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

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
# 「少跑了却宣布通过」有三种走法，光看 FAILED 一种都看不出来——没跑就没失败。
# 三条 `[ -x Tests/X ]` 包装干的就是第二种（缺产物则静默少跑一整节，
# 结尾照样宣布通过）。那三条已经删了，下面三道守卫是防它从别的地方回来。
#   整轮消失 / 正文被跳过 -> 执行的断言条数对不上（EXPECTED_ASSERTIONS）
#   子套件自己缩水        -> 它自己的条数对不上（EXPECTED_UNIT / EXPECTED_GUI；
#                            它们各自只产出 1 个 pass，总数看不见它们缩水）
#   脚本中途死掉          -> trap 兜底（结尾的检查本身都执行不到）
# 加断言时要同步改这几个数。用精确值而不是下限：下限挡不住「加了 5 条、
# 同时静默少了 3 条」。
#
# 原先还有一个 EXPECTED_ROUNDS=12，删了：没有哪一轮是零断言（最少的也有 2 条），
# 所以整轮消失必然让条数也对不上，它没有独立覆盖。它唯一能独占抓到的是
# 「某轮标题从 round() 改成 echo 但正文照跑」——那不破坏任何覆盖；
# 而真该挡的「新增一轮却用 echo」它反而挡不住（ROUNDS 仍等于期望值）。
EXPECTED_ASSERTIONS=69
EXPECTED_UNIT=229
EXPECTED_GUI=37

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

[ -x "$BIN" ] || bail "先运行 make 构建 $BIN"

# 所有测试工具都由 Makefile 构建，这里只管用。
for tool in fixture probe; do
    [ -x "Tests/$tool" ] || bail "先运行 make test（缺 Tests/$tool）"
done
# 产物不仅要存在，还得是当前源码建出来的。本脚本原先只查存在，于是绕过 make
# 直接 `bash Tests/selftest.sh` 时，可能拿着几个来自**不同源码版本**的二进制
# 一起跑，得出任何单一版本都不会给出的结论——实测踩过一次，而且事后复现不出来，
# 这正是它危险的地方。
#
# 两件事都交给 make，不在这里自己攒：
#   清单——上一版硬编码了 7 个产物名，是 Makefile 那份清单的第二份拷贝。
#     往 TEST_TOOLS 加工具时这里会静默落后；更阴的是 `make -q` 对「文件存在但
#     不属于任何规则」也退出 0（实测 `make -q README.md` → 0），所以名字一旦
#     对不上，守卫是静默退化成空跑而不是报错。现在清单只有 Makefile 一份。
#   依赖——每个产物依赖哪些源文件只有 Makefile 知道（Tests/fixture 只依赖
#     自己那一个文件，Tests/probe 还依赖整个 Sources/Core），自己比 mtime 等于
#     重写一份依赖表。`make -q` 是只读的问询模式，不执行任何规则，所以从
#     make test 里反过来调它不会递归。
# 不吞 stderr：Makefile 真出语法错时，错误本身比「问不到清单」有用得多。
artifacts=$(make --no-print-directory print-artifacts) \
    || bail "问不到产物清单（make print-artifacts 失败，原因见上）"
[ -n "$artifacts" ] || bail "产物清单是空的（print-artifacts 没出声）"
for art in $artifacts; do
    # 缺产物在这里就停，不再 `continue`：那等于「缺了就算通过」，
    # 而这个守卫存在的全部意义就是不要静默通过。
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
# 把子套件自己的断言条数也钉住。原先这一整轮只产出 1 个 pass，于是
# EXPECTED_PASSES 完全感知不到单测缩水：实测删掉 20 条用例（175→155），
# 套件照样打印「全部通过（12 轮，58 项断言）」。这是「少跑了却宣布通过」的
# 第四种走法——被压成一个 pass 的子套件自己缩水——上一轮三道守卫都没看见。
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
{IPTC}/StarRating'
while IFS= read -r key; do
    want=$(./Tests/probe "$WORK/照片.jpg" "$key")
    got=$(./Tests/probe "$WORK/照片.heic" "$key")
    check_same "$key" "$got" "$want"
done <<< "$KEYS"

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
out=$("$BIN" -r "$WORK/相册" -o "$WORK/无冲突" 2>&1); st=$?
refute "无冲突时不改名、不报避让" "$st" grep -q "重名避让" <<< "$out"

round "5. 安全行为"
"$BIN" "$WORK/照片.jpg" 2>&1 | grep -q "输出已存在" && pass "不覆盖已有输出" || fail "应拒绝覆盖"
"$BIN" -q 2 "$WORK/照片.jpg" >/dev/null 2>&1; [ $? -eq 2 ] && pass "拒绝非法质量值" || fail "应拒绝非法质量值"
echo "not an image" > "$WORK/坏.jpg"
"$BIN" "$WORK/坏.jpg" 2>&1 | grep -q "不是 JPEG" && pass "跳过非 JPEG 文件" || fail "应跳过非 JPEG"
# 探针自己也得分清「整个文件读不出来」和「这个键不存在」。两者都报「无」时，
# 下面第 6 轮那条前提断言（seen = <无> 即算「ImageIO 读不出这种写法」）
# 在文件整体读不出来时也会通过。CGImageSourceCreateWithURL 对垃圾文件会成功，
# 所以这条必须拿一个真的垃圾文件来验，不能拿不存在的路径。
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
    # 只接受恰好的「无」。原先还接受空串，而空串可能是 probe 本身没出声——
    # 那会让这条前提在工具坏掉时也通过。
    [ "$seen" = "<无>" ] \
        && pass "确认 ImageIO 读不出这种写法" \
        || fail "前提不成立：ImageIO 读出了 [$seen]"
    # 非空守卫：上面那条只有在文件**本身读得出来**时才说明问题。probe 现在把
    # 「整个文件读不出来」报成 <无法读取>，但这条正面对照更直接：同一次调用、
    # 同一个文件、换一个键必须读得到值。
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

round "7. --delete-original 的安全边界"
# 全套功能里唯一会删除用户文件的一条，此前零覆盖——它的安全性完全依赖
# 「校验不通过就不删」这条逻辑，而那条逻辑本身没有测试守着。
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

# 那句说明是状态，不是元数据差异：它一度被塞进 issues 数组，于是差异数虚增一条，
# 界面的橙色徽章和弹窗标题也跟着多算。加不加 --delete-original，差异条数必须一样。
./Tests/fixture --lossy "$WORK/计数.jpg" >/dev/null
n1=$("$BIN" --verify "$WORK/计数.jpg" 2>&1 | grep -oE '发现 [0-9]+ 处差异')
rm -f "$WORK/计数.heic"
n2=$("$BIN" --delete-original "$WORK/计数.jpg" 2>&1 | grep -oE '发现 [0-9]+ 处差异')
check_same "状态说明不计入差异条数" "$n2" "$n1"

# 预演不该在磁盘上留下任何痕迹——曾经它会把输出目录先建出来
"$BIN" -n -r "$WORK/相册" -o "$WORK/预演输出" >/dev/null 2>&1; st=$?
refute "预演不创建输出目录" "$st" test -e "$WORK/预演输出"

# 预演绝不能删任何东西
cp "$WORK/照片.jpg" "$WORK/预演不删.jpg"
"$BIN" -n --delete-original "$WORK/预演不删.jpg" >/dev/null 2>&1; st=$?
refute "预演不删源文件" "$st" test ! -f "$WORK/预演不删.jpg"

# 真实相机照片：MakerNote 必然丢失，校验必须报出汇总行，--delete-original 不能删源。
# 用拷贝，test_pic/ 里的原件不可再生。
cp test_pic/IMG_1225.JPG "$WORK/相机.jpg"
camera_out=$("$BIN" -v --delete-original "$WORK/相机.jpg" 2>&1); st=$?
echo "$camera_out" | grep -q "丢失 厂商私有数据 MakerNote" \
    && pass "相机照片丢失 MakerNote 被报出" \
    || { fail "相机照片丢失 MakerNote 却没报"; echo "$camera_out" | sed 's/^/     /'; }
refute "相机照片丢了 MakerNote，源文件保留" "$st" test ! -f "$WORK/相机.jpg"

round "7b. 偏移只靠 XMP 承载"
# IIM 时间后缀里的偏移，在目标里的唯一承载是 ImageIO 合成的
# XMP/photoshop:DateCreated——前提是源里没有 EXIF OffsetTime*。默认那张夹具图
# 自己带 OffsetTimeOriginal，于是 offsetSurvives 永远在第一条就命中，等价字段
# （XMP 那条腿）那一半怎么写都不影响结果：实测把它整条删掉，默认图照样"校验通过"。
# 这一轮专门造一张只靠 XMP 承载的图，把那条腿接上。
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

round "8. 界面模型：指定输出文件夹与取消"
# 这两条走模型层而不是驱动窗口：「输出到指定文件夹」要经过 NSOpenPanel，
# 模态面板没法自动化，而 ConversionModel 覆盖的是同一套逻辑。
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
# 同上：这一轮的 ✓ 数原先只进文案不进断言，打印 0 条也算「全过」。
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

round "10. 审查账本：引文逐字、来源可溯、记录不腐"
# .scratch/verify-hardening 的全部价值在于「引的是审查当时的原话」。这组性质会
# 无声腐坏，所以必须有守卫而不是靠记得。四条独立性质，一个循环里一起查
# （上一版写成两个几乎逐字相同的循环——`08-03` 记的就是这个房规）。
ledger=.scratch/verify-hardening
checked=0; unsupported=0; derivative=0; rotten=0; noconcl=0; miscast=0
for issue in "$ledger"/issues/*.md; do
    [ -e "$issue" ] || break
    checked=$((checked + 1))
    rnd=$(sed -n 's/^Round: //p' "$issue" | head -1)
    source=$(sed -n 's/^Source: //p' "$issue" | head -1)
    sha=$(sed -n 's/^Fixed by: //p' "$issue" | head -1)
    revname=$(sed -n 's|^Review: \.\./reviews/||p' "$issue" | head -1)
    target="$ledger/reviews/$revname"
    printf -v _pad '%02d' "$rnd" 2>/dev/null || _pad=$(printf '%02d' "$rnd")

    grep -q '^## 结论$' "$issue" || noconcl=$((noconcl + 1))

    # 不是审查提的条目没有「意见原文」可引。上一版让 10-11 借了 round-10-spec.md
    # 里一句无关的真话来填这个字段，守卫照样放行——那是把字段当装饰。
    # 这类条目改用 `## 缺陷`（我观察到什么），并且不参与引文与溯源两项。
    selffound=0
    case "$source" in *我自己*) selffound=1 ;; esac
    # 数的是「几个文件错了」，不是「触发了几个条件」：一个自发现条目既缺
    # `## 缺陷` 又多一个 `## 意见原文`，那是一处错，不是两处（实测报成 2）。
    wrong=0
    if [ "$selffound" -eq 1 ]; then
        grep -q '^## 缺陷$' "$issue" || wrong=1
        grep -q '^## 意见原文$' "$issue" && wrong=1
        [ "$wrong" -eq 0 ] || miscast=$((miscast + 1))
        continue
    fi
    grep -q '^## 意见原文$' "$issue" || miscast=$((miscast + 1))

    # Fixed by: 只认三种取值。未知取值必须出声——上一版的 case 分支把它静默跳过，
    # 于是 14 条 `(git init 之前)` 从没被任何守卫看过一眼。
    # 别按长度猜它是不是 SHA：`dbb1e1`（6 位）git 认、而 `[0-9a-f]×7` 的模式
    # 不认，于是一个腐坏的短 SHA 会被静默跳过（实测）。交给 git 判。
    case "$sha" in
        "—"|"(git init 之前)") ;;
        *)  if git rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
                git merge-base --is-ancestor "$sha" HEAD 2>/dev/null \
                    || rotten=$((rotten + 1))
            else
                rotten=$((rotten + 1))
            fi ;;
    esac

    # 引文：只取 `## 意见原文` 段内的 blockquote，整段每一行都要核。
    # 上一版取的是整个文件的第一行 `> `，多行引文只查了一半。
    awk '/^## 意见原文$/{f=1;next} /^## /{f=0} f && /^> /{sub(/^> /,"");print}' \
        "$issue" > "$WORK/quote.txt"
    nq=$(grep -c . "$WORK/quote.txt")
    if [ ! -f "$target" ] || [ "$nq" -eq 0 ]; then
        unsupported=$((unsupported + 1))
    else
        tr -d '`*' < "$target" > "$WORK/target.txt"
        miss=0
        while IFS= read -r qline; do
            [ -n "$qline" ] || continue
            printf '%s' "$qline" | tr -d '`*' > "$WORK/q1.txt"
            grep -qF -f "$WORK/q1.txt" "$WORK/target.txt" || miss=1
        done < "$WORK/quote.txt"
        [ "$miss" -eq 0 ] || unsupported=$((unsupported + 1))
    fi

    # 来源可溯：`Review:` 和引文是同一只手写的，所以不能让它自由指定。某轮某轴的
    # agent 原文在库里时，引文就必须出自那一份；聚合报告是我自己写的，引它只能
    # 证明我写过，证明不了审查当时说了什么。只有那一侧的 agent 原文确实丢失
    # （上下文压缩，spec.md 列了哪些），或者这条本来就不是审查提的，才允许引聚合。
    {
        allowed=""
        case "$source" in *Standards*|*标准*) allowed="$allowed standards" ;; esac
        case "$source" in *Spec*) allowed="$allowed spec" ;; esac
        have=""
        for ax in $allowed; do
            [ -f "$ledger/reviews/round-$_pad-$ax.md" ] && have="$have $ax"
        done
        if [ -n "$have" ]; then
            ok=0
            for ax in $have; do
                [ "$revname" = "round-$_pad-$ax.md" ] && ok=1
            done
            [ "$ok" -eq 1 ] || derivative=$((derivative + 1))
        fi
    }
done

# 每条守卫都配一个「清单非空」的证人：空集上的「全都满足」恒真，那正是本文件
# 开头列的「少跑了却宣布通过」。
[ "$checked" -gt 0 ] \
    && pass "查了 $checked 条 issue（清单非空，下面四条不是空集上的恒真）" \
    || fail "一条 issue 都没查到——账本路径对不上了"
[ "$unsupported" -eq 0 ] \
    && pass "每条意见原文都在它 Review: 指名的那份报告里逐字存在" \
    || fail "$unsupported 条引文在所指报告里找不到（引文必须逐字，不能转述或删节）"
[ "$derivative" -eq 0 ] \
    && pass "每条引文都出自 agent 原文，而不是我自己的聚合（丢失那几侧除外）" \
    || fail "$derivative 条引的是我自己的聚合，而那一轮那一轴的 agent 原文就在库里"
[ "$rotten" -eq 0 ] \
    && pass "每个 Fixed by: 要么是可达的提交，要么是两种成文的字面值" \
    || fail "$rotten 条 Fixed by: 不可达或取值未成文"
[ "$noconcl" -eq 0 ] \
    && pass "每条 issue 都有 ## 结论" \
    || fail "$noconcl 条 issue 缺 ## 结论（issue-tracker.md 要求两节都在）"
[ "$miscast" -eq 0 ] \
    && pass "审查提的用 ## 意见原文，我自己发现的用 ## 缺陷，两者不混" \
    || fail "$miscast 条用错了章节（不是审查提的就没有「原文」可引）"

rounds=$(ls "$ledger"/issues/*.md 2>/dev/null \
    | sed -n 's|.*/\([0-9][0-9]\)-[0-9][0-9]-.*|\1|p' | sort -u)
nrounds=$(printf '%s\n' $rounds | grep -c '[0-9]')
missing_agg=0
for r in $rounds; do
    [ -f "$ledger/reviews/round-$r-aggregate.md" ] || missing_agg=$((missing_agg + 1))
done
[ "$nrounds" -gt 0 ] && [ "$missing_agg" -eq 0 ] \
    && pass "$nrounds 个轮次各有聚合报告（轮号非空）" \
    || fail "取到 $nrounds 个轮号、其中 $missing_agg 轮缺聚合报告"

echo
# 数的是「执行了多少条」= PASSED + FAILED，不是「通过了多少条」。
# 原先比 PASSED：真失败时 PASSED 必然偏小，于是额外报一句「有断言没有执行」
# ——那是误诊，断言执行了，只是失败了（实测把 2 条真失败放大成 3 条）。
# 这一条不走 expect_count：它要是也发一个 pass，就会把自己要比的那个数顶高
# 一位（实测比的是 60、打印的是 61）。所以只在不符时出声，并且下面的结论
# 打印的就是它比过的那个数。代价是它自己没人罩着——它是最外层那一条，
# 没有更外层可以罩它了，这一点如实记下来。
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

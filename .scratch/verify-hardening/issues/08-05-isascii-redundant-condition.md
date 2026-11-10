# isASCII 冗余条件 + 四行自白

Status: resolved
Round: 8
Source: Standards 4（第 8 轮报告，2026-11-10T04:28Z）
Fixed by: b5244c1
Review: ../reviews/round-08-aggregate.md

## 意见原文

> 删 `isASCII` 冗余条件与四行自白，保留行为用例

## 结论

返工过一次。b5244c1 只把那段自白从生产代码搬进了测试文件，等于决定没做（第 9 轮 Spec 轴指出「The apology was relocated, not resolved」）。eac5f46 才真正解决：numericFields 改调 isAllDigits，「ASCII 数字」全文件只定义一处，而且找到了它真正的证人 +999-09-15T18:42:07+08:00——Int("+999") 是 999，所以「有 Int 兜着所以冗余」这个判断从一开始就只对全角数字成立。

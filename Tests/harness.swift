// 测试脚手架：断言与计数。unit-test 和 guimodel-test 都链接它，
// 省得各写一份 pass/fail/check 和各自的失败计数器。

import Foundation

/// 累计失败数；各测试二进制在最后用 finish() 收尾。
var failedChecks = 0

func pass(_ what: String) { print("  ✓ \(what)") }

func fail(_ what: String) {
    print("  ✗ \(what)")
    failedChecks += 1
}

/// 断言两个同类型的值相等。失败消息带上两边的值，不必再回头加打印。
/// 比 `check(a == b, …)` 多这一条信息，所以能用这个就别用布尔版。
func check<T: Equatable>(_ what: String, _ got: T, _ want: T) {
    got == want ? pass(what) : fail("\(what)（期望 [\(want)]，实际 [\(got)]）")
}

/// 断言一个布尔条件。只在待断言的东西本身就是条件（而非两个值相等）时用。
func check(_ condition: Bool, _ what: String) {
    condition ? pass(what) : fail(what)
}

/// 断言某个判定函数在给定输入上的结果。输入会出现在失败消息里——判定规则
/// 的用例往往几十条一组，不带输入根本定位不到是哪条。
func checkRule<T: Equatable>(_ input: String, _ got: T, _ want: T, _ why: String) {
    got == want ? pass(why) : fail("\(why)：[\(input)] 期望 [\(want)]，实际 [\(got)]")
}

/// 统一收尾：打印结论并以恰当的状态码退出。
func finish(_ label: String) -> Never {
    print()
    print(failedChecks == 0 ? "\(label)全部通过" : "\(failedChecks) 项失败")
    exit(failedChecks > 0 ? 1 : 0)
}

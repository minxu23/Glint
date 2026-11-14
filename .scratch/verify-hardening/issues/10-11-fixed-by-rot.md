# Fixed by: 指向了一个悬空提交

Status: resolved
Round: 10
Source: 我自己（两轴都没提——这个缺陷是在修本轮意见的过程中造出来的）
Fixed by: a36c55b
Review: ../reviews/round-10-spec.md

## 缺陷

44 quotes appear literally in the cited review

## 结论

不是审查提的。10-08 加了「引文必须逐字」的守卫之后几分钟，我自己造了同一类
缺陷的另一个实例：先提交、把短 SHA 回填进 10 个 issue 文件、再 `--amend`，
而 amend 换掉了 SHA，于是那些 `Fixed by:` 指向一个只活在 reflog 里的悬空
提交，会被 gc 回收。

改法和 10-08 同构：给这条性质加守卫（selftest 第 10 轮，检查每个 SHA 从 HEAD
可达），而且**先加守卫再修数据**，让它在真实缺陷上变红（实测 10 条不可达）
而不是在捏出来的例子上。

教训不是「别用 amend」，是：一条记录只要引用了别处的东西（引文、SHA、路径），
它就会腐坏，而腐坏是无声的。靠记得维护它等于没维护。

// 界面模型里相机 RAW 的用例的入口（用例在 raw.swift）。暂时与 guimodel-test 分开跑，原因见
// Makefile 里 guiraw-test 那条规则。
//
// 用法: guiraw-test <工作目录>   目录里要有一张 Tests/fixture 造的 源.jpg（能无差异转换的 JPEG）

import Foundation

guard let work = CommandLine.arguments.dropFirst().first.map({ URL(fileURLWithPath: $0) }) else {
    FileHandle.standardError.write(Data("用法: guiraw-test <工作目录>\n".utf8))
    exit(2)
}
let source = work.appendingPathComponent("源.jpg")
runRAWTests(work: work, source: FileManager.default.fileExists(atPath: source.path) ? source : nil)
finish("界面模型（RAW）测试")

/// browsing.swift 里的 runBrowsingTests 用到它（定义在 guimodel 的 main.swift，这个工具不链那个文件）。
/// 这里只为让 browsing.swift 编得过，本工具不调 runBrowsingTests。
func files(in dir: URL, ext: String, deep: Bool = false) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == ext }.sorted { $0.path < $1.path }
}

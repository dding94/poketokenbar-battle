import Foundation
import JavaScriptCore
let ctx = JSContext()!
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
let src = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
var t = now(); let r = ctx.evaluateScript(src)!; print("micro", r.toString()!, now() - t, "ms")

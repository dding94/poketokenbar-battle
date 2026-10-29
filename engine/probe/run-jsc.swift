// Usage: swift run-jsc.swift engine.js corpus.json out.json [replay=1] [serializeAtTurn]
import Foundation
import JavaScriptCore

let args = CommandLine.arguments
let engineSrc = try! String(contentsOfFile: args[1], encoding: .utf8)
let corpusText = try! String(contentsOfFile: args[2], encoding: .utf8)
let outPath = args[3]
let doReplay = args.count > 4 && args[4] == "1"
let serAt = args.count > 5 ? Int(args[5]) ?? 0 : 0

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

let t0 = nowMs()
let vm = JSVirtualMachine()!
let ctx = JSContext(virtualMachine: vm)!
var jsError: String? = nil
ctx.exceptionHandler = { _, exc in
  let stack = exc?.objectForKeyedSubscript("stack")?.toString() ?? ""
  jsError = "\(exc?.toString() ?? "?")\n\(stack)"
}
let hostNow: @convention(block) () -> Double = { nowMs() }
ctx.setObject(hostNow, forKeyedSubscript: "__hostNow" as NSString)
ctx.setObject(corpusText, forKeyedSubscript: "__corpus" as NSString)

ctx.evaluateScript(engineSrc, withSourceURL: URL(fileURLWithPath: args[1]))
let t1 = nowMs()
if let e = jsError { print("EVAL ERROR: \(e)"); exit(1) }

let call = "JSON.stringify((function(){var r = PTBEngine.runCorpus(__corpus, {withLogs: true, now: __hostNow, replay: \(doReplay), serializeAtTurn: \(serAt)}); r.host = 'JavaScriptCore (JSContext, Swift)'; return r;})())"
let out = ctx.evaluateScript(call)
let t2 = nowMs()
if let e = jsError { print("RUN ERROR: \(e)"); exit(1) }
let json = out!.toString()!
try! json.write(toFile: outPath, atomically: true, encoding: .utf8)

ctx.setObject(json, forKeyedSubscript: "__out" as NSString)
let s2 = ctx.evaluateScript("""
(function(res){ var r = res.results;
  return JSON.stringify({timing: res.timing, errors: r.filter(function(x){return x.error}).length,
   replayFail: r.filter(function(x){return x.replayOk===false}).length,
   stateFail: r.filter(function(x){return x.stateOk===false}).length}); })(JSON.parse(__out))
""")
print("evalMs=\(t1 - t0) totalMs=\(t2 - t0)")
print(s2!.toString()!)

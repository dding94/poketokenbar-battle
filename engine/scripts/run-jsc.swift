import Foundation
import JavaScriptCore
let args = CommandLine.arguments
let context = JSContext()!
var failure: String?
context.exceptionHandler = { _, value in failure = value?.toString() ?? "JavaScript exception" }
context.evaluateScript(try String(contentsOfFile: args[1], encoding: .utf8))
if let failure { fatalError(failure) }
let corpus = try String(contentsOfFile: args[2], encoding: .utf8)
let start = Date()
guard let output = context.objectForKeyedSubscript("PTBCorpus")?.objectForKeyedSubscript("run")?.call(withArguments: [corpus])?.toString(), failure == nil else {
    fatalError(failure ?? "Missing corpus output")
}
try output.write(toFile: args[3], atomically: true, encoding: .utf8)
let results = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [[String: Any]]
print("JavaScriptCore: \(results.count) replay + state checks in \(Date().timeIntervalSince(start))s")

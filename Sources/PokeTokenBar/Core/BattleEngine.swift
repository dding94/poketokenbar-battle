import CryptoKit
import Foundation
import JavaScriptCore

/// One synchronous engine per owner. Never evaluates interpolated input as source.
@MainActor
final class BattleEngine {
    enum Failure: Error, Equatable { case missingBundle, checksumMismatch, invalidBundle, engine(String) }
    enum Method: String { case version, createBattle, request, choose, autoChoice, state, drainLog, result, replay, destroy }
    private let context: JSContext
    private let api: JSValue

    init(url: URL? = Bundle.main.url(forResource: "battle-engine", withExtension: "js"),
         expectedHash: String = BattleEngineManifest.sha256) throws {
        guard let url, let data = try? Data(contentsOf: url) else { throw Failure.missingBundle }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedHash else { throw Failure.checksumMismatch }
        guard let source = String(data: data, encoding: .utf8), let context = JSContext() else {
            throw Failure.invalidBundle
        }
        context.evaluateScript(source, withSourceURL: url)
        guard context.exception == nil,
              let api = context.objectForKeyedSubscript("PTBEngine"), !api.isUndefined else {
            throw Failure.invalidBundle
        }
        self.context = context
        self.api = api
    }

    func call(_ method: Method, arguments: [String] = []) throws -> String {
        context.exception = nil
        guard let function = api.objectForKeyedSubscript(method.rawValue), !function.isUndefined,
              let text = function.call(withArguments: arguments)?.toString(), context.exception == nil,
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            throw Failure.invalidBundle
        }
        if let envelope = value as? [String: Any], envelope["ok"] as? Bool == false {
            throw Failure.engine(envelope["error"] as? String ?? "engine_failure")
        }
        return text
    }
}

import SwiftUI
import XCTest
@testable import PokeTokenBar

actor OnlineBattleSyntheticNameProvider: PokemonNameProviding {
    func names(for resource: PokemonNameResource) async throws -> [String: String] {
        switch (resource.kind, resource.name) {
        case (.pokemonSpecies, "25"): return ["ko": "피카츄", "en": "Pikachu"]
        case (.pokemonSpecies, "129"): return ["ko": "잉어킹", "en": "Magikarp"]
        case (.pokemonSpecies, "492"): return ["ko": "쉐이미", "en": "Shaymin"]
        case (.pokemonForm, "10064"): return ["ko": "스카이폼", "en": "Sky Forme"]
        default: throw URLError(.notConnectedToInternet)
        }
    }
}

private actor OnlineBattleSpeciesNameServer {
    var paths: [String] = []
    func fetch(_ url: URL) throws -> Data {
        paths.append(url.path)
        let name = url.path.contains("pokemon-species") ? "Pikachu" : "Original form"
        let key = url.path.contains("pokemon-species") ? "names" : "form_names"
        var payload: [String: Any] = ["names": []]
        payload[key] = [["name": name, "language": ["name": "en"]]]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

@MainActor
final class OnlineBattleReviewFixTests: XCTestCase {
    func testGroupBackForwardsWhileBusyAndPreservesRunningBattle() {
        let model = OnlineBattleScreenRenderingTests.model()
        OnlineBattleScreenRenderingTests.arena(model)
        model.phase = .verifying; model.isBusy = true
        let deadline = model.deadline
        var actions = 0
        model.onAction = { action in
            if case .backToLobby = action { actions += 1 } else { XCTFail("Back must not cancel, pause or hide the popover") }
        }
        model.send(.backToLobby)
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(model.room?.state, .running)
        XCTAssertEqual(model.deadline, deadline)
        XCTAssertNotNil(model.arena)
    }

    func testRoomArenaAndVerificationUseGroupRouteWithoutHomeClose() {
        for phase in [OnlineBattlePresentation.Phase.room, .arena, .verifying] {
            let model = OnlineBattleScreenRenderingTests.model()
            OnlineBattleScreenRenderingTests.arena(model)
            model.phase = phase; model.isBusy = true
            var closed = false
            var routeActions = 0
            model.onAction = { action in
                if case .backToLobby = action {
                    routeActions += 1
                    // The session owns this routing decision; the UI only requests it.
                    model.phase = .lobby
                } else { XCTFail("Unexpected action") }
            }
            let screen = OnlineBattleScreen(model: model, l: L(.ko), artwork: false, onClose: { closed = true })
            XCTAssertTrue(screen.showsGroupBack)
            screen.returnToGroup()
            XCTAssertEqual(routeActions, 1)
            XCTAssertEqual(model.phase, .lobby)
            XCTAssertFalse(screen.showsGroupBack)
            XCTAssertFalse(closed)
            XCTAssertEqual(model.room?.state, .running)
        }
    }

    func testEnglishEngineNameResolvesCachedKoreanAndKeepsPublicForm() async {
        let provider = OnlineBattleSyntheticNameProvider()
        let names = PokemonNameDisplayStore()
        _ = await names.load(.init(kind: .pokemonSpecies, name: "25"), provider: provider)
        _ = await names.load(.init(kind: .pokemonSpecies, name: "492"), provider: provider)
        _ = await names.load(.init(kind: .pokemonForm, name: "10064"), provider: provider)
        let pikachu = OnlineBattleSpeciesNameLevel(speciesNum: 25, publicName: "Pikachu", level: 50, language: .ko,
                                                   provider: provider, displayStore: names, loadsNames: false)
        XCTAssertEqual(pikachu.displayName, "피카츄")
        let sky = OnlineBattleSpeciesNameLevel(speciesNum: 492, publicName: "Shaymin-Sky", level: 50, language: .ko,
                                               provider: provider, displayStore: names, loadsNames: false)
        XCTAssertEqual(sky.displayName, "쉐이미 [스카이폼]")
        let offline = OnlineBattleSpeciesNameLevel(speciesNum: 129, publicName: "Magikarp", level: 50, language: .ko,
                                                   provider: provider, displayStore: names, loadsNames: false)
        XCTAssertEqual(offline.displayName, "Magikarp", "Uncached offline names retain the public English name")
    }

    func testSpeciesClientRoutingAndCacheStaySeparateFromFormKind() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("online-species-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = OnlineBattleSpeciesNameServer()
        let client = PokemonNameClient(directory: directory, fetch: { try await server.fetch($0) })
        let species = PokemonNameResource(kind: .pokemonSpecies, name: "25")
        let form = PokemonNameResource(kind: .pokemonForm, name: "25")
        let first = try await client.names(for: species)
        let other = try await client.names(for: form)
        XCTAssertEqual(first["en"], "Pikachu")
        XCTAssertEqual(other["en"], "Original form")
        let restored = PokemonNameClient(directory: directory, fetch: { try await server.fetch($0) })
        let cached = try await restored.names(for: species)
        XCTAssertEqual(cached["en"], "Pikachu")
        let paths = await server.paths
        XCTAssertEqual(paths, ["/api/v2/pokemon-species/25", "/api/v2/pokemon-form/25"])
        XCTAssertNotEqual(species.cacheKey, form.cacheKey)
    }
}

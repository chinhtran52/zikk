import Testing
import Foundation
import SwiftUI
import SwiftData
import APICore
import APIStore
import DesignSystem
@testable import Features

@MainActor
@Suite struct CollectionSearchTests {
    static var containers: [ModelContainer] = []

    struct Tree {
        let bot: APICollection, other: APICollection
        let utters: CollectionNode, intents: CollectionNode, nlu: CollectionNode, train: CollectionNode, hoaDon: CollectionNode
    }

    /// Bot (collection)
    ///   NLU (folder)
    ///     Upload utters (request)
    ///     Train (request, url …/train)
    ///   Intents (request)
    /// Other (collection)
    ///   Hóa đơn (request)
    func makeTree() throws -> Tree {
        let container = try StoreFactory.makeContainer(inMemory: true)
        Self.containers.append(container)
        let context = container.mainContext
        let workspace = try StoreFactory.defaultWorkspace(in: context)
        func collection(_ name: String, _ index: Int) -> APICollection {
            let c = APICollection(name: name, sortIndex: index)
            c.workspace = workspace
            context.insert(c)
            return c
        }
        func node(_ kind: NodeKind, _ name: String, _ c: APICollection, _ parent: CollectionNode?, url: String = "", _ index: Int) -> CollectionNode {
            let n = CollectionNode(kind: kind, name: name, request: kind == .request ? RequestSpec(url: url) : nil, sortIndex: index)
            n.collection = c
            n.parent = parent
            context.insert(n)
            return n
        }
        let bot = collection("Bot", 0), other = collection("Other", 1)
        let nlu = node(.folder, "NLU", bot, nil, 0)
        let utters = node(.request, "Upload utters", bot, nlu, url: "{{base}}/utters", 0)
        let train = node(.request, "Train", bot, nlu, url: "{{base}}/model/train", 1)
        let intents = node(.request, "Intents", bot, nil, url: "{{base}}/intents", 1)
        let hoaDon = node(.request, "Hóa đơn", other, nil, url: "{{base}}/invoices", 0)
        try context.save()
        return Tree(bot: bot, other: other, utters: utters, intents: intents, nlu: nlu, train: train, hoaDon: hoaDon)
    }

    @Test func searchExpandsAncestorsOfMatches() throws {
        let t = try makeTree()
        let search = CollectionSearch(query: "utters", collections: [t.bot, t.other])
        #expect(search.visibleCollections == [t.bot.id])
        #expect(search.expanded == [t.bot.id, t.nlu.id])
        #expect(search.visibleNodes == [t.nlu.id, t.utters.id])
        #expect(!search.isVisible(t.train) && !search.isVisible(t.intents))
    }

    @Test func matchesURLAndIgnoresCaseAndDiacritics() throws {
        let t = try makeTree()
        #expect(CollectionSearch(query: "MODEL/TRAIN", collections: [t.bot, t.other]).visibleNodes == [t.nlu.id, t.train.id])
        let vietnamese = CollectionSearch(query: "hoa don", collections: [t.bot, t.other])
        #expect(vietnamese.visibleNodes == [t.hoaDon.id])
        #expect(vietnamese.expanded == [t.other.id])
    }

    @Test func matchingFolderOrCollectionShowsItsSubtree() throws {
        let t = try makeTree()
        let folder = CollectionSearch(query: "nlu", collections: [t.bot, t.other])
        #expect(folder.visibleNodes == [t.nlu.id, t.utters.id, t.train.id])
        #expect(!folder.expanded.contains(t.nlu.id), "a matching folder is shown, not forced open")
        let collection = CollectionSearch(query: "oth", collections: [t.bot, t.other])
        #expect(collection.visibleCollections == [t.other.id])
        #expect(collection.visibleNodes == [t.hoaDon.id])
    }

    @Test func emptyQueryShowsEverything() throws {
        let t = try makeTree()
        let search = CollectionSearch(query: "  ", collections: [t.bot, t.other])
        #expect(!search.isActive)
        #expect(search.isVisible(t.train) && search.isVisible(t.other))
    }

    @Test func expansionFollowsSearchButRespectsUser() throws {
        let t = try makeTree()
        var expansion = TreeExpansion()
        let none = CollectionSearch(query: "", collections: [t.bot])
        #expect(!expansion.isExpanded(t.bot.id, search: none))

        let search = CollectionSearch(query: "utters", collections: [t.bot])
        #expect(expansion.isExpanded(t.bot.id, search: search))
        #expect(expansion.isExpanded(t.nlu.id, search: search))
        // The user collapses an auto-expanded folder during the search…
        expansion.set(t.nlu.id, expanded: false, search: search)
        #expect(!expansion.isExpanded(t.nlu.id, search: search))
        // …a new query re-expands it; clearing the search restores the user's own state.
        expansion.searchChanged()
        #expect(expansion.isExpanded(t.nlu.id, search: search))
        #expect(!expansion.isExpanded(t.nlu.id, search: none))
        expansion.set(t.bot.id, expanded: true, search: none)
        #expect(expansion.isExpanded(t.bot.id, search: none))
    }

    @Test func highlightRanges() {
        let text = "Upload utters and UTTERS"
        let ranges = HighlightedText.ranges(of: "utters", in: text)
        #expect(ranges.map { String(text[$0]) } == ["utters", "UTTERS"])
        #expect(HighlightedText.ranges(of: "hoa", in: "Hóa đơn").map { String("Hóa đơn"[$0]) } == ["Hóa"])
        #expect(HighlightedText.ranges(of: "a d", in: "Hóa Đơn Đơn").map { String("Hóa Đơn Đơn"[$0]) } == ["a Đ"])
        #expect(HighlightedText.ranges(of: " ", in: "a b").isEmpty)
        let attributed = HighlightedText.attributed("Upload utters", highlighting: "utters")
        let emphasized = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(attributed[$0.range].characters) }
        #expect(emphasized == ["utters"])
    }
}

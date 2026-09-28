import Foundation
import APIStore
import DesignSystem

/// Result of filtering the collections tree by a search query.
///
/// Requests match on their name or URL, folders and collections on their name. Matching is case- and
/// diacritic-insensitive. Ancestors of every match stay visible and are expanded so the match can be seen;
/// a matching folder or collection also shows its whole subtree.
@MainActor
struct CollectionSearch {
    let query: String
    /// Collections that contain something matching (or match themselves).
    private(set) var visibleCollections: Set<UUID> = []
    /// Nodes to show.
    private(set) var visibleNodes: Set<UUID> = []
    /// Collections and folders that should be expanded to reveal matches.
    private(set) var expanded: Set<UUID> = []

    var isActive: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(query: String, collections: [APICollection]) {
        self.query = query
        guard isActive else { return }
        for collection in collections {
            let collectionMatches = Self.matches(collection.name, query)
            var containsMatch = false
            for node in collection.rootNodes where visit(node, forceVisible: collectionMatches) {
                containsMatch = true
            }
            if containsMatch { expanded.insert(collection.id) }
            if containsMatch || collectionMatches { visibleCollections.insert(collection.id) }
        }
    }

    /// Returns whether `node` or a descendant matches; records visibility and expansion along the way.
    private mutating func visit(_ node: CollectionNode, forceVisible: Bool) -> Bool {
        let selfMatches = Self.matches(node.name, query) || (!node.isFolder && Self.matches(node.request.url, query))
        var descendantMatches = false
        for child in node.sortedChildren ?? [] where visit(child, forceVisible: forceVisible || (node.isFolder && selfMatches)) {
            descendantMatches = true
        }
        if descendantMatches { expanded.insert(node.id) }
        if selfMatches || descendantMatches || forceVisible { visibleNodes.insert(node.id) }
        return selfMatches || descendantMatches
    }

    func isVisible(_ node: CollectionNode) -> Bool { !isActive || visibleNodes.contains(node.id) }
    func isVisible(_ collection: APICollection) -> Bool { !isActive || visibleCollections.contains(collection.id) }

    static func matches(_ text: String, _ query: String) -> Bool {
        HighlightedText.matches(text, query)
    }
}

/// Expansion state of the collections tree: the user's own choices, overridden while a search is active so
/// matches are revealed (the user can still collapse them during the search).
@MainActor
struct TreeExpansion {
    var manual: Set<UUID> = []
    /// Auto-expanded items the user collapsed during the current search.
    var collapsedDuringSearch: Set<UUID> = []

    func isExpanded(_ id: UUID, search: CollectionSearch) -> Bool {
        if search.isActive, search.expanded.contains(id) { return !collapsedDuringSearch.contains(id) }
        return manual.contains(id)
    }

    mutating func set(_ id: UUID, expanded: Bool, search: CollectionSearch) {
        if search.isActive, search.expanded.contains(id) {
            if expanded { collapsedDuringSearch.remove(id) } else { collapsedDuringSearch.insert(id) }
        } else if expanded {
            manual.insert(id)
        } else {
            manual.remove(id)
        }
    }

    mutating func searchChanged() { collapsedDuringSearch.removeAll() }
}

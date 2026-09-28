import Foundation
import SwiftData

public enum SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [Workspace.self, APICollection.self, CollectionNode.self, SavedExample.self, APIEnvironment.self,
         APISpec.self, Dataset.self, MockDefinition.self, HistoryEntry.self, CookieRecord.self]
    }
}

public enum APIStoreMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public enum StoreFactory {
    /// Creates the app's model container. Pass `inMemory: true` for tests and previews.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration("Workspace", schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, migrationPlan: APIStoreMigrationPlan.self, configurations: [configuration])
    }

    /// Returns the first live workspace, creating a default one on first launch.
    @MainActor
    public static func defaultWorkspace(in context: ModelContext) throws -> Workspace {
        var descriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let workspace = Workspace(name: "My Workspace")
        context.insert(workspace)
        try context.save()
        return workspace
    }
}

import CoreData

// Managed object classes. The model itself is built in code below.

@objc(FavoriteMO)
final class FavoriteMO: NSManagedObject {
    @NSManaged var key: String
    @NSManaged var siteID: String
    @NSManaged var postData: Data
    @NSManaged var createdAt: Date
    @NSManaged var collections: Set<CollectionMO>
}

@objc(CollectionMO)
final class CollectionMO: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var name: String
    @NSManaged var createdAt: Date
    @NSManaged var favorites: Set<FavoriteMO>
}

@objc(HistoryMO)
final class HistoryMO: NSManagedObject {
    @NSManaged var query: String
    @NSManaged var siteID: String
    @NSManaged var date: Date
}

@objc(SavedSearchMO)
final class SavedSearchMO: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var name: String
    @NSManaged var query: String
    @NSManaged var siteID: String
    @NSManaged var createdAt: Date
}

@objc(DownloadMO)
final class DownloadMO: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var postKey: String
    @NSManaged var siteID: String
    @NSManaged var postData: Data
    @NSManaged var remoteURL: String
    @NSManaged var state: String
    @NSManaged var progress: Double
    @NSManaged var bytesTotal: Int64
    @NSManaged var relativePath: String?
    @NSManaged var errorMessage: String?
    @NSManaged var resumeData: Data?
    @NSManaged var createdAt: Date
    @NSManaged var tagsText: String
    @NSManaged var mediaType: String
}

final class CoreDataStack {
    static let shared = CoreDataStack()

    let container: NSPersistentContainer
    var context: NSManagedObjectContext { container.viewContext }
    private(set) var loadError: Error?

    private init() {
        container = NSPersistentContainer(name: "MediaDeck", managedObjectModel: Self.makeModel())
        let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaDeck.sqlite")
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let desc = NSPersistentStoreDescription(url: storeURL)
        desc.shouldMigrateStoreAutomatically = true
        desc.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [desc]
        final class ErrorBox { var error: Error? }
        let box = ErrorBox()
        container.loadPersistentStores { _, e in box.error = e }
        if let e = box.error {
            // Unreadable store: start fresh rather than crash, and report it.
            NSLog("[CoreData] load failed: %@ — recreating store", "\(e)")
            try? container.persistentStoreCoordinator.destroyPersistentStore(at: storeURL, ofType: NSSQLiteStoreType)
            container.loadPersistentStores { _, _ in }
            loadError = e
        }
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = true
    }

    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            ToastCenter.shared.error(error, prefix: "Couldn't save")
            context.rollback()
        }
    }

    // MARK: - Model built in code

    private static func attr(_ name: String, _ type: NSAttributeType, optional: Bool = false, defaultValue: Any? = nil) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = optional
        if let d = defaultValue { a.defaultValue = d }
        return a
    }

    private static func entity(_ name: String, _ cls: AnyClass, _ attrs: [NSAttributeDescription]) -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = name
        e.managedObjectClassName = NSStringFromClass(cls)
        e.properties = attrs
        return e
    }

    static func makeModel() -> NSManagedObjectModel {
        let favorite = entity("Favorite", FavoriteMO.self, [
            attr("key", .stringAttributeType), attr("siteID", .stringAttributeType),
            attr("postData", .binaryDataAttributeType), attr("createdAt", .dateAttributeType),
        ])
        let collection = entity("Collection", CollectionMO.self, [
            attr("id", .stringAttributeType), attr("name", .stringAttributeType), attr("createdAt", .dateAttributeType),
        ])
        let history = entity("History", HistoryMO.self, [
            attr("query", .stringAttributeType), attr("siteID", .stringAttributeType), attr("date", .dateAttributeType),
        ])
        let saved = entity("SavedSearch", SavedSearchMO.self, [
            attr("id", .stringAttributeType), attr("name", .stringAttributeType), attr("query", .stringAttributeType),
            attr("siteID", .stringAttributeType), attr("createdAt", .dateAttributeType),
        ])
        let download = entity("Download", DownloadMO.self, [
            attr("id", .stringAttributeType), attr("postKey", .stringAttributeType), attr("siteID", .stringAttributeType),
            attr("postData", .binaryDataAttributeType), attr("remoteURL", .stringAttributeType),
            attr("state", .stringAttributeType), attr("progress", .doubleAttributeType, defaultValue: 0.0),
            attr("bytesTotal", .integer64AttributeType, defaultValue: 0),
            attr("relativePath", .stringAttributeType, optional: true), attr("errorMessage", .stringAttributeType, optional: true),
            attr("resumeData", .binaryDataAttributeType, optional: true), attr("createdAt", .dateAttributeType),
            attr("tagsText", .stringAttributeType, defaultValue: ""), attr("mediaType", .stringAttributeType, defaultValue: "image"),
        ])

        // Favorite <<->> Collection
        let favToCol = NSRelationshipDescription()
        let colToFav = NSRelationshipDescription()
        favToCol.name = "collections"; favToCol.destinationEntity = collection
        favToCol.minCount = 0; favToCol.maxCount = 0; favToCol.isOptional = true
        favToCol.deleteRule = .nullifyDeleteRule; favToCol.inverseRelationship = colToFav
        colToFav.name = "favorites"; colToFav.destinationEntity = favorite
        colToFav.minCount = 0; colToFav.maxCount = 0; colToFav.isOptional = true
        colToFav.deleteRule = .nullifyDeleteRule; colToFav.inverseRelationship = favToCol
        favorite.properties.append(favToCol)
        collection.properties.append(colToFav)

        let model = NSManagedObjectModel()
        model.entities = [favorite, collection, history, saved, download]
        return model
    }
}

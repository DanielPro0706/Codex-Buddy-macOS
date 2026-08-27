import CloudKit
import Foundation

nonisolated enum CodexCloudSync {
    private static let containerIdentifier = "iCloud.com.danieldev.CodexBuddyNew"
    private static let recordType = "CodexBuddyState"
    private static let recordName = "current-state"
    private static let snapshotField = "snapshot"
    private static let secretField = "pushSecret"
    private static let updatedAtField = "updatedAt"

    struct CloudState: Sendable {
        let snapshot: CodexStatusSnapshot?
        let pushSecret: String?
    }

    static func fetch() async throws -> CloudState {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let recordID = CKRecord.ID(recordName: recordName)
        let results = try await database.records(
            for: [recordID],
            desiredKeys: [snapshotField, secretField, updatedAtField]
        )
        guard let result = results[recordID] else { return CloudState(snapshot: nil, pushSecret: nil) }

        do {
            let record = try result.get()
            let snapshot = (record[snapshotField] as? Data)
                .flatMap { try? CodexStatusCache.decoder.decode(CodexStatusSnapshot.self, from: $0) }
            return CloudState(snapshot: snapshot, pushSecret: record[secretField] as? String)
        } catch let error as CKError where error.code == .unknownItem {
            return CloudState(snapshot: nil, pushSecret: nil)
        }
    }

    @discardableResult
    static func publish(snapshot: CodexStatusSnapshot, pushSecret: String) async throws -> CodexStatusSnapshot {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let recordID = CKRecord.ID(recordName: recordName)
        let existing = try? await fetchRecord(database: database, recordID: recordID)

        if let existingSnapshot = existing.flatMap(snapshot(from:)),
           existingSnapshot.capturedAt > snapshot.capturedAt {
            return existingSnapshot
        }

        let record = existing ?? CKRecord(recordType: recordType, recordID: recordID)
        record[snapshotField] = try CodexStatusCache.encoder.encode(snapshot) as CKRecordValue
        record[secretField] = pushSecret as CKRecordValue
        record[updatedAtField] = Date.now as CKRecordValue

        let result = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .changedKeys,
            atomically: true
        )
        guard let saveResult = result.saveResults[recordID] else { return snapshot }
        _ = try saveResult.get()
        return snapshot
    }

    static func newest(local: CodexStatusSnapshot?) async -> CodexStatusSnapshot? {
        guard let cloud = try? await fetch().snapshot else { return local }
        guard let local else { return cloud }
        return cloud.capturedAt > local.capturedAt ? cloud : local
    }

    private static func fetchRecord(database: CKDatabase, recordID: CKRecord.ID) async throws -> CKRecord {
        let results = try await database.records(for: [recordID])
        guard let result = results[recordID] else { throw CKError(.unknownItem) }
        return try result.get()
    }

    private static func snapshot(from record: CKRecord) -> CodexStatusSnapshot? {
        guard let data = record[snapshotField] as? Data else { return nil }
        return try? CodexStatusCache.decoder.decode(CodexStatusSnapshot.self, from: data)
    }
}

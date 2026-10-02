import CloudKit
import Foundation
import OSLog

nonisolated enum CodexCloudSync {
    private static let containerIdentifier = "iCloud.com.danieldev.CodexBuddyNew"
    private static let recordType = "CodexBuddyState"
    private static let recordName = "current-state"
    private static let snapshotField = "snapshot"
    private static let secretField = "pushSecret"
    private static let updatedAtField = "updatedAt"
    private static let logger = Logger(subsystem: "com.danieldev.CodexBuddyNew", category: "CloudSync")

    enum AccountAvailability: Sendable, Equatable {
        case unknown
        case checking
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case couldNotDetermine
    }

    enum Failure: Sendable, Equatable {
        case network
        case permission
        case configuration
        case rateLimited
        case unavailable
        case unknown(String)
    }

    enum OperationStatus: Sendable, Equatable {
        case notChecked
        case checking
        case synced(Date)
        case connectedWithoutData
        case unavailable(AccountAvailability)
        case failed(Failure)

        var isSuccessful: Bool {
            switch self {
            case .synced, .connectedWithoutData: true
            default: false
            }
        }
    }

    static func accountAvailability() async -> AccountAvailability {
        do {
            return switch try await CKContainer(identifier: containerIdentifier).accountStatus() {
            case .available: .available
            case .noAccount: .noAccount
            case .restricted: .restricted
            case .temporarilyUnavailable: .temporarilyUnavailable
            case .couldNotDetermine: .couldNotDetermine
            @unknown default: .couldNotDetermine
            }
        } catch {
            log(error, operation: "account-status")
            return .couldNotDetermine
        }
    }

    static func operationStatus(for error: Error) -> OperationStatus {
        log(error, operation: "database")

        if let cloudError = error as? CloudSyncError {
            return .unavailable(cloudError.availability)
        }

        guard let cloudError = error as? CKError else {
            return .failed(.unknown(error.localizedDescription))
        }

        return switch cloudError.code {
        case .notAuthenticated:
            .unavailable(.noAccount)
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy:
            .failed(.network)
        case .permissionFailure:
            .failed(.permission)
        case .serverRejectedRequest, .invalidArguments, .badContainer:
            .failed(.configuration)
        case .requestRateLimited, .limitExceeded:
            .failed(.rateLimited)
        default:
            .failed(.unknown(cloudError.localizedDescription))
        }
    }

    @discardableResult
    static func publish(snapshot: CodexStatusSnapshot, pushSecret: String) async throws -> CodexStatusSnapshot {
        try await requireAvailableAccount()
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

    private static func fetchRecord(database: CKDatabase, recordID: CKRecord.ID) async throws -> CKRecord {
        let results = try await database.records(for: [recordID])
        guard let result = results[recordID] else { throw CKError(.unknownItem) }
        return try result.get()
    }

    private static func snapshot(from record: CKRecord) -> CodexStatusSnapshot? {
        guard let data = record[snapshotField] as? Data else { return nil }
        return try? CodexStatusCache.decoder.decode(CodexStatusSnapshot.self, from: data)
    }

    private static func requireAvailableAccount() async throws {
        let availability = await accountAvailability()
        guard availability == .available else {
            throw CloudSyncError(availability: availability)
        }
    }

    private static func log(_ error: Error, operation: String) {
        if let cloudError = error as? CKError {
            logger.error("CloudKit \(operation, privacy: .public) failed: code=\(cloudError.code.rawValue, privacy: .public) message=\(cloudError.localizedDescription, privacy: .public)")
        } else {
            logger.error("CloudKit \(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct CloudSyncError: LocalizedError {
        let availability: AccountAvailability

        var errorDescription: String? { "iCloud account is unavailable" }
    }
}

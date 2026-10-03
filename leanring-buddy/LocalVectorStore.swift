//
//  LocalVectorStore.swift
//  leanring-buddy
//
//  In-process, pure Swift local vector store backed by SQLite (libsqlite3)
//  and Apple's Accelerate framework (vDSP) for vectorized cosine similarity.
//  Stores and retrieves:
//    1. Past successful task trajectories (indexed by task goal + app)
//    2. Per-app cached UI maps
//

import Accelerate
import Foundation
import SQLite3

/// A stored past successful automation trajectory.
struct StoredTrajectoryRecord {
    let id: String
    let taskGoal: String
    let appName: String
    let trajectorySummary: String
    let embedding: [Float]
    let createdAt: Date
}

/// A stored per-app UI structure map.
struct StoredUIMapRecord {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let elementsSummary: String
    let embedding: [Float]
    let updatedAt: Date
}

/// Thread-safe in-process local vector database.
actor LocalVectorStore {

    private var databasePointer: OpaquePointer?

    // MARK: - Initialization

    init(databaseFileName: String = "rag_vector_store.sqlite") {
        let fileManager = FileManager.default
        let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Clicky", isDirectory: true)

        try? fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        let databaseFileURL = applicationSupportDirectory.appendingPathComponent(databaseFileName)

        var db: OpaquePointer?
        if sqlite3_open(databaseFileURL.path, &db) == SQLITE_OK {
            self.databasePointer = db
            print("🗄️ LocalVectorStore: Opened SQLite database at \(databaseFileURL.path)")
        } else {
            print("⚠️ LocalVectorStore: Failed to open SQLite database at \(databaseFileURL.path)")
            self.databasePointer = nil
        }

        if let openDB = db {
            Self.initializeDatabaseTables(on: openDB)
        }
    }

    deinit {
        if let db = databasePointer {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema Initialization

    private static func initializeDatabaseTables(on db: OpaquePointer) {
        let createTrajectoriesTableSQL = """
        CREATE TABLE IF NOT EXISTS trajectories (
            id TEXT PRIMARY KEY,
            task_goal TEXT NOT NULL,
            app_name TEXT NOT NULL,
            trajectory_summary TEXT NOT NULL,
            embedding BLOB NOT NULL,
            created_at REAL NOT NULL
        );
        """

        let createUIMapsTableSQL = """
        CREATE TABLE IF NOT EXISTS ui_maps (
            id TEXT PRIMARY KEY,
            app_name TEXT NOT NULL,
            bundle_identifier TEXT NOT NULL,
            elements_summary TEXT NOT NULL,
            embedding BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        """

        let createUserFactsTableSQL = """
        CREATE TABLE IF NOT EXISTS user_facts (
            id TEXT PRIMARY KEY,
            fact TEXT NOT NULL,
            embedding BLOB NOT NULL,
            created_at REAL NOT NULL
        );
        """

        executeSQLStatement(createTrajectoriesTableSQL, on: db)
        executeSQLStatement(createUIMapsTableSQL, on: db)
        executeSQLStatement(createUserFactsTableSQL, on: db)
    }

    private static func executeSQLStatement(_ sql: String, on db: OpaquePointer) {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorPointer) != SQLITE_OK {
            if let errorMsg = errorPointer {
                print("⚠️ LocalVectorStore: SQL error: \(String(cString: errorMsg))")
                sqlite3_free(errorMsg)
            }
        }
    }

    // MARK: - Saving Records

    /// Saves a successful task trajectory with its embedding vector.
    func saveSuccessfulTrajectory(
        taskGoal: String,
        appName: String,
        trajectorySummary: String,
        embedding: [Float]
    ) {
        guard let db = databasePointer else { return }

        let sql = """
        INSERT OR REPLACE INTO trajectories (id, task_goal, app_name, trajectory_summary, embedding, created_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        let recordID = UUID().uuidString
        let rawEmbeddingData = Data(bytes: embedding, count: embedding.count * MemoryLayout<Float>.size)

        sqlite3_bind_text(statement, 1, (recordID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (taskGoal as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (appName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (trajectorySummary as NSString).utf8String, -1, nil)
        _ = rawEmbeddingData.withUnsafeBytes { rawBufferPointer in
            sqlite3_bind_blob(statement, 5, rawBufferPointer.baseAddress, Int32(rawEmbeddingData.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)

        if sqlite3_step(statement) == SQLITE_DONE {
            print("💾 LocalVectorStore: Saved trajectory for \"\(taskGoal)\" (app: \(appName))")
        }
    }

    /// Saves or updates a cached UI map for an application.
    func saveAppUIMap(
        appName: String,
        bundleIdentifier: String,
        elementsSummary: String,
        embedding: [Float]
    ) {
        guard let db = databasePointer else { return }

        let sql = """
        INSERT OR REPLACE INTO ui_maps (id, app_name, bundle_identifier, elements_summary, embedding, updated_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        let recordID = appName.lowercased()
        let rawEmbeddingData = Data(bytes: embedding, count: embedding.count * MemoryLayout<Float>.size)

        sqlite3_bind_text(statement, 1, (recordID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (appName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (bundleIdentifier as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (elementsSummary as NSString).utf8String, -1, nil)
        _ = rawEmbeddingData.withUnsafeBytes { rawBufferPointer in
            sqlite3_bind_blob(statement, 5, rawBufferPointer.baseAddress, Int32(rawEmbeddingData.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)

        if sqlite3_step(statement) == SQLITE_DONE {
            print("💾 LocalVectorStore: Saved UI map for \(appName)")
        }
    }

    // MARK: - Querying & Vector Similarity

    /// Finds relevant past trajectories matching the query embedding, optionally filtered by application name.
    func findRelevantPastTrajectories(
        queryEmbedding: [Float],
        appName: String? = nil,
        similarityThreshold: Float = 0.55,
        maximumResultsLimit: Int = 3
    ) -> [String] {
        guard let db = databasePointer else { return [] }

        var sql = "SELECT task_goal, app_name, trajectory_summary, embedding FROM trajectories"
        if let app = appName, !app.isEmpty {
            sql += " WHERE LOWER(app_name) = '\(app.lowercased())'"
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var scoredTrajectories: [(similarity: Float, hint: String)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let taskGoal = String(cString: sqlite3_column_text(statement, 0))
            let app = String(cString: sqlite3_column_text(statement, 1))
            let summary = String(cString: sqlite3_column_text(statement, 2))

            guard let blobPointer = sqlite3_column_blob(statement, 3) else { continue }
            let blobBytes = Int(sqlite3_column_bytes(statement, 3))
            let floatCount = blobBytes / MemoryLayout<Float>.size

            let floatPointer = blobPointer.bindMemory(to: Float.self, capacity: floatCount)
            let storedVector = Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))

            let score = calculateCosineSimilarity(vectorA: queryEmbedding, vectorB: storedVector)
            if score >= similarityThreshold {
                let hint = "Past trajectory for \(app) (\"\(taskGoal)\", similarity: \(String(format: "%.2f", score))):\n\(summary)"
                scoredTrajectories.append((similarity: score, hint: hint))
            }
        }

        scoredTrajectories.sort { $0.similarity > $1.similarity }
        return scoredTrajectories.prefix(maximumResultsLimit).map { $0.hint }
    }

    /// Finds cached UI structure map for an application.
    func findAppUIMap(
        appName: String
    ) -> String? {
        guard let db = databasePointer else { return nil }

        let sql = "SELECT elements_summary FROM ui_maps WHERE LOWER(app_name) = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (appName.lowercased() as NSString).utf8String, -1, nil)

        if sqlite3_step(statement) == SQLITE_ROW {
            let summary = String(cString: sqlite3_column_text(statement, 0))
            return "Cached UI map for \(appName):\n\(summary)"
        }

        return nil
    }

    /// Saves a persistent user preference or fact with its embedding vector.
    func saveUserFact(
        fact: String,
        embedding: [Float]
    ) {
        guard let db = databasePointer else { return }

        let sql = """
        INSERT OR REPLACE INTO user_facts (id, fact, embedding, created_at)
        VALUES (?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        let recordID = UUID().uuidString
        let rawEmbeddingData = Data(bytes: embedding, count: embedding.count * MemoryLayout<Float>.size)

        sqlite3_bind_text(statement, 1, (recordID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (fact as NSString).utf8String, -1, nil)
        _ = rawEmbeddingData.withUnsafeBytes { rawBufferPointer in
            sqlite3_bind_blob(statement, 3, rawBufferPointer.baseAddress, Int32(rawEmbeddingData.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)

        if sqlite3_step(statement) == SQLITE_DONE {
            print("💾 LocalVectorStore: Saved user fact: \"\(fact)\"")
        }
    }

    /// Finds relevant user facts matching query embedding.
    func findRelevantUserFacts(
        queryEmbedding: [Float],
        similarityThreshold: Float = 0.60,
        maximumResultsLimit: Int = 2
    ) -> [String] {
        guard let db = databasePointer else { return [] }

        let sql = "SELECT fact, embedding FROM user_facts;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var scoredFacts: [(similarity: Float, fact: String)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let factText = String(cString: sqlite3_column_text(statement, 0))

            guard let blobPointer = sqlite3_column_blob(statement, 1) else { continue }
            let blobBytes = Int(sqlite3_column_bytes(statement, 1))
            let floatCount = blobBytes / MemoryLayout<Float>.size

            let floatPointer = blobPointer.bindMemory(to: Float.self, capacity: floatCount)
            let storedVector = Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))

            let score = calculateCosineSimilarity(vectorA: queryEmbedding, vectorB: storedVector)
            if score >= similarityThreshold {
                scoredFacts.append((similarity: score, fact: factText))
            }
        }

        scoredFacts.sort { $0.similarity > $1.similarity }
        return scoredFacts.prefix(maximumResultsLimit).map { $0.fact }
    }

    // MARK: - Apple Accelerate Cosine Similarity

    /// Computes cosine similarity between two float vectors using Accelerate vDSP.
    private func calculateCosineSimilarity(vectorA: [Float], vectorB: [Float]) -> Float {
        guard vectorA.count == vectorB.count, !vectorA.isEmpty else { return 0.0 }

        let count = vDSP_Length(vectorA.count)
        var dotProduct: Float = 0.0
        vDSP_dotpr(vectorA, 1, vectorB, 1, &dotProduct, count)

        var sumSquareA: Float = 0.0
        vDSP_svesq(vectorA, 1, &sumSquareA, count)

        var sumSquareB: Float = 0.0
        vDSP_svesq(vectorB, 1, &sumSquareB, count)

        let magnitude = sqrt(sumSquareA) * sqrt(sumSquareB)
        guard magnitude > 0.0 else { return 0.0 }

        return dotProduct / magnitude
    }
}

// SQLITE_TRANSIENT helper for binding Swift Data to SQLite BLOB
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

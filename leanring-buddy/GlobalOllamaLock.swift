//
//  GlobalOllamaLock.swift
//  leanring-buddy
//
//  A strict, non-reentrant asynchronous mutex for all local AI calls.
//  Because Swift actors are re-entrant (they suspend at `await` and allow other tasks to run),
//  we use checked continuations to build a true queue.
//  This prevents 12GB RAM spikes by ensuring Mem0 batches, Vision, and Reasoning models
//  NEVER run simultaneously and crash the system.
//

import Foundation

actor GlobalOllamaLock {
    static let shared = GlobalOllamaLock()
    
    private var isLocked = false
    private var waitQueue: [CheckedContinuation<Void, Never>] = []
    
    private init() {}
    
    /// Acquires the lock. If the lock is already held, the caller is suspended until it is released.
    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        
        await withCheckedContinuation { continuation in
            waitQueue.append(continuation)
        }
    }
    
    /// Releases the lock, resuming the next suspended caller if any.
    private func release() {
        if !waitQueue.isEmpty {
            let next = waitQueue.removeFirst()
            next.resume()
        } else {
            isLocked = false
        }
    }
    
    /// Executes the given async closure while holding the lock.
    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        
        defer {
            Task {
                await self.release()
            }
        }
        
        return try await operation()
    }
}

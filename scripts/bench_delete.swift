// Bench: the app's old per-file detached loop vs plain recursive removeItem
// vs BatchDeleter's tiered parallel delete, on identical synthetic trees.
// Run: swift scripts/bench_delete.swift
//
// NOTE: this snapshots BatchDeleter's algorithm for measurement only —
// the real implementation lives in Sources/Moppet/Core/BatchDeleter.swift.

import Foundation

let fm = FileManager.default
let workerCount = 6
let chunkSize = 256
let dirCount = 200      // 200 subdirs × 100 files = 20,000 small files
let filesPerDir = 100

func makeTree(_ root: URL) throws {
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for d in 0..<dirCount {
        let dir = root.appendingPathComponent("d\(d)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in 0..<filesPerDir {
            try Data("x".utf8).write(to: dir.appendingPathComponent("f\(f)"))
        }
    }
}

func measure(_ label: String, _ body: () async throws -> Void) async rethrows -> Double {
    let start = Date()
    try await body()
    let elapsed = Date().timeIntervalSince(start)
    print(String(format: "%@: %.2fs", label, elapsed))
    return elapsed
}

let base = fm.temporaryDirectory.appendingPathComponent("moppet-bench-\(UUID().uuidString)")
let treeA = base.appendingPathComponent("A")
let treeB = base.appendingPathComponent("B")
let treeC = base.appendingPathComponent("C")
defer { try? fm.removeItem(at: base) }

print("Creating three \(dirCount * filesPerDir)-file trees…")
try makeTree(treeA)
try makeTree(treeB)
try makeTree(treeC)

// 0. The app's OLD loop: per-file Task.detached hop + await. (The real old
//    code also repainted SwiftUI per file — not even included here.)
let t0 = await measure("old loop (per-file detached hop)") {
    var urls = (try? fm.enumerator(at: treeC, includingPropertiesForKeys: nil)?
        .allObjects.compactMap { $0 as? URL }) ?? []
    urls.sort { $0.pathComponents.count > $1.pathComponents.count }
    for url in urls {
        _ = try? await Task.detached { try fm.removeItem(at: url) }.value
    }
}

// 1. One recursive removeItem (single-threaded unlink walk).
let t1 = try await measure("plain removeItem") {
    try fm.removeItem(at: treeA)
}

// 2. New way: expand once, parallel leaf unlinks in bounded chunks,
//    then deepest-first rmdirs.
let t2 = await measure("tiered parallel (BatchDeleter algorithm)") {
    // expand
    var files: [URL] = []
    var dirs: [URL] = []
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    func classify(_ url: URL) {
        let values = try? url.resourceValues(forKeys: keys)
        if (values?.isSymbolicLink ?? false) || !(values?.isDirectory ?? false) {
            files.append(url)
            return
        }
        dirs.append(url)
        if let children = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: []) {
            for child in children { classify(child) }
        }
    }
    classify(treeB)

    // parallel leaf unlink, bounded workers
    let chunks = stride(from: 0, to: files.count, by: chunkSize).map {
        Array(files[$0..<Swift.min($0 + chunkSize, files.count)])
    }
    await withTaskGroup(of: Void.self) { group in
        var iterator = chunks.makeIterator()
        var inFlight = 0
        while let chunk = iterator.next() {
            group.addTask {
                for url in chunk { try? fm.removeItem(at: url) }
            }
            inFlight += 1
            if inFlight == workerCount {
                _ = await group.next()
            }
        }
        for await _ in group {}
    }

    // deepest-first rmdir
    for dir in dirs.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
        try? fm.removeItem(at: dir)
    }
}

print(String(format: "old loop vs new: %.1fx  (plain removeItem vs new: %.1fx)",
             t0 / t2, t1 / t2))
print("A exists:", fm.fileExists(atPath: treeA.path),
      " B exists:", fm.fileExists(atPath: treeB.path),
      " C exists:", fm.fileExists(atPath: treeC.path))

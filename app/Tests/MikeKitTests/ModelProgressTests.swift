import FluidAudio
import Testing
@testable import MikeKit

@Test func modelProgressNeverGoesBackwards() {
    var m = ModelProgress()
    let feed: [(Double, DownloadPhase)] = [
        (0, .listing), (0.2, .downloading(completedFiles: 1, totalFiles: 9)), (0.5, .downloading(completedFiles: 9, totalFiles: 9)),
        (0.5, .compiling(modelName: "a")), (1, .compiling(modelName: "")),
        (0.5, .downloading(completedFiles: 0, totalFiles: 0)), (0.5, .compiling(modelName: "b")),  // the next model, cached
        (0.1, .downloading(completedFiles: 1, totalFiles: 2)),  // a later fetch restarting from 0
    ]
    var seen: [ModelProgress] = []
    for (f, phase) in feed { m.add(DownloadProgress(fractionCompleted: f, phase: phase)); seen.append(m) }
    #expect(seen[1] == ModelProgress(fraction: 0.4, preparing: false))
    #expect(seen[2].fraction == 1 && !seen[2].preparing)
    #expect(seen.dropFirst(3).allSatisfy { $0.preparing && $0.fraction == 1 })
    #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
}

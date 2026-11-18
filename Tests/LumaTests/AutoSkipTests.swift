import Foundation
import Testing
@testable import Luma

@Test func chapterSkipMarkersKeepColdOpensAndPostCredits() {
    let chapters = [AutoSkip.Chapter(title: "Cold open", time: 0), .init(title: "Opening", time: 72), .init(title: "Episode", time: 162), .init(title: "End Credits", time: 2400), .init(title: "Post credits scene", time: 2490)]
    let result = AutoSkip.chapters(chapters, duration: 2520)
    #expect(result.intro?.start == 72)
    #expect(result.intro?.end == 162)
    #expect(result.intro?.contains(30) == false)
    // The credits window must end before the bonus scene.
    #expect(result.credits?.start == 2400)
    #expect(result.credits?.end == 2490)
    #expect(result.credits?.contains(2500) == false)
    #expect(AutoSkip.chapters([.init(title: "Chapter 1", time: 0)], duration: 2000).intro == nil)
}

@Test func repeatedAudioAlignmentRejectsSilenceAndShortRecaps() async throws {
    // Deterministic, temporally varying fingerprints simulate the same theme at different offsets.
    var seed: UInt32 = 0x12345678
    func random() -> AutoSkip.Print {
        seed = seed &* 1664525 &+ 1013904223
        return AutoSkip.Print(bits: seed, audible: true)
    }
    let motif = (0..<550).map { _ in random() }
    let a = (0..<110).map { _ in random() } + motif + (0..<200).map { _ in random() }
    let b = (0..<300).map { _ in random() } + motif + (0..<70).map { _ in random() }
    let range = try #require(try await AutoSkip.common(a, b))
    #expect(abs(range.lowerBound - Double(110) * AutoSkip.step) < 1)
    #expect(abs(range.upperBound - Double(660) * AutoSkip.step) < 1)
    let silence = Array(repeating: AutoSkip.Print(bits: 0, audible: false), count: 800)
    #expect(try await AutoSkip.common(silence, silence) == nil)
    let tone = Array(repeating: AutoSkip.Print(bits: 0xff00ff, audible: true), count: 800)
    #expect(try await AutoSkip.common(tone, tone) == nil)
    #expect(try await AutoSkip.common(Array(motif.prefix(120)), Array(motif.prefix(120))) == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_SKIP_FIXTURE"] != nil))
func extractsAndMatchesActualRepeatedAudio() async throws {
    let base = URL(filePath: ProcessInfo.processInfo.environment["LUMA_SKIP_FIXTURE"]!)
    let a = try await AutoSkip.fingerprints(AutoSkip.audio(base.appending(path: "A.wav"), start: 0, length: 55))
    let b = try await AutoSkip.fingerprints(AutoSkip.audio(base.appending(path: "B.wav"), start: 0, length: 55))
    let range = try #require(try await AutoSkip.common(a, b))
    #expect((4...8).contains(range.lowerBound))
    #expect((39...43).contains(range.upperBound))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_SKIP_FIXTURE"] != nil))
func realAudioRequiresThirdEpisodeConfirmation() async throws {
    let base = URL(filePath: ProcessInfo.processInfo.environment["LUMA_SKIP_FIXTURE"]!)
    let result = try await AutoSkip.compare(current: base.appending(path: "A.wav"), reference: base.appending(path: "B.wav"), confirmation: base.appending(path: "C.wav"), duration: 1200, analyzeCredits: false)
    let intro = try #require(result.intro)
    #expect((4...8).contains(intro.start))
    #expect((39...43).contains(intro.end))
    #expect(intro.source.contains("三集"))
    #expect(result.credits == nil)
}

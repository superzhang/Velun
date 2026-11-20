import SwiftUI
import Combine
import AVKit
import Observation

struct PlayerTrackChoice: Identifiable { let id: Int; let title: String }

@MainActor @Observable final class Playback {
    private struct AirPlayHandoff {
        let asset: AVURLAsset
        let position: Double
        let paused: Bool
    }

    let preferences: PlaybackPreferences
    static let automaticNativeSubtitle = -2
    private(set) var nativeAudio: [PlayerTrackChoice] = []
    private(set) var nativeSubtitles: [PlayerTrackChoice] = []
    private(set) var nativeAudioID = -1
    private(set) var nativeSubtitleID = -1
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    let player = AVPlayer()
    var mpv: MPVEngine?
    var media: Media?
    var error: String?
    private(set) var technicalInfo: MediaTechnicalInfo?
    private var resolvedPlaybackURL: URL?
    private var resolvedSubtitles: [URL] = []
    private var usingNativeAirPlay = false
    private(set) var preparingAirPlay = false
    private(set) var airPlayMessage: String?
    private var compatibilityTask: Task<Void, Never>?
    var exportingCompatibility = false
    var compatibilityMessage = ""
    var autoAdvance = UserDefaults.standard.object(forKey: "playback.autoAdvance") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoAdvance, forKey: "playback.autoAdvance") }
    }
    private var queue: [UUID] = []
    private var unindexedQueueItems: [UUID: Media] = [:]
    private var queueLoops = false
    var selectableEpisodes: [Media] {
        guard let media, let group = library.group(containing: media.id), group.isTV else { return [] }
        let removed = sources?.removedSourceIDs(in: library.referencedSourceIDs) ?? []
        var excluded = sources?.excludedSourceIDs ?? []
        if let sourceID = media.sourceID { excluded.remove(sourceID) }
        return group.episodes.compactMap { slot in
            let files = slot.files.filter { item in
                item.sourceMissing != true && (item.sourceID.map { !removed.contains($0) && !excluded.contains($0) } ?? true)
            }
            guard !files.isEmpty else { return nil }
            return EpisodeSlot(id: slot.id, code: slot.code, files: files).preferredFile(favoring: media.id)
        }
    }
    func selectEpisode(_ id: UUID) {
        guard id != media?.id, let episode = selectableEpisodes.first(where: { $0.id == id }) else { return }
        open(episode)
    }
    func playQueue(_ items: [Media], shuffled: Bool, loop: Bool) {
        let available = items.filter { $0.sourceMissing != true }
        let ordered = shuffled ? available.shuffled() : available
        guard let first = ordered.first else { return }
        queue = ordered.map(\.id); queueLoops = loop
        let indexedIDs = Set(library.items.map(\.id))
        unindexedQueueItems = Dictionary(ordered.filter { !indexedIDs.contains($0.id) }.map { ($0.id, $0) },
                                         uniquingKeysWith: { first, _ in first })
        preferences.options.repeatOne = false
        open(first)
    }
    var previousEpisode: Media? {
        guard let media else { return nil }
        if !queue.isEmpty {
            guard let index = queue.firstIndex(of: media.id) else { return nil }
            let previous = index > 0 ? queue[index - 1] : queueLoops ? queue.last : nil
            return previous.flatMap(queuedMedia)
        }
        return adjacentEpisode(offset: -1)
    }
    var nextEpisode: Media? {
        if !queue.isEmpty {
            guard let id = media?.id, let index = queue.firstIndex(of: id) else { return nil }
            let next = index + 1 < queue.count ? queue[index + 1] : queueLoops ? queue[0] : nil
            return next.flatMap(queuedMedia)
        }
        return adjacentEpisode(offset: 1)
    }
    private func adjacentEpisode(offset: Int) -> Media? {
        guard let current = media?.id else { return nil }
        let episodes = selectableEpisodes
        guard let index = episodes.firstIndex(where: { $0.id == current }),
              episodes.indices.contains(index + offset) else { return nil }
        return episodes[index + offset]
    }
    private func queuedMedia(_ id: UUID) -> Media? {
        library.items.first { $0.id == id } ?? unindexedQueueItems[id]
    }

    private func clearPlaybackQueue() {
        queue = []; unindexedQueueItems = [:]; queueLoops = false
    }
    nonisolated static func nextEpisode(after id: UUID, groups: [MediaGroup]) -> Media? {
        guard let group = groups.first(where: { $0.isTV && $0.items.contains(where: { $0.id == id }) }),
              let index = group.items.firstIndex(where: { $0.id == id }), group.items.indices.contains(index + 1) else { return nil }
        let current = EpisodeCode(group.items[index])
        return group.items.dropFirst(index + 1).first { candidate in
            let code = EpisodeCode(candidate)
            return candidate.sourceMissing != true && (current.episode == 0 || code > current)
        }
    }
    func finished() {
        guard let media else { return }
        if preferences.options.repeatOne {
            if let mpv { mpv.seek(0); mpv.set("pause", "no") }
            else { let current = player.currentItem; Task { await player.seek(to: .zero); guard player.currentItem === current else { return }; player.playImmediately(atRate: Float(preferences.options.speed)) } }
            return
        }
        saveProgress()
        markCompleted(media)
        if (!queue.isEmpty || autoAdvance), let next = nextEpisode { open(next) }
    }
    var autoSkipEnabled = UserDefaults.standard.object(forKey: "playback.autoSkip") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSkipEnabled, forKey: "playback.autoSkip"); if !autoSkipEnabled { skipTask?.cancel() } else { skipAttempted = nil } }
    }
    private(set) var skipAnalysis = ""
    private var detectedSkip = SkipDetection()
    private var nativeChapters: [AutoSkip.Chapter] = []
    private var skipTask: Task<Void, Never>?
    private var skipAttempted: UUID?
    private var nativeSkipPosition = 0.0
    var skipPosition: Double { mpv?.position ?? nativeSkipPosition }
    var skipDuration: Double { mpv?.duration ?? player.currentItem?.duration.seconds ?? 0 }
    var skipMarkers: SkipDetection {
        let chapters = mpv?.chapters.map { AutoSkip.Chapter(title: $0.title, time: $0.time) } ?? nativeChapters
        let tagged = AutoSkip.chapters(chapters, duration: skipDuration)
        return SkipDetection(intro: tagged.intro ?? detectedSkip.intro, credits: tagged.credits ?? detectedSkip.credits)
    }
    var activeIntro: SkipSegment? { autoSkipEnabled ? skipMarkers.intro.flatMap { $0.contains(skipPosition) ? $0 : nil } : nil }
    var activeCredits: SkipSegment? { autoSkipEnabled ? skipMarkers.credits.flatMap { $0.contains(skipPosition) ? $0 : nil } : nil }
    func skipIntro() {
        guard let intro = activeIntro else { return }
        if let mpv { mpv.seek(intro.end) }
        else { player.seek(to: CMTime(seconds: intro.end, preferredTimescale: 600)) }
    }
    func playNextFromCredits() {
        guard activeCredits != nil, let next = nextEpisode else { return }
        let completed = media
        open(next) // close() saves the outgoing position before the completed flag is written.
        if let completed { markCompleted(completed) }
    }
    func updateAutoSkip() {
        if mpv == nil { nativeSkipPosition = player.currentTime().seconds }
        guard autoSkipEnabled, let media, skipAttempted != media.id,
              skipDuration.isFinite, skipDuration > 600,
              let group = library.group(containing: media.id), group.isTV else { return }
        let references = AutoSkip.references(for: media, in: group)
        guard references.count == 2 else {
            skipAttempted = media.id
            if skipMarkers.intro == nil || skipMarkers.credits == nil { skipAnalysis = "音频交叉识别需要同季至少三集；章节标记仍可直接使用。" }
            return
        }
        let reference = references[0], confirmation = references[1]
        skipAttempted = media.id
        let duration = skipDuration
        skipTask = Task(priority: .utility) {
            do {
                try await Task.sleep(for: .seconds(3))
                if skipMarkers.intro != nil && skipMarkers.credits != nil { return }
                skipAnalysis = "正在自动识别片头片尾…"
                let key = await AutoSkipCache.key(media: media, reference: reference, confirmation: confirmation, duration: duration)
                if let saved = await AutoSkipCache.read(id: media.id, key: key) { try Task.checkCancellation(); detectedSkip = saved; skipAnalysis = "自动识别已完成"; return }
                let currentURL = try await RemoteSourceResolver.resolve(media)
                let referenceURL = try await RemoteSourceResolver.resolve(reference)
                let confirmationURL = try await RemoteSourceResolver.resolve(confirmation)
                let tagged = skipMarkers
                let result = try await AutoSkip.compare(current: currentURL, reference: referenceURL, confirmation: confirmationURL, duration: duration, analyzeIntro: tagged.intro == nil, analyzeCredits: tagged.credits == nil)
                try Task.checkCancellation()
                guard self.media?.id == media.id else { return }
                detectedSkip = result
                skipAnalysis = result.intro == nil && result.credits == nil ? "未找到可信的重复片头片尾" : "已通过三集交叉确认（重复音频）"
                await AutoSkipCache.save(id: media.id, key: key, result: result)
            } catch is CancellationError { }
            catch { if self.media?.id == media.id { skipAnalysis = "此视频暂无法分析，仍可使用章节标记" } }
        }
    }
    var loading = false
    private var timer: Timer?
    private var preparation: Task<Void, Never>?
    private var status: NSKeyValueObservation?
    private var volumeStatus: NSKeyValueObservation?
    private var muteStatus: NSKeyValueObservation?
    private let library: Library
    private let sources: SourcesStore?
    private let directHistory: DirectFilePlaybackHistory
    private var completedDirectFileID: UUID?
    init(library: Library, preferences: PlaybackPreferences? = nil, sources: SourcesStore? = nil,
         directHistory: DirectFilePlaybackHistory? = nil) {
        self.library = library
        self.preferences = preferences ?? PlaybackPreferences()
        self.sources = sources
        self.directHistory = directHistory ?? DirectFilePlaybackHistory()
    }
    func open(_ media: Media) {
        open(media, handoff: nil)
    }
    private func open(_ incoming: Media, handoff: AirPlayHandoff?) {
        let preferAirPlay = handoff != nil || player.isExternalPlaybackActive
        close(clearQueue: false)
        let media = directHistory.mediaRestoringProgress(incoming)
        usingNativeAirPlay = preferAirPlay
        if !queue.contains(media.id) { clearPlaybackQueue() }
        self.media = media
        guard media.sourceMissing != true else {
            error = "来源中找不到此文件。文件恢复后可重新扫描来源。"
            return
        }
        loading = true
        preparation = Task { [self] in
            do {
                let resolved: URL
                if let handoff { resolved = handoff.asset.url }
                else { resolved = try await RemoteSourceResolver.resolve(media) }
                try Task.checkCancellation()
                resolvedPlaybackURL = resolved
                var sidecars = media.sidecars
                if media.sourceID == nil && media.url.isFileURL { sidecars = await SidecarIndex.local(for: media.url) }
                var subtitles: [URL] = []
                for subtitle in SidecarIndex.prioritizedSubtitles(sidecars?.subtitles ?? [], for: media.url, language: preferences.options.subtitleLanguage) {
                    try Task.checkCancellation()
                    if let url = try? await RemoteSourceResolver.resolveSidecar(subtitle) { subtitles.append(url) }
                }
                try Task.checkCancellation()
                resolvedSubtitles = subtitles
                let technical = try? await VideoProbe.shared.information(media)
                try Task.checkCancellation()
                technicalInfo = technical
                var stream = media; stream.url = resolved
                let nativeImmersive = preferences.options.nativeHDRPreferred && (technical?.isHDR == true || technical?.hasAtmos == true)
                let requiresEnhancedFormat = media.url.pathExtension.lowercased() == "mkv" || technical?.hasSystemCompatibleAudio == false
                let prefersEnhanced = preferences.options.audioMode != .automatic || (preferences.options.preferEnhancedPlayer && !nativeImmersive)
                let canUseEnhancedSubtitles = !nativeImmersive && technical?.requiresNativeDolbyVision != true && !subtitles.isEmpty
                if requiresEnhancedFormat || (!preferAirPlay && (prefersEnhanced || canUseEnhancedSubtitles)) {
                    startMPV(stream); return
                }
                if resolved.isFileURL && !FileManager.default.fileExists(atPath: resolved.path) { throw CocoaError(.fileNoSuchFile) }
                let asset = handoff?.asset ?? AVURLAsset(url: resolved)
                guard try await asset.load(.isPlayable) else {
                    try Task.checkCancellation()
                    startMPV(stream); return
                }
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: asset)
                item.allowedAudioSpatializationFormats = preferences.options.allowsSpatialAudio ? .multichannel : []
                player.replaceCurrentItem(with: item)
                status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    let message = item.status == .failed ? (item.error?.localizedDescription ?? "播放失败") : nil
                    if let message {
                        Task { @MainActor [weak self] in
                            guard let self, self.player.currentItem === item else { return }
                            self.error = message
                            self.loading = false
                        }
                    }
                }
                if let position = handoff?.position, position.isFinite, position > 0 {
                    await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                } else if handoff == nil, media.isContinuing {
                    await player.seek(to: CMTime(seconds: media.position, preferredTimescale: 600))
                }
                try Task.checkCancellation()
                if let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["zh", "en"]) {
                    try Task.checkCancellation()
                    nativeChapters = []
                    for group in groups {
                        let title = group.items.first(where: { $0.commonKey == .commonKeyTitle })
                        let name = try? await title?.load(.stringValue)
                        try Task.checkCancellation()
                        nativeChapters.append(AutoSkip.Chapter(title: name ?? "", time: group.timeRange.start.seconds))
                    }
                }
                try await loadNativeTracks(asset: asset, item: item)
                try Task.checkCancellation()
                loading = false
                applyPreferences()
                if handoff?.paused != true { player.playImmediately(atRate: Float(preferences.options.speed)) }
                volumeStatus = player.observe(\.volume, options: [.new]) { [weak self] player, _ in
                    let value = Double(player.volume) * 100
                    Task { @MainActor [weak self] in
                        guard let self, abs(self.preferences.options.volume - value) > 0.01 else { return }
                        self.preferences.options.volume = value
                    }
                }
                muteStatus = player.observe(\.isMuted, options: [.new]) { [weak self] player, _ in
                    let value = player.isMuted
                    Task { @MainActor [weak self] in
                        guard let self, self.preferences.options.muted != value else { return }
                        self.preferences.options.muted = value
                    }
                }
                timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.saveProgress() }
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription; self.loading = false } }
        }
    }
    func prepareAirPlay() {
        guard let engine = mpv, let media, let url = resolvedPlaybackURL, !preparingAirPlay else { return }
        guard media.url.pathExtension.lowercased() != "mkv", technicalInfo?.hasSystemCompatibleAudio != false else {
            airPlayMessage = "此片源需要增强播放器，请使用屏幕镜像。"
            return
        }
        preparingAirPlay = true
        airPlayMessage = nil
        preparation = Task {
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) == true
            guard !Task.isCancelled, mpv === engine else { return }
            preparingAirPlay = false
            guard playable else {
                airPlayMessage = "系统播放器无法打开此片源，请使用屏幕镜像。"
                return
            }
            open(media, handoff: AirPlayHandoff(asset: asset, position: engine.position, paused: engine.paused))
        }
    }
    private func startMPV(_ media: Media, paused: Bool = false) {
        usingNativeAirPlay = false
        if technicalInfo?.requiresNativeDolbyVision == true {
            loading = false
            error = "此 Dolby Vision 片源没有可直接显示的 HDR 兼容层。请使用系统兼容的 MP4 / MOV，或创建无损封装副本，避免紫绿偏色。"
            return
        }
        let id = media.id
        let memory = library.playbackMemory(for: id).enhanced ?? EnhancedPlaybackMemory()
        mpv = MPVEngine(url: media.url, resume: media.isContinuing ? media.position : 0, options: preferences.options,
                        paused: paused, externalSubtitles: resolvedSubtitles, memory: memory) { [weak self] memory in
            self?.library.updatePlaybackMemory(for: id) { $0.enhanced = memory }
        }
        loading = false
        applyPreferences()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.saveProgress() } }
    }
    func applyPreferences() {
        if preferences.options.audioMode == .passthrough && preferences.options.speed != 1 { preferences.options.speed = 1 }
        let options = preferences.options.sanitized()
        if options.audioMode != .automatic && !usingNativeAirPlay && mpv == nil && player.currentItem != nil { useEnhancedPlayer(); return }
        player.currentItem?.allowedAudioSpatializationFormats = options.allowsSpatialAudio ? .multichannel : []
        mpv?.apply(options)
        mpv?.surface?.updateHDROutput()
        let gain = [0, 3, 6, 9].contains(preferences.audioBoost) ? preferences.audioBoost : 0
        mpv?.setAudioBoost(gain)
        player.volume = Float(options.volume / 100); player.isMuted = options.muted
        player.defaultRate = Float(options.speed)
        if player.rate > 0 { player.rate = Float(options.speed) }
    }
    func resetSettings() {
        preferences.reset(); autoAdvance = true; autoSkipEnabled = true
        if let media { library.updatePlaybackMemory(for: media.id) { $0 = FilePlaybackMemory() } }
        mpv?.setAudioDelay(0)
        mpv?.forgetFileChoices(options: preferences.options)
        selectNativeAudio(-1)
        selectNativeSubtitle(Self.automaticNativeSubtitle)
        applyPreferences()
    }
    func useEnhancedPlayer() {
        guard mpv == nil, var current = media else { return }
        let wasPaused = player.rate == 0
        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? current.duration
        if position.isFinite { current.position = position }
        if duration.isFinite { current.duration = duration }
        let technical = technicalInfo, resolved = resolvedPlaybackURL, subtitles = resolvedSubtitles
        close(clearQueue: false); media = current; technicalInfo = technical; resolvedPlaybackURL = resolved; resolvedSubtitles = subtitles
        var stream = current; stream.url = resolved ?? current.url
        startMPV(stream, paused: wasPaused)
    }
    func exportNativeCompatibleCopy() {
        guard !exportingCompatibility, let media, let info = technicalInfo else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = media.title.replacingOccurrences(of: "/", with: " ") + ".mp4"
        panel.message = "无损重新封装视频和一条系统兼容音轨，保留 Dolby Vision / E-AC-3 Atmos 数据；不重新编码。完成后打开副本。"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.resolvingSymlinksInPath() != media.url.resolvingSymlinksInPath() else { compatibilityMessage = "请选择不同于原文件的路径。"; return }
        exportingCompatibility = true; compatibilityMessage = "正在创建无损封装副本…完整写入文件后才能打开。"
        compatibilityTask = Task {
            defer { exportingCompatibility = false; compatibilityTask = nil }
            do {
                let source = try await RemoteSourceResolver.resolve(media)
                try await NativeCompatibleCopy.save(source, to: destination, info: info)
                try Task.checkCancellation()
                library.add([destination])
                guard var copy = library.items.first(where: { $0.url == destination }) else { return }
                if let metadata = media.metadata { library.applyMetadata(metadata, to: [copy.id]) }
                copy.position = skipPosition; copy.duration = skipDuration
                preferences.options.preferNativeHDR = true
                open(copy)
            } catch is CancellationError { }
            catch { compatibilityMessage = error.localizedDescription }
        }
    }
    private func loadNativeTracks(asset: AVAsset, item: AVPlayerItem) async throws {
        let audio = try await asset.loadMediaSelectionGroup(for: .audible)
        let subtitles = try await asset.loadMediaSelectionGroup(for: .legible)
        try Task.checkCancellation()
        audioGroup = audio; subtitleGroup = subtitles
        nativeAudio = audio?.options.enumerated().map { PlayerTrackChoice(id: $0.offset, title: $0.element.displayName) } ?? []
        nativeSubtitles = subtitles?.options.enumerated().map { PlayerTrackChoice(id: $0.offset, title: $0.element.displayName) } ?? []
        let memory = media.map { library.playbackMemory(for: $0.id) }
        if let audio {
            if let option = memory?.nativeAudio.flatMap({ Self.restoreNativeOption($0, in: audio) }) {
                item.select(option, in: audio)
            } else {
                selectPreferredNativeOption(in: audio, item: item, language: preferences.options.audioLanguage)
            }
            nativeAudioID = audio.options.firstIndex { $0 == item.currentMediaSelection.selectedMediaOption(in: audio) } ?? -1
        }
        if let subtitles {
            switch memory?.nativeSubtitles {
            case .off:
                item.select(nil, in: subtitles)
            case .track(let data):
                if let option = Self.restoreNativeOption(data, in: subtitles) { item.select(option, in: subtitles) }
                else { selectDefaultNativeSubtitle(in: subtitles, item: item) }
            case nil:
                selectDefaultNativeSubtitle(in: subtitles, item: item)
            }
            nativeSubtitleID = subtitles.options.firstIndex { $0 == item.currentMediaSelection.selectedMediaOption(in: subtitles) } ?? -1
        }
    }

    private static func restoreNativeOption(_ data: Data, in group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return group.mediaSelectionOption(withPropertyList: propertyList)
    }

    private static func encodeNativeOption(_ option: AVMediaSelectionOption) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: option.propertyList(), format: .binary, options: 0)
    }

    private func selectPreferredNativeOption(in group: AVMediaSelectionGroup, item: AVPlayerItem, language: TrackLanguage) {
        let aliases = language.mpvValue.lowercased().split(separator: ",")
        let option = group.options.first { option in
            let code = (option.extendedLanguageTag ?? option.locale?.identifier ?? "").lowercased()
            return aliases.contains { code.hasPrefix($0) }
        }
        if let option { item.select(option, in: group) }
        else { item.selectMediaOptionAutomatically(in: group) }
    }

    private func selectDefaultNativeSubtitle(in group: AVMediaSelectionGroup, item: AVPlayerItem) {
        if preferences.options.subtitlesEnabled {
            selectPreferredNativeOption(in: group, item: item, language: preferences.options.subtitleLanguage)
        } else {
            item.select(nil, in: group)
        }
    }

    func selectNativeAudio(_ id: Int) {
        guard let audioGroup, let item = player.currentItem, let media else { return }
        if id == -1 {
            selectPreferredNativeOption(in: audioGroup, item: item, language: preferences.options.audioLanguage)
            library.updatePlaybackMemory(for: media.id) { $0.nativeAudio = nil }
            nativeAudioID = id
        } else if audioGroup.options.indices.contains(id) {
            let option = audioGroup.options[id]
            item.select(option, in: audioGroup)
            nativeAudioID = id
            if let data = Self.encodeNativeOption(option) {
                library.updatePlaybackMemory(for: media.id) { $0.nativeAudio = data }
            }
        }
    }

    func selectNativeSubtitle(_ id: Int) {
        guard let subtitleGroup, let item = player.currentItem, let media else { return }
        if id == Self.automaticNativeSubtitle {
            selectDefaultNativeSubtitle(in: subtitleGroup, item: item)
            library.updatePlaybackMemory(for: media.id) { $0.nativeSubtitles = nil }
        } else if id == -1 {
            item.select(nil, in: subtitleGroup)
            library.updatePlaybackMemory(for: media.id) { $0.nativeSubtitles = .off }
        } else if subtitleGroup.options.indices.contains(id) {
            let option = subtitleGroup.options[id]
            item.select(option, in: subtitleGroup)
            if let data = Self.encodeNativeOption(option) {
                library.updatePlaybackMemory(for: media.id) { $0.nativeSubtitles = .track(data) }
            }
        } else {
            return
        }
        nativeSubtitleID = id
    }
    func saveProgress() {
        guard let media else { return }
        if let mpv {
            if mpv.duration > 0 && !mpv.loading {
                recordProgress(for: media, position: mpv.position, duration: mpv.duration)
            }
        } else if let item = player.currentItem, media.directPlaybackURL == nil || !loading {
            recordProgress(for: media, position: player.currentTime().seconds, duration: item.duration.seconds)
        }
    }
    private func recordProgress(for media: Media, position: Double, duration: Double) {
        if let directURL = media.directPlaybackURL {
            directHistory.record(directURL, position: position, duration: duration, watched: completedDirectFileID == media.id)
        } else {
            library.update(media.id, position: position, duration: duration)
        }
    }
    private func markCompleted(_ media: Media) {
        if let directURL = media.directPlaybackURL {
            if media.id == self.media?.id { completedDirectFileID = media.id }
            directHistory.finish(directURL)
            directHistory.flush()
        } else {
            library.setEpisodeWatched(media.id, to: true)
        }
    }
    func close(clearQueue: Bool = true) {
        if clearQueue { clearPlaybackQueue() }
        preparation?.cancel(); preparation = nil
        preparingAirPlay = false; airPlayMessage = nil; usingNativeAirPlay = false
        compatibilityTask?.cancel(); compatibilityTask = nil; exportingCompatibility = false; compatibilityMessage = ""
        technicalInfo = nil; resolvedPlaybackURL = nil; resolvedSubtitles = []
        skipTask?.cancel(); skipTask = nil; skipAttempted = nil; detectedSkip = SkipDetection(); nativeChapters = []; skipAnalysis = ""
        saveProgress(); directHistory.flush(); completedDirectFileID = nil; timer?.invalidate(); timer = nil
        mpv?.stop(); mpv = nil
        status = nil; volumeStatus = nil; muteStatus = nil; player.pause(); player.replaceCurrentItem(with: nil)
        media = nil; error = nil; loading = false; technicalInfo = nil; resolvedPlaybackURL = nil
        nativeAudio = []; nativeSubtitles = []; audioGroup = nil; subtitleGroup = nil
        nativeAudioID = -1; nativeSubtitleID = -1
    }
}

struct NativePlayer: NSViewRepresentable {
    let player: AVPlayer
    let sizing: VideoSizing
    var hdrMode: HDRPlaybackMode = .automatic
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.videoGravity = gravity
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        if #available(macOS 26, *) { view.preferredDisplayDynamicRange = hdrMode == .sdr ? .standard : .automatic }
        return view
    }
    private var gravity: AVLayerVideoGravity { switch sizing { case .fit: .resizeAspect; case .fill: .resizeAspectFill; case .stretch: .resize } }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player; view.videoGravity = gravity
        if #available(macOS 26, *) { view.preferredDisplayDynamicRange = hdrMode == .sdr ? .standard : .automatic }
    }
}

struct PlaybackView: View {
    @Bindable var playback: Playback
    @State private var controlsVisible = true
    @State private var showSettings = false
    @State private var settingsTab = 0
    @State private var overControls = false
    @State private var controlsLocked = false
    @State private var routePickerOpen = false
    @State private var controlPanel: PlaybackControlPanel?
    @State private var lastInteraction = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var title: String { playback.media?.metadata?.title ?? playback.media?.title ?? "" }

    private func extraControls(height: CGFloat) -> PlaybackExtraControls {
        PlaybackExtraControls(playback: playback, panel: $controlPanel, height: height) {
            routePickerOpen = $0
            controlsVisible = true
            lastInteraction = Date()
        }
    }

    var body: some View {
        ZStack {
            Color.black
            if let engine = playback.mpv {
                MPVSurface(engine: engine).id(playback.media?.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack {
                    Spacer()
                    MPVControls(engine: engine, preferences: playback.preferences, extraControls: extraControls(height: 44),
                        previous: { if engine.position > 3 || playback.previousEpisode == nil { engine.seek(0) } else if let previous = playback.previousEpisode { playback.open(previous) } },
                        next: playback.nextEpisode.map { next in { playback.open(next) } },
                        settings: { settingsTab = $0; showSettings = true }, interaction: { controlsLocked = $0; lastInteraction = Date(); controlsVisible = true })
                        .onHover { overControls = $0 }
                }.opacity(controlsVisible ? 1 : 0).allowsHitTesting(controlsVisible).accessibilityHidden(!controlsVisible)
                if engine.loading && engine.error == nil { loading("正在缓冲…") }
                if let error = engine.error { failure(error) }
            } else {
                NativePlayer(player: playback.player, sizing: playback.preferences.options.sizing, hdrMode: playback.preferences.options.hdrMode)
            }
            VStack {
                ZStack {
                    Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1).padding(.horizontal, 160).shadow(color: .black, radius: 6)
                    HStack {
                        Button { playback.close() } label: { Label("关闭", systemImage: "xmark").font(.system(size: 13, weight: .medium)).padding(.horizontal, 13).frame(height: 36).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                            .buttonStyle(.plain).help("返回媒体库").accessibilityLabel("返回媒体库")
                        Spacer()
                        if playback.mpv == nil {
                            let controls = extraControls(height: 36)
                            controls
                            controls.episodeButton
                            NativeAdvancedMenu(playback: playback, settings: { settingsTab = $0; showSettings = true }, interaction: { controlsLocked = $0; lastInteraction = Date(); controlsVisible = true })
                        }
                    }
                }.padding(.horizontal, 22).frame(height: 68)
                    .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
                    .onHover { overControls = $0 }
                Spacer()
            }.opacity(controlsVisible ? 1 : 0).allowsHitTesting(controlsVisible).accessibilityHidden(!controlsVisible)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if playback.activeIntro != nil {
                        Button { playback.skipIntro() } label: { Label(playback.activeIntro?.source == "章节标记" ? "跳过片头" : "跳过重复片段", systemImage: "forward.end.fill") }
                            .buttonStyle(.borderedProminent).tint(.white.opacity(0.22)).help(playback.activeIntro?.source ?? "")
                    }
                    if playback.activeCredits != nil, playback.nextEpisode != nil {
                        Button { playback.playNextFromCredits() } label: { Label("下一集", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).tint(.white.opacity(0.22)).help(playback.activeCredits?.source ?? "")
                    }
                }.controlSize(.large).padding(.horizontal, 34).padding(.bottom, controlsVisible ? 140 : 38)
            }
            if playback.loading { loading("正在准备播放…") }
            if let error = playback.error { failure(error) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controlsVisible)
        .onContinuousHover { phase in if case .active = phase { lastInteraction = Date(); controlsVisible = true } }
        .onChange(of: controlsVisible) { _, visible in playback.mpv?.setControlsVisible(visible) }
        .onChange(of: playback.media?.id) { _, _ in
            controlPanel = nil
            routePickerOpen = false
            controlsVisible = true
            lastInteraction = Date()
        }
        .onChange(of: playback.mpv == nil) { _, _ in
            controlPanel = nil
            routePickerOpen = false
            controlsVisible = true
            lastInteraction = Date()
        }
        .onChange(of: controlPanel) { _, _ in lastInteraction = Date() }
        .onChange(of: playback.mpv?.ended) { _, ended in if ended == true { playback.finished() } }
        .onReceive(clock) { now in
            playback.updateAutoSkip()
            let paused = playback.mpv?.paused ?? (playback.player.rate == 0)
            controlsVisible = showSettings || controlsLocked || routePickerOpen || controlPanel != nil || paused || overControls || now.timeIntervalSince(lastInteraction) < 3
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            if let item = note.object as? AVPlayerItem, item === playback.player.currentItem { playback.finished() }
        }
        .sheet(isPresented: $showSettings) { PlayerSettingsView(playback: playback, initialTab: settingsTab).tint(.orange) }
        .onChange(of: playback.preferences.audioBoost) { _, _ in playback.applyPreferences() }
        .onChange(of: playback.preferences.options) { _, _ in playback.applyPreferences() }
        .onChange(of: playback.mpv?.volume) { _, volume in if let volume, playback.preferences.options.volume != volume { playback.preferences.options.volume = volume } }
        .onDisappear { playback.close() }
    }
    private func loading(_ text: String) -> some View { ProgressView(text).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) }
    private func failure(_ text: String) -> some View {
        ContentUnavailableView { Label("暂时无法播放", systemImage: "exclamationmark.triangle") } description: { Text(text) } actions: {
            Button("返回媒体库") { playback.close() }
            if playback.technicalInfo?.requiresNativeDolbyVision == true {
                Button("创建系统兼容 MP4 副本…") { playback.exportNativeCompatibleCopy() }.disabled(playback.exportingCompatibility)
                if !playback.compatibilityMessage.isEmpty { Text(playback.compatibilityMessage).font(.caption) }
            }
        }
    }
}

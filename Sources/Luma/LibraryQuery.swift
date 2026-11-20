import Foundation

@MainActor final class LibraryQueryCache {
    private struct Key: Equatable {
        let libraryID: ObjectIdentifier
        let revision: Int
        let destination: Destination
        let search: String
        let localOnly: Bool
        let sourceID: UUID?
        let genre: String?
        let sort: String
        let excludedSourceIDs: Set<UUID>
        let castCredits: Set<TMDBTitleID>
    }
    private var key: Key?
    private var result: [MediaGroup] = []
    func groups(in library: Library, destination: Destination, search: String = "", localOnly: Bool = false, sourceID: UUID? = nil, genre: String? = nil, sort: String = "recent", excludedSourceIDs: Set<UUID> = [], castCredits: Set<TMDBTitleID> = []) -> [MediaGroup] {
        let key = Key(libraryID: ObjectIdentifier(library), revision: library.revision, destination: destination, search: search, localOnly: localOnly, sourceID: sourceID, genre: genre, sort: sort, excludedSourceIDs: excludedSourceIDs, castCredits: castCredits)
        if self.key == key { return result }
        let needle = MediaGroup.searchKey(search)
        var groups = library.groupedItems
        let customList: Bool = switch destination { case .playlist, .collection: true; default: false }
        if localOnly || sourceID != nil || customList || !excludedSourceIDs.isEmpty {
            groups = groups.compactMap { group in
                let values = group.items.filter { item in
                    let membership: Bool = switch destination {
                    case .playlist(let name): item.playlists?.contains(name) == true
                    case .collection(let name): item.collectionName == name
                    default: true
                    }
                    let excluded = item.sourceID.map { excludedSourceIDs.contains($0) } ?? false
                    return !excluded && membership && (!localOnly || item.isLocalFile) && (sourceID == nil || item.sourceID == sourceID)
                }
                if values.count == group.items.count { return group }
                return values.isEmpty ? nil : MediaGroup(id: group.id, items: values)
            }
        }
        groups = groups.filter { group in
            guard needle.isEmpty || group.searchIndex.contains(needle) else { return false }
            switch destination {
            case .playlist(let name): return group.items.contains { $0.playlists?.contains(name) == true }
            case .collection(let name): return group.items.contains { $0.collectionName == name }
            case .movies: return !group.isTV
            case .shows: return group.isTV
            case .unwatched: return !group.isWatched
            case .favorites: return group.hasFavorite
            case .top: return !group.isTV && (group.info?.rating ?? 0) > 0
            case .genres: return !group.isTV && (genre == nil || group.genres.contains(genre!))
            case .unmatched: return group.info == nil && !group.hasLocalTitle
            case .performer(let id, _):
                guard let info = group.info else { return false }
                return castCredits.contains(TMDBTitleID(id: info.id, kind: info.kind))
                    || group.items.contains { $0.metadata?.cast?.contains { $0.id == id } == true }
            default: return true
            }
        }.sorted { a, b in
            if destination == .top || sort == "rating" { return (a.info?.rating ?? 0) > (b.info?.rating ?? 0) }
            if sort == "name" { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            if sort == "year" { return (a.year ?? "") > (b.year ?? "") }
            return a.added > b.added
        }
        self.key = key; result = groups
        return groups
    }
}

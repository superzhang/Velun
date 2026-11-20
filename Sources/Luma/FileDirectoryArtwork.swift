import Foundation

struct FileDirectoryArtwork {
    let title: String
    let subtitle: String?
    let poster: URL
    let fallback: URL?

    private struct Folder {
        let workID: String
        var localPoster: URL?
        var seasons: Set<Int> = []
    }

    static func index(groups: [MediaGroup], directories: [UUID: [Substring]]) -> [String: FileDirectoryArtwork] {
        guard !directories.isEmpty else { return [:] }
        var artwork: [String: FileDirectoryArtwork] = [:]
        var folders: [String: Folder] = [:]
        var works: [String: MediaGroup] = [:]
        var mixed = Set<String>()
        for group in groups {
            for item in group.items where item.sourceMissing != true {
                guard let root = item.sourceID.flatMap({ directories[$0] }) else { continue }
                let path = item.sourcePath.split(separator: "/")
                guard path.count > root.count, path.starts(with: root) else { continue }
                let relative = path.dropFirst(root.count)
                guard let entry = relative.first else { continue }
                let name = String(entry)
                if relative.count == 1 {
                    if let poster = item.sidecars?.poster ?? group.poster, artwork[name] == nil {
                        artwork[name] = FileDirectoryArtwork(title: group.isTV ? item.title : group.title,
                                                               subtitle: group.isTV ? nil : group.year, poster: poster,
                                                               fallback: group.info?.poster)
                    }
                } else {
                    if let folder = folders[name], folder.workID != group.id {
                        mixed.insert(name)
                        continue
                    }
                    if mixed.contains(name) { continue }
                    if folders[name] == nil {
                        folders[name] = Folder(workID: group.id)
                        works[group.id] = group
                    }
                    if folders[name]?.localPoster == nil { folders[name]?.localPoster = item.sidecars?.poster }
                    if group.isTV { folders[name]?.seasons.insert(EpisodeCode(item).season) }
                }
            }
        }
        for (name, folder) in folders where !mixed.contains(name) {
            guard let group = works[folder.workID],
                  let poster = folder.localPoster ?? group.poster else { continue }
            let subtitle: String?
            if let season = folder.seasons.first, folder.seasons.count == 1 {
                subtitle = season == 0 ? "特别篇" : "第 \(season) 季"
            } else {
                subtitle = group.isTV ? "\(folder.seasons.count) 季" : group.year
            }
            artwork[name] = FileDirectoryArtwork(title: group.title, subtitle: subtitle, poster: poster, fallback: group.info?.poster)
        }
        return artwork
    }
}

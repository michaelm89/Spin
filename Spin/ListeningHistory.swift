import Foundation

/// An album as Spin knows it: identified by its cover URL, which Spotify shares across an album's tracks.
struct AlbumRef: Hashable, Codable {
    let artworkURL: String
    var name: String = ""
    var artist: String = ""
}

/// Songs Spin has seen play to the end, saved in Application Support.
final class ListeningHistory: ObservableObject {
    static let shared = ListeningHistory()

    struct Completion: Codable {
        let album: AlbumRef
        let trackID: String
        let date: Date
    }

    @Published private(set) var completions: [Completion] = []

    private static let maxStored = 5000
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Completion].self, from: data) {
            completions = saved
        }
    }

    func record(_ track: PlaybackState, artworkURL: String) {
        let album = AlbumRef(artworkURL: artworkURL, name: track.album, artist: track.artist)
        completions.append(Completion(album: album, trackID: track.trackID, date: Date()))
        if completions.count > Self.maxStored { completions.removeFirst(completions.count - Self.maxStored) }
        let snapshot = completions
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        }
    }

    /// Albums ordered by when one of their songs last finished, newest first.
    var recentAlbums: [(album: AlbumRef, date: Date)] {
        var seen = Set<String>()
        var result: [(AlbumRef, Date)] = []
        for completion in completions.reversed() where seen.insert(completion.album.artworkURL).inserted {
            result.append((completion.album, completion.date))
        }
        return result
    }

    /// Albums ordered by how many of their songs Spin has seen finish.
    var mostPlayedAlbums: [AlbumRef] {
        var counts: [String: (AlbumRef, Int)] = [:]
        for completion in completions {
            counts[completion.album.artworkURL, default: (completion.album, 0)].1 += 1
        }
        return counts.values.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

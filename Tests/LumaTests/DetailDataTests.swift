import Foundation
import Testing
@testable import Luma

@Test func detailResolutionUsesEncodedDimensions() throws {
    let crop = try VideoDimensions.decode(Data(#"{"streams":[{"width":3840,"height":1600}]}"#.utf8))
    #expect(crop?.badge == "4K")
    #expect(VideoDimensions(width: 1920, height: 800).badge == "1080p")
    #expect(VideoDimensions(width: 1280, height: 536).badge == "720p")
    #expect(VideoDimensions(width: 720, height: 480).badge == "SD")
    #expect(try VideoDimensions.decode(Data(#"{"streams":[]}"#.utf8)) == nil)
    #expect(try VideoDimensions.decode(Data(#"{"streams":[{"width":0,"height":1080}]}"#.utf8)) == nil)
}

@Test func imdbDatasetMatchesWholeIDAndRejectsInvalidScores() {
    let data = Data("tconst\taverageRating\tnumVotes\ntt12345670\t6.0\t100\ntt1234567\t7.6\t840\ntt9876543\t11.2\t40\ntt1111111\t8.0\t0\n".utf8)
    #expect(IMDbRating.find("tt1234567", in: data) == IMDbRating(score: 7.6, votes: 840))
    #expect(IMDbRating.find("tt12345670", in: data)?.score == 6)
    #expect(IMDbRating.find("tt9876543", in: data) == nil)
    #expect(IMDbRating.find("tt1111111", in: data) == nil)
    #expect(IMDbRating.find("tt123456", in: data) == nil)
    #expect(IMDbRating.find("tt1234567\n", in: data) == nil)
}

@Test func detailMetadataLoadsLogoExternalIDAndCertification() async throws {
    let payload = Data(#"{"genres":[{"name":"剧情"}],"runtime":62,"first_air_date":"2026-10-24","credits":{"cast":[]},"external_ids":{"imdb_id":"tt1234567"},"images":{"logos":[{"file_path":"/english.png","iso_639_1":"en","vote_average":9},{"file_path":"/chinese.png","iso_639_1":"zh","vote_average":7}]},"content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-MA"}]}}"#.utf8)
    let client = TMDBClient { request in
        #expect(request.url?.query?.contains("external_ids") == true)
        return (payload, 200)
    }
    let original = MovieInfo(id: 1, kind: "tv", title: "测试", year: "2026", overview: "", poster: nil)
    let detail = try await client.details(original, token: "fixture")
    #expect(detail.logo?.lastPathComponent == "chinese.png")
    #expect(detail.imdbID == "tt1234567")
    #expect(detail.certification == "TV-MA")
    #expect(detail.releaseDate == "2026-10-24")
    #expect(detail.detailVersion == 2)
    // Old saved metadata keeps decoding; newly optional fields need no migration.
    let old = try JSONDecoder().decode(MovieInfo.self, from: JSONEncoder().encode(original))
    #expect(old.detailVersion == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_MKV_FIXTURE"] != nil)) func detailProbeReadsRealMKV() async throws {
    let file = URL(filePath: try #require(ProcessInfo.processInfo.environment["LUMA_MKV_FIXTURE"]))
    let size = try await VideoProbe.inspect(file)
    #expect(size != nil)
    #expect((size?.width ?? 0) > 0)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_LIVE_IMDB"] == "1")) func imdbOfficialDatasetLoadsAndCaches() async throws {
    let rating = try await IMDbRatings.shared.rating("tt0111161")
    #expect((rating?.score ?? 0) > 8)
    #expect((rating?.votes ?? 0) > 1000)
    let cached = try await IMDbRatings.shared.rating("tt0111161")
    #expect(cached == rating)
}

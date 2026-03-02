import Foundation

enum FailedReasonType: String, Codable, CaseIterable {
    case notFound404 = "404/不可用"
    case timeout = "超时"
    case fetchFailed = "抓取失败"
}

struct RepoIdentity: Hashable {
    let owner: String
    let name: String

    var fullName: String { "\(owner)/\(name)" }
}

struct GitHubRepo: Decodable {
    let name: String
    let fullName: String
    let description: String?
    let language: String?
    let stargazersCount: Int
    let htmlURL: URL
    let topics: [String]?
    let updatedAt: String?
    let archived: Bool?
    let disabled: Bool?
    let fork: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case description
        case language
        case stargazersCount = "stargazers_count"
        case htmlURL = "html_url"
        case topics
        case updatedAt = "updated_at"
        case archived
        case disabled
        case fork
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let publishedAt: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case publishedAt = "published_at"
        case assets
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

struct RepoRecord: Codable, Identifiable {
    let id: String
    let owner: String
    let repo: String
    var projectName: String
    var sourceURL: String

    var descriptionEN: String
    var descriptionZH: String
    var summaryZH: String

    var releaseNotesEN: String
    var releaseNotesZH: String
    var setupGuideEN: String
    var formattedZH: String

    var category: String
    var language: String
    var stars: Int
    var isFork: Bool

    var releaseTag: String
    var releaseAssetName: String
    var releaseAssetURL: String

    var hasDownloadAsset: Bool
    var localPath: String
    var previewImagePath: String
    var storageRootPath: String
    var infoFilePath: String

    var updatedAt: Date

    var fullName: String { "\(owner)/\(repo)" }
    var displayCategory: String { hasDownloadAsset ? "有安装包项目" : "无安装包项目" }

    init(
        id: String,
        owner: String,
        repo: String,
        projectName: String,
        sourceURL: String,
        descriptionEN: String,
        descriptionZH: String,
        summaryZH: String,
        releaseNotesEN: String,
        releaseNotesZH: String,
        setupGuideEN: String,
        formattedZH: String,
        category: String,
        language: String,
        stars: Int,
        isFork: Bool,
        releaseTag: String,
        releaseAssetName: String,
        releaseAssetURL: String,
        hasDownloadAsset: Bool,
        localPath: String,
        previewImagePath: String,
        storageRootPath: String,
        infoFilePath: String,
        updatedAt: Date
    ) {
        self.id = id
        self.owner = owner
        self.repo = repo
        self.projectName = projectName
        self.sourceURL = sourceURL
        self.descriptionEN = descriptionEN
        self.descriptionZH = descriptionZH
        self.summaryZH = summaryZH
        self.releaseNotesEN = releaseNotesEN
        self.releaseNotesZH = releaseNotesZH
        self.setupGuideEN = setupGuideEN
        self.formattedZH = formattedZH
        self.category = category
        self.language = language
        self.stars = stars
        self.isFork = isFork
        self.releaseTag = releaseTag
        self.releaseAssetName = releaseAssetName
        self.releaseAssetURL = releaseAssetURL
        self.hasDownloadAsset = hasDownloadAsset
        self.localPath = localPath
        self.previewImagePath = previewImagePath
        self.storageRootPath = storageRootPath
        self.infoFilePath = infoFilePath
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, owner, repo, projectName, sourceURL
        case descriptionEN, descriptionZH, summaryZH
        case releaseNotesEN, releaseNotesZH, setupGuideEN, formattedZH
        case category, language, stars, isFork
        case releaseTag, releaseAssetName, releaseAssetURL
        case hasDownloadAsset, localPath, previewImagePath, storageRootPath, infoFilePath
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decode(String.self, forKey: .id)
        owner = try c.decode(String.self, forKey: .owner)
        repo = try c.decode(String.self, forKey: .repo)
        projectName = try c.decode(String.self, forKey: .projectName)
        sourceURL = try c.decode(String.self, forKey: .sourceURL)

        descriptionEN = try c.decodeIfPresent(String.self, forKey: .descriptionEN) ?? ""
        descriptionZH = try c.decodeIfPresent(String.self, forKey: .descriptionZH) ?? ""
        summaryZH = try c.decodeIfPresent(String.self, forKey: .summaryZH) ?? ""

        releaseNotesEN = try c.decodeIfPresent(String.self, forKey: .releaseNotesEN) ?? ""
        releaseNotesZH = try c.decodeIfPresent(String.self, forKey: .releaseNotesZH) ?? ""
        setupGuideEN = try c.decodeIfPresent(String.self, forKey: .setupGuideEN) ?? ""
        formattedZH = try c.decodeIfPresent(String.self, forKey: .formattedZH) ?? ""

        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "未分类"
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "Unknown"
        stars = try c.decodeIfPresent(Int.self, forKey: .stars) ?? 0
        isFork = try c.decodeIfPresent(Bool.self, forKey: .isFork) ?? false

        releaseTag = try c.decodeIfPresent(String.self, forKey: .releaseTag) ?? "N/A"
        releaseAssetName = try c.decodeIfPresent(String.self, forKey: .releaseAssetName) ?? "无安装包"
        releaseAssetURL = try c.decodeIfPresent(String.self, forKey: .releaseAssetURL) ?? ""

        localPath = try c.decodeIfPresent(String.self, forKey: .localPath) ?? ""
        hasDownloadAsset = try c.decodeIfPresent(Bool.self, forKey: .hasDownloadAsset) ?? !localPath.isEmpty
        previewImagePath = try c.decodeIfPresent(String.self, forKey: .previewImagePath) ?? ""
        storageRootPath = try c.decodeIfPresent(String.self, forKey: .storageRootPath) ?? ""
        infoFilePath = try c.decodeIfPresent(String.self, forKey: .infoFilePath) ?? ""

        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

struct RepoDraft {
    let identity: RepoIdentity
    let projectName: String
    let sourceURL: URL

    let descriptionEN: String
    let descriptionZH: String
    let summaryZH: String

    let releaseNotesEN: String
    let releaseNotesZH: String
    let setupGuideEN: String
    let formattedZH: String

    let category: String
    let language: String
    let stars: Int
    let isFork: Bool

    let releaseTag: String
    let releaseAssetName: String
    let releaseAssetURL: String

    let hasDownloadAsset: Bool
    let localPath: String
    let previewImagePath: String
}

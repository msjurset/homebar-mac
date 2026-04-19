import Foundation

struct HAArea: Identifiable, Equatable, Sendable, Codable {
    let areaID: String
    let name: String

    var id: String { areaID }

    enum CodingKeys: String, CodingKey {
        case areaID = "area_id"
        case name
    }
}

import SwiftUI

struct ThirdPartyLicense: Identifiable {
    let name: String
    let license: String
    let url: URL?
    let purpose: String

    var id: String {
        name
    }
}

extension ThirdPartyLicense {
    static func loadAll(from bundle: Bundle = .main) -> [ThirdPartyLicense] {
        guard let url = bundle.url(forResource: "ThirdPartyLicenses", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: String]]
        else { return [] }

        return entries.compactMap { dict in
            guard let name = dict["name"],
                  let license = dict["license"],
                  let purpose = dict["purpose"]
            else { return nil }
            return ThirdPartyLicense(
                name: name,
                license: license,
                url: dict["url"].flatMap(URL.init(string:)),
                purpose: purpose
            )
        }
    }
}

struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    private let licenses = ThirdPartyLicense.loadAll()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Third-Party Licenses")
                .font(.headline)
                .padding()

            if licenses.isEmpty {
                Text("No third-party licenses found.")
                    .foregroundStyle(.readableSecondary)
                    .padding()
            } else {
                List(licenses) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.name).fontWeight(.medium)
                            Spacer()
                            Text(entry.license)
                                .font(.caption)
                                .foregroundStyle(.readableSecondary)
                        }
                        Text(entry.purpose)
                            .font(.caption)
                            .foregroundStyle(.readableSecondary)
                        if let link = entry.url {
                            Link("View on GitHub", destination: link)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 480, height: 400)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

import ShazamKit

class ShazamCatalogManager {
    private var catalog = SHCustomCatalog()
    
    func loadCatalog() async throws {
        guard let signatureURL = Bundle.main.url(
            forResource: "KING_OF_THE_PECOS_signature",
            withExtension: "shazamsignature"
        ) else {
            throw NSError(domain: "FileNotFound", code: 404)
        }

        do {
            let signatureData = try Data(contentsOf: signatureURL)
            let signature = try SHSignature(dataRepresentation: signatureData)

            let mediaItem = SHMediaItem(properties: [
                SHMediaItemProperty.title: "Your Audio Title",
                SHMediaItemProperty.artist: "Artist Name"
            ])

            try catalog.addReferenceSignature(signature, representing: [mediaItem])
            print("✅ Catalog loaded with 1 signature")

        } catch {
            print("❌ Failed to load catalog: \(error.localizedDescription)")
            throw error
        }
    }
    
    func getCatalog() -> SHCustomCatalog {
        return catalog
    }
}

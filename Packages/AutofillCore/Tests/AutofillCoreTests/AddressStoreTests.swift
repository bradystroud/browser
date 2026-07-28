import XCTest
@testable import AutofillCore

final class AddressStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testStartsEmpty() {
        let store = AddressStore(profileDirectory: tempDirectory)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testSaveAndReload() {
        let store = AddressStore(profileDirectory: tempDirectory)
        let address = StoredAddress(
            fullName: "Ada Lovelace", streetAddress: "12 Analytical Engine Way",
            city: "London", state: "", postalCode: "SW1A 1AA", country: "United Kingdom",
            phone: "+44 20 7946 0958", email: "ada@example.com"
        )
        store.save(address)

        // A fresh instance reading the same directory should see the same
        // data -- proves this actually persisted to disk, not just an
        // in-memory array.
        let reloaded = AddressStore(profileDirectory: tempDirectory)
        XCTAssertEqual(reloaded.all(), [address])
    }

    func testSavingSameIdOverwrites() {
        let store = AddressStore(profileDirectory: tempDirectory)
        let id = UUID().uuidString
        store.save(StoredAddress(id: id, fullName: "Ada Lovelace", city: "London"))
        store.save(StoredAddress(id: id, fullName: "Ada Lovelace", city: "Manchester"))

        let all = store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.city, "Manchester")
    }

    func testDelete() {
        let store = AddressStore(profileDirectory: tempDirectory)
        let address = StoredAddress(fullName: "Ada Lovelace")
        store.save(address)
        store.delete(id: address.id)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testMultipleAddressesAreIndependent() {
        let store = AddressStore(profileDirectory: tempDirectory)
        store.save(StoredAddress(fullName: "Ada Lovelace"))
        store.save(StoredAddress(fullName: "Charles Babbage"))
        XCTAssertEqual(store.all().count, 2)
    }
}

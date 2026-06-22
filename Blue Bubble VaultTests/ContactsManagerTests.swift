import XCTest
@testable import Blue_Bubble_Vault

final class ContactsManagerTests: XCTestCase {
    func testUSPhoneWithCountryCodeMatchesLocalFormattedContactPhone() {
        let records = [
            ContactLookupRecord(
                displayName: "Synthetic Contact",
                phoneNumbers: ["(571) 495-9305"],
                emailAddresses: []
            )
        ]

        let resolvedName = ContactsManager.resolvedName(for: "+15714959305", in: records)

        XCTAssertEqual(resolvedName, "Synthetic Contact")
    }

    func testFormattedUSPhoneMatchesCompactLocalPhone() {
        let records = [
            ContactLookupRecord(
                displayName: "Synthetic Contact",
                phoneNumbers: ["5714959305"],
                emailAddresses: []
            )
        ]

        let resolvedName = ContactsManager.resolvedName(for: "+1 (571) 495-9305", in: records)

        XCTAssertEqual(resolvedName, "Synthetic Contact")
    }

    func testEmailMatchingIsCaseInsensitive() {
        let records = [
            ContactLookupRecord(
                displayName: "Synthetic Contact",
                phoneNumbers: [],
                emailAddresses: ["Person.Example@iCloud.com"]
            )
        ]

        let resolvedName = ContactsManager.resolvedName(for: "person.example@icloud.com", in: records)

        XCTAssertEqual(resolvedName, "Synthetic Contact")
    }

    func testUnrelatedPhoneNumbersDoNotMatch() {
        let records = [
            ContactLookupRecord(
                displayName: "Synthetic Contact",
                phoneNumbers: ["(571) 495-9305"],
                emailAddresses: []
            )
        ]

        let resolvedName = ContactsManager.resolvedName(for: "+12025550100", in: records)

        XCTAssertNil(resolvedName)
    }

    func testPhoneSearchCandidatesIncludeLocalAndCountryCodeForms() {
        let candidates = ContactsManager.phoneSearchCandidates(for: "+1 (571) 495-9305")

        XCTAssertTrue(candidates.contains("+1 (571) 495-9305"))
        XCTAssertTrue(candidates.contains("15714959305"))
        XCTAssertTrue(candidates.contains("+15714959305"))
        XCTAssertTrue(candidates.contains("5714959305"))
    }

    func testBulkResolutionMatchesOnlyIndexedHandles() {
        let records = [
            ContactLookupRecord(
                displayName: "Synthetic Contact",
                phoneNumbers: ["(571) 495-9305"],
                emailAddresses: ["Person.Example@iCloud.com"]
            )
        ]
        let index = ContactsManager.buildResolvedNameIndex(from: records)

        var handles = Set<String>()
        for suffix in 0..<500 {
            handles.insert("+1202555\(String(format: "%04d", suffix))")
        }
        handles.insert("+15714959305")
        handles.insert("person.example@icloud.com")

        let resolvedNames = ContactsManager.resolvedNames(for: handles, in: index)

        XCTAssertEqual(resolvedNames["+15714959305"], "Synthetic Contact")
        XCTAssertEqual(resolvedNames["person.example@icloud.com"], "Synthetic Contact")
        XCTAssertNil(resolvedNames["+12025550000"])
        XCTAssertEqual(resolvedNames.count, 2)
    }
}

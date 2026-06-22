import XCTest
@testable import Blue_Bubble_Vault

final class FDAPermissionManagerTests: XCTestCase {
    func testSystemApplicationsFolderIsStableForPrivacyPermissions() {
        let state = FDAPermissionManager.bundleLocationState(
            for: URL(fileURLWithPath: "/Applications/Blue Bubble Vault.app"),
            homeDirectory: URL(fileURLWithPath: "/Users/synthetic")
        )

        XCTAssertEqual(state, .applicationsFolder)
    }

    func testUserApplicationsFolderIsStableForPrivacyPermissions() {
        let state = FDAPermissionManager.bundleLocationState(
            for: URL(fileURLWithPath: "/Users/synthetic/Applications/Blue Bubble Vault.app"),
            homeDirectory: URL(fileURLWithPath: "/Users/synthetic")
        )

        XCTAssertEqual(state, .userApplicationsFolder)
    }

    func testTranslocatedAppLocationIsDetected() {
        let state = FDAPermissionManager.bundleLocationState(
            for: URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/Blue Bubble Vault.app"),
            homeDirectory: URL(fileURLWithPath: "/Users/synthetic")
        )

        XCTAssertEqual(state, .translocated)
    }

    func testBuildFolderLocationIsUnstableForPrivacyPermissions() {
        let state = FDAPermissionManager.bundleLocationState(
            for: URL(fileURLWithPath: "/Users/synthetic/Library/Developer/Xcode/DerivedData/Blue Bubble Vault.app"),
            homeDirectory: URL(fileURLWithPath: "/Users/synthetic")
        )

        XCTAssertEqual(state, .unstable)
    }
}

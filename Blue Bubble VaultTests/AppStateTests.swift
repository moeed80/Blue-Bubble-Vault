import XCTest
@testable import Blue_Bubble_Vault

final class AppStateTests: XCTestCase {
    func testContactSyncPreferenceRestoresOnlyWhenContactsAreAuthorized() {
        XCTAssertTrue(
            AppState.restoredContactSyncEnabled(
                savedPreference: true,
                authorizationState: .authorized
            )
        )

        XCTAssertFalse(
            AppState.restoredContactSyncEnabled(
                savedPreference: false,
                authorizationState: .authorized
            )
        )

        for state in [ContactsAuthorizationState.notDetermined, .denied, .restricted, .unknown] {
            XCTAssertFalse(
                AppState.restoredContactSyncEnabled(
                    savedPreference: true,
                    authorizationState: state
                )
            )
        }
    }
}

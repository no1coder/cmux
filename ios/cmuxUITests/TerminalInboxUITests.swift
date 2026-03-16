import XCTest

final class TerminalInboxUITests: XCTestCase {
    private enum Fixture {
        static let currentWorkspaceID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        static let olderWorkspaceID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testInboxFixtureShowsUnreadWorkspaceFirst() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_INBOX_FIXTURE"] = "1"
        app.launch()

        let home = app.otherElements["terminal.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 6), "Expected terminal home to appear")

        let currentWorkspace = app.buttons["terminal.workspace.\(Fixture.currentWorkspaceID)"]
        let olderWorkspace = app.buttons["terminal.workspace.\(Fixture.olderWorkspaceID)"]
        XCTAssertTrue(currentWorkspace.waitForExistence(timeout: 4), "Expected newer inbox workspace")
        XCTAssertTrue(olderWorkspace.waitForExistence(timeout: 4), "Expected older inbox workspace")
        XCTAssertLessThan(
            currentWorkspace.frame.minY,
            olderWorkspace.frame.minY,
            "Expected the newer unread workspace to sort ahead of the older workspace"
        )

        let unreadBadge = app.otherElements["terminal.workspace.unread.\(Fixture.currentWorkspaceID)"]
        XCTAssertTrue(unreadBadge.exists, "Expected unread badge on the newer workspace")
        XCTAssertFalse(
            app.otherElements["terminal.workspace.unread.\(Fixture.olderWorkspaceID)"].exists,
            "Expected older workspace to remain read"
        )

        XCTAssertEqual(
            app.staticTexts["terminal.workspace.status.\(Fixture.currentWorkspaceID)"].label,
            "Connected"
        )
        XCTAssertEqual(
            app.staticTexts["terminal.workspace.status.\(Fixture.olderWorkspaceID)"].label,
            "Disconnected"
        )
    }

    func testInboxFixtureSwipeUnreadMarksWorkspaceUnread() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_INBOX_FIXTURE"] = "1"
        app.launch()

        let olderWorkspace = app.buttons["terminal.workspace.\(Fixture.olderWorkspaceID)"]
        XCTAssertTrue(olderWorkspace.waitForExistence(timeout: 6), "Expected older workspace row")

        olderWorkspace.swipeRight()

        let toggleUnread = app.buttons["terminal.workspace.action.toggleUnread.\(Fixture.olderWorkspaceID)"]
        XCTAssertTrue(toggleUnread.waitForExistence(timeout: 2), "Expected unread swipe action")
        toggleUnread.tap()

        XCTAssertTrue(
            app.otherElements["terminal.workspace.unread.\(Fixture.olderWorkspaceID)"].waitForExistence(timeout: 2),
            "Expected unread badge after toggling unread"
        )
    }

    func testInboxFixtureSwipeDeleteRemovesWorkspace() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_INBOX_FIXTURE"] = "1"
        app.launch()

        let olderWorkspace = app.buttons["terminal.workspace.\(Fixture.olderWorkspaceID)"]
        XCTAssertTrue(olderWorkspace.waitForExistence(timeout: 6), "Expected older workspace row")

        olderWorkspace.swipeLeft()

        let deleteAction = app.buttons["terminal.workspace.action.delete.\(Fixture.olderWorkspaceID)"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 2), "Expected delete swipe action")
        deleteAction.tap()

        XCTAssertFalse(
            olderWorkspace.waitForExistence(timeout: 2),
            "Expected deleted workspace to disappear from the inbox"
        )
    }
}

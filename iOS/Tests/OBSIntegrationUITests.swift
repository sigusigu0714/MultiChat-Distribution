import XCTest

final class OBSIntegrationUITests: XCTestCase {
    func testChatOBSNavigationAndOfflineControls() {
        let app = XCUIApplication()
        app.launch()
        let setup = app.navigationBars["接続セットアップ"]
        if setup.waitForExistence(timeout: 5) {
            XCTAssertTrue(app.textFields["setup-server-url"].exists)
            XCTAssertFalse(app.buttons["save-connection-setup"].isEnabled)
            capture(app, "00-Blank-Connection-Setup")
            app.buttons["skip-connection-setup"].tap()
        }
        XCTAssertTrue(app.navigationBars["MultiChat"].waitForExistence(timeout: 15))
        capture(app, "01-MultiChat")
        app.navigationBars["MultiChat"].buttons["OBS"].tap()
        XCTAssertTrue(app.navigationBars["OBS Remote"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OBS管理者設定が必要です"].firstMatch.exists)
        capture(app, "02-OBS-Unconfigured")
        app.buttons["obs-settings"].tap()
        XCTAssertTrue(app.navigationBars["OBS管理者設定"].waitForExistence(timeout: 5))
        let url = app.textFields["obs-server-url"]
        XCTAssertEqual(url.value as? String, "WSSサーバーURL")
        url.tap()
        url.press(forDuration: 1.2)
        // Replace the default endpoint without contacting the live relay.
        if app.menuItems["Select All"].exists { app.menuItems["Select All"].tap() }
        else if app.menuItems["すべてを選択"].exists { app.menuItems["すべてを選択"].tap() }
        else {
            let current = url.value as? String ?? ""
            url.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        url.typeText("wss://example.invalid/obsremote/ws")
        let token = app.secureTextFields["OBS操作用トークン"]
        token.tap()
        token.typeText("simulator-test-only-token")
        app.buttons["保存して接続"].tap()
        XCTAssertTrue(app.buttons["Twitch !fix"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["KICK !fix"].exists)
        XCTAssertFalse(app.buttons["Twitch !fix"].isEnabled)
        XCTAssertFalse(app.buttons["KICK !fix"].isEnabled)
        XCTAssertFalse(app.buttons["配信を開始"].isEnabled)
        XCTAssertTrue(app.staticTexts["状態不明"].exists)
        capture(app, "03-OBS-Offline-Controls")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
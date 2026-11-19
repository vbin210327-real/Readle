import XCTest

final class ReadleUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func openSample() {
        let title = app.staticTexts["清晨的旧书店"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        title.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    private func showReaderControls() {
        // Refresh the three-second window even if a preceding swipe left the bars visible.
        app.scrollViews["readerScroll"].coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.5)).tap()
        if !app.buttons["readerBack"].exists {
            app.scrollViews["readerScroll"].coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["readerBack"].waitForExistence(timeout: 3), app.debugDescription)
    }

    func testHeartSentenceAndWordReadAloud() {
        app.terminate()
        app.launchArguments = ["-ReadleVerifySpeech"]
        app.launch()
        let title = app.staticTexts["Readle双向验证"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap()
        let body = app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.1)).press(forDuration: 0.7)
        let word = app.buttons["speak-word"]
        XCTAssertTrue(word.waitForExistence(timeout: 10))
        word.tap()
        let download = app.buttons["下载并朗读"]
        if download.exists { download.tap() }
        let status = app.descendants(matching: .any).matching(identifier: "speechStatus").firstMatch
        let playing = NSPredicate(format: "label == %@", "正在朗读")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: status)], timeout: 300), .completed, app.debugDescription)
        screenshot("23-heart-word-read-aloud")
        if word.label == "停止朗读" { word.tap() }
        app.buttons["关闭释义"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap()
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.1)).tap()
        let original = app.buttons["speak-sentence-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        original.tap()
        XCTAssertFalse(download.exists, "Installed Heart must not download again")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: status)], timeout: 45), .completed, app.debugDescription)
        screenshot("24-heart-sentence-read-aloud")
        let translated = app.buttons["speak-sentence-translation"]
        XCTAssertEqual(translated.value as? String, "中文系统声音")
        if original.label == "停止朗读" { original.tap() }
        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
        original.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: status)], timeout: 45), .completed, app.debugDescription)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(status.waitForNonExistence(timeout: 5), "Leaving the app must stop read-aloud")
    }

    func testBilingualSentenceAndWordUX() {
        let title = app.staticTexts["Readle双向验证"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        let body = app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.1)).press(forDuration: 0.7)
        XCTAssertTrue(app.staticTexts["wordMeaning"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["lookupWord"].label, "Raindrops")
        app.buttons["关闭释义"].tap()
        XCTAssertFalse(app.staticTexts["translationResult"].exists, "Long press must not trigger sentence translation")
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.1)).tap()
        let result = app.staticTexts["translationResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "雨珠覆盖了树叶。")
        let y = body.frame.minY
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.1)).press(forDuration: 0.7)
        XCTAssertTrue(app.staticTexts["wordMeaning"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["lookupWord"].label, "Raindrops")
        XCTAssertTrue(app.staticTexts["wordMeaning"].label.contains("雨滴"))
        screenshot("22-word-meaning-card")
        app.buttons["关闭释义"].tap()
        XCTAssertEqual(body.frame.minY, y, accuracy: 2)
        XCTAssertEqual(result.label, "雨珠覆盖了树叶。")
        // English text always translates to Chinese; no direction to choose.
        app.terminate(); app.launch(); title.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "雨珠覆盖了树叶。")
        screenshot("21-bilingual-word-ux")
    }

    private func openPositionBook() {
        let book = app.staticTexts["Readle定位验证"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10), app.debugDescription)
        book.tap()
        XCTAssertTrue(app.scrollViews["readerScroll"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.scrollViews["readerScroll"].label, "Readle定位验证")
    }

    func testTranslationStaysBelowSelectedSentenceAndRestoresContinuation() {
        let title = app.staticTexts["Readle译文验证"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        let scroll = app.scrollViews["readerScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["readerBack"].waitForNonExistence(timeout: 6))
        func fragment(_ suffix: String = "") -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "paragraph-0" + suffix).firstMatch
        }
        func text(_ element: XCUIElement) -> String {
            if let value = element.value as? String, !value.isEmpty { return value }
            return element.label
        }
        let result = app.staticTexts["translationResult"]
        func check(_ expected: String, continuation: String?) {
            XCTAssertTrue(result.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(result.label, expected)
            let prefix = fragment()
            XCTAssertGreaterThanOrEqual(result.frame.minY, prefix.frame.maxY, "Translation must follow the selected sentence")
            XCTAssertLessThan(result.frame.minY - prefix.frame.maxY, 90)
            if let continuation {
                let suffix = fragment("-continuation")
                XCTAssertTrue(suffix.exists, app.debugDescription)
                XCTAssertEqual(text(suffix), continuation)
                XCTAssertGreaterThan(suffix.frame.minY, result.frame.maxY, "Remaining original text must follow the translation")
            } else {
                XCTAssertFalse(fragment("-continuation").exists)
            }
        }
        // First sentence: the translation cannot drop below the other three sentences.
        fragment().coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.08)).tap()
        check("The rain outside the window has stopped.", continuation: "院子里的树叶还挂着水珠。我们准备沿着河岸慢慢走。远处的小桥在晨光中亮起来。")
        XCTAssertEqual(text(fragment()), "窗外的雨停了。")
        // Select the next sentence in the continuation; preserve all original text exactly once.
        fragment("-continuation").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.06)).tap()
        check("Raindrops still cling to the leaves in the courtyard.", continuation: "我们准备沿着河岸慢慢走。远处的小桥在晨光中亮起来。")
        XCTAssertEqual(text(fragment()), "窗外的雨停了。院子里的树叶还挂着水珠。")
        screenshot("19-inline-middle-sentence")
        fragment("-continuation").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.85)).tap()
        check("The little bridge in the distance glows in the morning light.", continuation: nil)
        XCTAssertEqual(text(fragment()), "窗外的雨停了。院子里的树叶还挂着水珠。我们准备沿着河岸慢慢走。远处的小桥在晨光中亮起来。")
        // Move the panel back to the second sentence, then leave while its continuation is visible.
        fragment().coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.1)).tap()
        check("Raindrops still cling to the leaves in the courtyard.", continuation: "我们准备沿着河岸慢慢走。远处的小桥在晨光中亮起来。")
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        showReaderControls()
        let expectedY = fragment("-continuation").frame.minY
        app.buttons["readerBack"].tap()
        title.tap()
        XCTAssertTrue(fragment("-continuation").waitForExistence(timeout: 10))
        XCTAssertEqual(fragment("-continuation").frame.minY, expectedY, accuracy: 5)
        app.terminate(); app.launch(); title.tap()
        XCTAssertTrue(fragment("-continuation").waitForExistence(timeout: 10))
        XCTAssertEqual(fragment("-continuation").frame.minY, expectedY, accuracy: 5)
        XCTAssertEqual(result.label, "Raindrops still cling to the leaves in the courtyard.")
        screenshot("20-inline-continuation-restored")
    }

    func testScrollPositionRestoresWithoutTranslation() {
        openPositionBook()
        showReaderControls()
        app.buttons["章节目录"].tap()
        let second = app.buttons.containing(.staticText, identifier: "第二节 · 定位测试").firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5), app.debugDescription)
        second.tap()
        let scroll = app.scrollViews["readerScroll"]
        for _ in 0..<5 { scroll.swipeUp(velocity: .slow) }
        showReaderControls()
        let visible = app.textViews.allElementsBoundByIndex.filter {
            $0.identifier.hasPrefix("paragraph-") && $0.frame.minY > scroll.frame.minY + 75 && $0.frame.minY < scroll.frame.maxY - 100
        }
        guard let anchor = visible.first else { XCTFail(app.debugDescription); return }
        let identifier = anchor.identifier
        let expectedY = anchor.frame.minY
        XCTAssertTrue((anchor.value as? String)?.contains("第2节") == true)
        screenshot("14-position-before-exit")
        showReaderControls()
        app.buttons["readerBack"].tap()
        openPositionBook()
        let restored = app.textViews[identifier]
        XCTAssertTrue(restored.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(restored.frame.minY, expectedY, accuracy: 5, "Reopening must restore the actual scroll offset in the second chapter")
        screenshot("15-position-restored")
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launch()
        openPositionBook()
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(restored.frame.minY, expectedY, accuracy: 5, "Position must survive backgrounding and process restart")
        screenshot("16-position-after-relaunch")
    }

    func testImmersionBlankTapAndAutoHideKeepPosition() {
        openPositionBook()
        showReaderControls()
        let scroll = app.scrollViews["readerScroll"]
        let body = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "paragraph-")).firstMatch
        let before = body.frame.minY
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["readerBack"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.otherElements["readerProgress"].exists)
        XCTAssertEqual(body.frame.minY, before, accuracy: 1, "Hiding toolbars must not move the text")
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["readerBack"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["readerProgress"].exists)
        XCTAssertEqual(body.frame.minY, before, accuracy: 1)
        XCTAssertTrue(app.buttons["readerBack"].waitForNonExistence(timeout: 6), "Chrome should hide automatically after three seconds")
        XCTAssertFalse(app.otherElements["readerProgress"].exists)
        XCTAssertEqual(body.frame.minY, before, accuracy: 1)
        screenshot("17-immersive-reading")
    }

    func testImmersiveSentenceTapStillTranslates() {
        openSample()
        XCTAssertTrue(app.buttons["readerBack"].waitForNonExistence(timeout: 6))
        let paragraph = app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.14)).tap()
        let result = app.staticTexts["translationResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(result.label.lowercased().contains("dawn") || result.label.lowercased().contains("morning") || result.label.lowercased().contains("daybreak"), result.label)
        XCTAssertFalse(app.buttons["readerBack"].exists, "Tapping a sentence must not count as a blank-space tap")
        screenshot("18-immersive-sentence-translation")
    }

    func testSentenceTranslationCacheAndResume() {
        screenshot("01-library")
        openSample()
        let paragraph = app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.14)).tap()
        let result = app.staticTexts["translationResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(result.label.lowercased().contains("dawn") || result.label.lowercased().contains("morning") || result.label.lowercased().contains("daybreak"), result.label)
        screenshot("02-chinese-to-english")
        app.terminate()
        app.launch()
        openSample()
        XCTAssertTrue(result.waitForExistence(timeout: 5), "Cached translation and reading position should restore")
        screenshot("03-restored-translation")
    }

    func testRapidSelectionUsesCurrentSentence() {
        openSample()
        let first = app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.14)).tap()
        let continuation = app.descendants(matching: .any).matching(identifier: "paragraph-0-continuation").firstMatch
        XCTAssertTrue(continuation.waitForExistence(timeout: 5))
        continuation.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).tap()
        let result = app.staticTexts["translationResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(result.label.lowercased().contains("rain") || result.label.lowercased().contains("droplet"), result.label)
        screenshot("04-current-sentence")
    }

    func testFilePickerAndChapterNavigation() {
        let importButton = app.buttons["importBook"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        screenshot("05-file-importer")
        app.terminate(); app.launch()
        openSample()
        showReaderControls()
        app.buttons["章节目录"].tap()
        XCTAssertTrue(app.navigationBars["章节目录"].waitForExistence(timeout: 5))
        screenshot("06-chapter-list")
        app.buttons["完成"].tap()
        app.buttons["阅读字号"].tap()
        let larger = app.buttons["放大字号"]
        XCTAssertTrue(larger.waitForExistence(timeout: 5), app.debugDescription)
        larger.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch.exists)
    }

    func testImportTXTThroughFiles() {
        app.buttons["importBook"].tap()
        let browse = app.tabBars.buttons["浏览"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
        browse.tap()
        let file = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Readle导入验证,")).firstMatch
        if !file.waitForExistence(timeout: 5) {
            if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
            let local = app.staticTexts["我的iPhone"]
            XCTAssertTrue(local.waitForExistence(timeout: 10), app.debugDescription)
            local.tap()
            let folder = app.cells["Readle, Container"]
            XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
            folder.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        file.tap()
        XCTAssertTrue(app.scrollViews["readerScroll"].waitForExistence(timeout: 10), app.debugDescription)
        let paragraph = app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        let result = app.staticTexts["translationResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(result.label.lowercased().contains("river"), result.label)
        screenshot("07-imported-book-translation")
    }

    func testShareTXTFromFiles() {
        tryShareFromFiles(filename: "Readle分享验证", title: "Readle分享验证", warm: false)
        let paragraph = app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
        let result = app.staticTexts["translationResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(result.label.lowercased().contains("river"), result.label)
        screenshot("09-shared-book-translation")
    }

    func testShareEPUBFromFilesWhileAppInBackground() {
        tryShareFromFiles(filename: "ReadleEPUB分享验证", title: "ReadleEPUB分享验证", warm: true)
        let body = app.descendants(matching: .any).matching(identifier: "paragraph-1").firstMatch
        XCTAssertEqual(body.label, "我们沿着河岸慢慢向前走。")
        screenshot("10-shared-epub")
    }

    func testSharePDFFromFiles() {
        tryShareFromFiles(filename: "ReadlePDF分享验证", title: "ReadlePDF分享验证", warm: false)
        XCTAssertTrue((app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch.value as? String)?.contains("river") == true, app.debugDescription)
        screenshot("11-shared-pdf")
    }

    func testShareMOBIFromFilesAndTranslate() {
        tryShareFromFiles(filename: "ReadleMOBI分享验证", title: "ReadleMOBI分享验证", warm: false)
        let paragraph = app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch
        XCTAssertTrue((paragraph.value as? String)?.contains("我们沿着河岸慢慢向前走。") == true, app.debugDescription)
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
        let result = app.staticTexts["translationResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(result.label.lowercased().contains("river"), result.label)
        screenshot("12-shared-mobi-translation")
    }

    func testImportMOBIThroughFilePicker() {
        app.buttons["importBook"].tap()
        let browse = app.tabBars.buttons["浏览"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
        browse.tap()
        let file = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ReadleMOBI选择验证")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap() }
            let local = app.staticTexts["我的iPhone"]
            XCTAssertTrue(local.waitForExistence(timeout: 10), app.debugDescription)
            local.tap()
            let folder = app.cells["Readle, Container"]
            XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
            folder.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(file.isEnabled, "MOBI must be selectable, not grayed out")
        file.tap()
        XCTAssertTrue(app.scrollViews["readerScroll"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.scrollViews["readerScroll"].label, "ReadleMOBI选择验证")
        let paragraph = app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        XCTAssertTrue((paragraph.value as? String)?.contains("中文电子书也可以直接导入。") == true)
        screenshot("13-mobi-file-picker-import")
    }

    private func tryShareFromFiles(filename: String, title: String, warm: Bool) {
        if !warm { app.terminate() }
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.terminate()
        files.launch()
        let browse = files.tabBars.buttons["浏览"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10), files.debugDescription)
        browse.tap()
        let file = files.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", filename)).firstMatch
        if !file.waitForExistence(timeout: 3) {
            if files.buttons["BackButton"].exists { files.buttons["BackButton"].tap() }
            let local = files.staticTexts["我的iPhone"]
            XCTAssertTrue(local.waitForExistence(timeout: 10), files.debugDescription)
            local.tap()
            let folder = files.cells["Readle, Container"]
            XCTAssertTrue(folder.waitForExistence(timeout: 10), files.debugDescription)
            folder.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), files.debugDescription)
        files.navigationBars.buttons["OverflowBarButtonItem"].tap()
        let select = files.buttons["选择"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5), files.debugDescription)
        select.tap()
        file.tap()
        let share = files.buttons["共享"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5), files.debugDescription)
        share.tap()
        let shortcut = files.cells.matching(NSPredicate(format: "label == %@ OR label == %@", "导入 Readle", "Readle")).firstMatch
        if !shortcut.waitForExistence(timeout: 5) {
            let more = files.collectionViews.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "更多")).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5), files.debugDescription)
            more.tap()
        }
        let fullListShortcut = files.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "导入 Readle", "Readle")).firstMatch
        if shortcut.exists { shortcut.tap() }
        else {
            XCTAssertTrue(fullListShortcut.waitForExistence(timeout: 10), files.debugDescription)
            fullListShortcut.tap()
        }
        XCTAssertTrue(files.staticTexts["已保存到 Readle"].waitForExistence(timeout: 15), files.debugDescription)
        let receipt = XCTAttachment(screenshot: files.screenshot())
        receipt.name = "08-share-saved"; receipt.lifetime = .keepAlways; add(receipt)
        files.buttons["readleShareDone"].tap()
        if warm { app.activate() } else { app.launch() }
        XCTAssertTrue(app.scrollViews["readerScroll"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.scrollViews["readerScroll"].label, title)
        let paragraph = app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
    }
}

import StoreKitTest

final class MembershipUITests: XCTestCase {
    @MainActor
    func testFreeTranslationLimitKeepsCachedResultsReadable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-readle.translation.freeUses", "100"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Readle双向验证")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 12))
        book.tap()

        let first = app.descendants(matching: .any).matching(identifier: "paragraph-0").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.32)).press(forDuration: 0.7)
        XCTAssertTrue(app.staticTexts["sentenceTranslation"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sentenceTranslation"].label, "雨珠覆盖了树叶。")

        let next = app.descendants(matching: .any).matching(identifier: "paragraph-0-continuation").firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.55)).press(forDuration: 0.7)
        let translate = app.buttons["translateSentence"]
        XCTAssertTrue(translate.waitForExistence(timeout: 5))
        XCTAssertEqual(translate.label, "升级解锁翻译")
        translate.tap()
        XCTAssertTrue(app.buttons["恢复购买"].waitForExistence(timeout: 8))
        app.buttons["完成"].tap()

        first.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.32)).tap()
        XCTAssertTrue(app.buttons["恢复购买"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testFreeShelfAndPaywall() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.scrollViews["flatShelf"].waitForExistence(timeout: 15))
        app.buttons["searchBooks"].tap()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 6))
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchResult-")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 6))
        result.tap()
        XCTAssertTrue(app.buttons["theaterOpenTop"].waitForExistence(timeout: 8))
        app.buttons["theaterOpenTop"].tap()
        XCTAssertTrue(app.buttons["恢复购买"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["解锁句读院高级版"].exists)
        XCTAssertFalse(app.staticTexts["让每一本书，值得慢慢读。"].exists)
        app.swipeUp()
        let privacy = app.descendants(matching: .any).matching(identifier: "readlePrivacyPolicy").firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPurchasesAndLapse() async throws {
        continueAfterFailure = false
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Readle-CN", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let app = XCUIApplication()
        app.launch()
        let flat = app.scrollViews["flatShelf"]
        XCTAssertTrue(flat.waitForExistence(timeout: 15))
        let monthly = "com.linfanbin.readle.pro.monthly"
        _ = try await session.buyProduct(identifier: monthly)
        XCTAssertTrue(flat.waitForNonExistence(timeout: 20))
        try session.expireSubscription(productIdentifier: monthly)
        XCTAssertTrue(flat.waitForExistence(timeout: 20))

        let expired = app.staticTexts["高级版订阅已到期"]
        XCTAssertFalse(expired.exists)
        app.buttons["locked3DShelf"].tap()
        XCTAssertTrue(expired.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["renewPlan-monthly"].isSelected)
        app.buttons["关闭"].tap()

        app.buttons["searchBooks"].tap()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchResult-")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        book.tap()
        let reader = app.scrollViews["readerScroll"]
        XCTAssertTrue(reader.waitForExistence(timeout: 8))
        let theater = app.buttons["theaterOpenTop"]
        if !theater.exists { reader.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.5)).tap() }
        XCTAssertTrue(theater.waitForExistence(timeout: 3))
        theater.tap()
        XCTAssertTrue(expired.waitForExistence(timeout: 8))
        app.buttons["关闭"].tap()
        let listening = app.buttons["listenBook"]
        if !listening.exists { reader.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.5)).tap() }
        XCTAssertTrue(listening.waitForExistence(timeout: 3))
        listening.tap()
        XCTAssertTrue(expired.waitForExistence(timeout: 8))
        app.buttons["renewPlan-yearly"].tap()
        let renew = app.buttons["renewSubscription"]
        XCTAssertTrue(renew.isEnabled)
        renew.tap()
        XCTAssertTrue(expired.waitForNonExistence(timeout: 15))

        let yearly = "com.linfanbin.readle.pro.yearly"
        try session.expireSubscription(productIdentifier: yearly)
        app.terminate()
        app.launch()
        XCTAssertTrue(flat.waitForExistence(timeout: 15))
        app.buttons["locked3DShelf"].tap()
        XCTAssertTrue(expired.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["renewPlan-yearly"].isSelected)
        app.buttons["关闭"].tap()

        let lifetime = try await session.buyProduct(identifier: "com.linfanbin.readle.pro.lifetime")
        XCTAssertTrue(flat.waitForNonExistence(timeout: 20))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["membership"].waitForExistence(timeout: 15))
        XCTAssertFalse(flat.exists)
        try session.refundTransaction(identifier: UInt(lifetime.id))
        XCTAssertTrue(flat.waitForExistence(timeout: 20))
    }
}

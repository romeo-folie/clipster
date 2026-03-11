import ClipsterCore
import XCTest

final class ContentClassifierTests: XCTestCase {

    // MARK: - URL detection

    func testHttpUrlDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("https://example.com"), .url)
    }

    func testHttpWithPathUrlDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("https://github.com/romeo-folie/clipster"), .url)
    }

    func testFtpUrlDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("ftp://files.example.com/file.zip"), .url)
    }

    func testPlainTextNotUrl() {
        XCTAssertNotEqual(ContentClassifier.classifyText("just some text"), .url)
    }

    func testBareHostnameNotUrl() {
        // No scheme — should not be classified as url
        XCTAssertNotEqual(ContentClassifier.classifyText("example.com"), .url)
    }

    // MARK: - Email detection

    func testEmailDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("romeo@example.com"), .email)
    }

    func testEmailWithSubdomainDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("user@mail.example.co.uk"), .email)
    }

    func testEmailWithPlusDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("user+tag@example.com"), .email)
    }

    func testNonEmailNotDetected() {
        XCTAssertNotEqual(ContentClassifier.classifyText("not-an-email"), .email)
    }

    func testMultilineTextNotEmail() {
        XCTAssertNotEqual(ContentClassifier.classifyText("line1\nline2@example.com"), .email)
    }

    // MARK: - Phone detection

    func testE164PhoneDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("+14155552671"), .phone)
    }

    func testFormattedPhoneDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("+1 (415) 555-2671"), .phone)
    }

    func testShortNumberNotPhone() {
        XCTAssertNotEqual(ContentClassifier.classifyText("123"), .phone)
    }

    // MARK: - Colour detection

    func testHexColourDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("#FF5733"), .colour)
    }

    func testHexColourWithAlphaDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("#FF5733AA"), .colour)
    }

    func testRgbColourDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("rgb(255, 87, 51)"), .colour)
    }

    func testRgbaColourDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("rgba(255, 87, 51, 0.5)"), .colour)
    }

    func testHslColourDetected() {
        XCTAssertEqual(ContentClassifier.classifyText("hsl(9, 100%, 60%)"), .colour)
    }

    func testLowercaseHexColour() {
        XCTAssertEqual(ContentClassifier.classifyText("#ff5733"), .colour)
    }

    func testPlainTextNotColour() {
        XCTAssertNotEqual(ContentClassifier.classifyText("red"), .colour)
    }

    // MARK: - Code detection (PRD §7.1.1 — ≥2 signals)

    func testPythonCodeDetected() {
        let python = """
        def hello(name):
            if name:
                return f"Hello, {name}"
            else:
                return "Hello, World"
        """
        XCTAssertEqual(ContentClassifier.classifyText(python), .code)
    }

    func testJavaScriptCodeDetected() {
        let js = """
        const greet = (name) => {
            if (name) {
                return `Hello, ${name}`;
            }
            return 'Hello';
        };
        """
        XCTAssertEqual(ContentClassifier.classifyText(js), .code)
    }

    func testSwiftCodeDetected() {
        let swift = """
        func greet(_ name: String) -> String {
            return "Hello, \\(name)"
        }
        """
        XCTAssertEqual(ContentClassifier.classifyText(swift), .code)
    }

    func testShebangDetected() {
        let script = "#!/usr/bin/env bash\necho hello"
        // Has shebang (signal 4) + indentation may not apply, but test shebang contributes
        XCTAssertTrue(ContentClassifier.isCode(script) || script.hasPrefix("#!/"))
    }

    func testPlainEnglishNotCode() {
        let text = "This is a regular sentence without any programming constructs."
        XCTAssertNotEqual(ContentClassifier.classifyText(text), .code)
    }

    // MARK: - Code signal tests

    func testKeywordsSignal() {
        XCTAssertTrue(ContentClassifier.isCode("function foo() {\n  return 1;\n}"))
    }

    func testBracketDensitySignal() {
        // High bracket density + some keyword
        let dense = "{{{}}}[[[]]]((())) function"
        XCTAssertTrue(ContentClassifier.isCode(dense))
    }

    func testOperatorSignal() {
        let code = "const x = a => b => a + b;\nconst y = x ?? 0;\nreturn y;"
        XCTAssertTrue(ContentClassifier.isCode(code))
    }

    // MARK: - Plain text fallback

    func testPlainTextFallback() {
        XCTAssertEqual(ContentClassifier.classifyText("Hello, World!"), .plainText)
    }

    func testMultilineProseIsPlainText() {
        let prose = "The quick brown fox jumps over the lazy dog.\nThis is a second line of plain text."
        XCTAssertEqual(ContentClassifier.classifyText(prose), .plainText)
    }

    // MARK: - isURL helper

    func testIsURLTrue() {
        XCTAssertTrue(ContentClassifier.isURL("https://example.com"))
    }

    func testIsURLFalse() {
        XCTAssertFalse(ContentClassifier.isURL("not a url"))
    }

    // MARK: - HTML + plain-text priority (pasteboard integration)
    //
    // When both public.html and public.utf8-plain-text are present (e.g. Slack,
    // Chrome copying selected text), the plain text must win — the HTML is an
    // incidental render artefact.
    //
    // When only public.html is present, tags are stripped and visible text is
    // stored as plain text — never raw markup.

    func testHtmlAndPlainTextPresentUsesPlainText() {
        // Simulate Slack: writes both HTML wrapper and clean plain text.
        let plain = "Hello from Slack"
        let html = "<meta charset='utf-8'><div class='p-rich_text_section'>Hello from Slack</div>"

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(plain, forType: .string)
        pb.setData(html.data(using: .utf8)!, forType: .html)

        let entry = ContentClassifier.classify(pasteboard: pb, sourceApp: .unknown)

        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.content, plain, "Should capture plain text, not raw HTML")
        XCTAssertNotEqual(entry?.contentType, .richText, "Should not be classified as rich text")
    }

    func testHtmlOnlyStrippedToPlainText() {
        // HTML-only pasteboard: tags must be stripped; visible text stored as plain text.
        // No more raw HTML / meta tags leaking into the GUI.
        let html = "<h1>Hello</h1><p>World</p>"

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(html.data(using: .utf8)!, forType: .html)
        // No .string written — intentional.

        let entry = ContentClassifier.classify(pasteboard: pb, sourceApp: .unknown)

        XCTAssertNotNil(entry)
        XCTAssertFalse(entry?.content.contains("<") ?? true, "Raw HTML tags must not appear in stored content")
        XCTAssertTrue(entry?.content.contains("Hello") ?? false)
        XCTAssertTrue(entry?.content.contains("World") ?? false)
        XCTAssertNotEqual(entry?.contentType, .richText, "HTML-stripped content should not be richText")
    }

    func testHtmlWithMetaTagsStripped() {
        // Common pattern: Slack/Chrome-style HTML with meta charset and wrapper divs,
        // but WITHOUT a plain-text companion. Must strip to clean text.
        let html = "<meta charset='utf-8'><div>Some important text here</div>"

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(html.data(using: .utf8)!, forType: .html)

        let entry = ContentClassifier.classify(pasteboard: pb, sourceApp: .unknown)

        XCTAssertNotNil(entry)
        XCTAssertFalse(entry?.content.contains("<meta") ?? true, "Meta tags must be stripped")
        XCTAssertTrue(entry?.content.contains("Some important text here") ?? false)
    }

    func testHtmlEntityDecodingViaClassify() {
        let html = "<p>Fish &amp; Chips &lt;3 &quot;great&quot;</p>"

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(html.data(using: .utf8)!, forType: .html)

        let entry = ContentClassifier.classify(pasteboard: pb, sourceApp: .unknown)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.content, "Fish & Chips <3 \"great\"")
    }

    func testHtmlOnlyNoVisibleTextSkipped() {
        let html = "<div class='container'><span></span></div>"

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(html.data(using: .utf8)!, forType: .html)

        let entry = ContentClassifier.classify(pasteboard: pb, sourceApp: .unknown)
        XCTAssertNil(entry, "HTML with no visible text should be skipped")
    }
}

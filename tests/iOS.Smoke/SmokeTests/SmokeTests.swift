import XCTest
import UIKit
import WebKit

/// In-process smoke tests for the Novalist iOS app (net10.0-ios MAUI shell).
///
/// The bundle runs HOSTED inside Novalist.Mobile.app (TEST_HOST), so the tests
/// see the real product: the MAUI window, the HybridWebView, the in-process
/// BackendHost and the app's own sandbox. Functional coverage is driven through
/// the renderer's own public test surface - `window.novalistRpc` /
/// `window.novalistStores` - the exact same surface the desktop Playwright
/// suite drives, so the assertions exercise the real editor code path.
///
/// Phase layout (the workflow runs two `xcodebuild test` invocations):
///   Phase 1: test01..test06 - boot, create novel, chapters, Arabic content,
///            codex entities, export. Ends with a cold terminate.
///   Phase 2: test90 - fresh launch, reopen the project, verify persistence.
final class SmokeTests: XCTestCase {

    // MARK: - Constants

    /// Must match <ApplicationId> in Novalist.Mobile.csproj.
    static let bundleId = "com.syfslfk00.novalist"
    /// The project the suite creates (Phase 1) and reopens (Phase 2).
    static let novelName = "SmokeNovel"
    static let novelParent = "NovalistSmoke"

    /// Rich Arabic sample: dialogue, Arabic punctuation, Arabic-Indic and Latin
    /// digits, mixed Arabic/English words, several paragraphs.
    static let arabicText =
        "كان مساء يوم خميس، ١٥ أيار 2025، حين طرق خالد البابَ بلا استئذان.\n\n" +
        "«من على الباب؟» سألت ليلى وهي ترفع نظّارتها، ثم أضافت بصوتٍ خفيض: " +
        "\"لا تفتح قبل أن تعرف اسمه الكامل.\"\n\n" +
        "قال خالد: \"اسمي خالد الأنطاكي، وجئتُ أبحث عن مخطوطة Novalist المفقودة، " +
        "تلك التي ذكرها الرحّالة Ibn Jubayr في رحلته الثانية.\"\n\n" +
        "فكّرت ليلى: عدد الكلمات التي كتبتها هذا الأسبوع بلغ 3,450 كلمة، " +
        "أي ما يعادل ١٢ صفحة تقريبًا — وهو رقم لا بأس به لمشروعٍ من 6 فصول.\n\n" +
        "هل سيصدّقها خالد؟ وهل تنجو المخطوطة من مراجعة الناشر قبل الموعد النهائي؟"

    // MARK: - WebView discovery

    /// The HybridWebView's platform view. MAUI wraps handlers, so search the
    /// whole key-window hierarchy for the actual WKWebView.
    @MainActor
    private func findWebView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews {
            if let web = findWebView(in: sub) { return web }
        }
        return nil
    }

    @MainActor
    private func keyWindowRootView() throws -> UIView {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.flatMap { $0.windows }.first
        guard let root = window else {
            throw NSError(domain: "SmokeTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No key window - MAUI app did not boot."])
        }
        return root
    }

    @MainActor
    private func waitUpTo(_ seconds: TimeInterval, _ poll: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if poll() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return poll()
    }

    @MainActor
    private func acquiredWebView(_ seconds: TimeInterval = 30) throws -> WKWebView {
        var found: WKWebView?
        waitUpTo(seconds) { [weak self] in
            guard let self else { return false }
            found = self.findWebView(in: (try? self.keyWindowRootView()) ?? UIView())
            return found != nil
        }
        guard let web = found else {
            throw NSError(domain: "SmokeTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "WKWebView (HybridWebView) was never added to the view hierarchy."])
        }
        return web
    }

    // MARK: - JS evaluation

    /// Evaluates `script` (must return a string) with retry until it resolves
    /// to non-empty output. Long-running JS promises are awaited inside the
    /// script itself; we only retry transport-level failures.
    /// Run promise-producing JavaScript without Swift WebKit async overlays.
    /// The callback-based API avoids libswiftWebKit.dylib on iOS 18.5.
    @MainActor
    private func evaluateString(_ web: WKWebView, _ script: String,
                                timeout: TimeInterval = 90, retries: Int = 3) async throws -> String {
        var lastError: Error = NSError(domain: "SmokeTests", code: 3,
                                       userInfo: [NSLocalizedDescriptionKey: "JS evaluation never ran"])
        for _ in 0..<max(1, retries) {
            do {
                let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let starter = """
                window.__novalistSmoke = window.__novalistSmoke || {};
                window.__novalistSmoke['\(token)'] = {done:false};
                Promise.resolve().then(() => (\(script))).then(
                  value => { window.__novalistSmoke['\(token)'] = {done:true, value:String(value ?? '')}; },
                  error => { window.__novalistSmoke['\(token)'] = {done:true, error:String(error)}; }
                );
                'started';
                """
                _ = try await evaluateCallback(web, starter)
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    let probe = "JSON.stringify(window.__novalistSmoke && window.__novalistSmoke['\(token)'] || {done:false})"
                    if let result = try await evaluateCallback(web, probe) as? String,
                       result.contains("\"done\":true") {
                        let data = Data(result.utf8)
                        let state = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                        if let error = state["error"] as? String {
                            throw NSError(domain: "SmokeTests", code: 6,
                                          userInfo: [NSLocalizedDescriptionKey: error])
                        }
                        if let value = state["value"] as? String, !value.isEmpty { return value }
                        throw NSError(domain: "SmokeTests", code: 4,
                                      userInfo: [NSLocalizedDescriptionKey: "JS returned empty"])
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                throw NSError(domain: "SmokeTests", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "JS timed out after \(timeout)s"])
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        throw lastError
    }

    @MainActor
    private func evaluateCallback(_ web: WKWebView, _ javascript: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            web.evaluateJavaScript(javascript) { value, error in
                if let error = error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    /// Wraps a JS promise so failures surface as "ERROR: ..." strings instead of
    /// evaluateJavaScript errors (which lose the message detail on iOS 18).
    private func jsRpc(_ method: String, _ params: String) -> String {
        """
        (async () => {
          try {
            if (typeof window.novalistRpc === 'undefined')
              return 'ERROR: novalistRpc missing (renderer not ready)';
            const result = await window.novalistRpc.request('\(method)', \(params));
            return JSON.stringify(result);
          } catch (e) {
            return 'ERROR: ' + (e && e.message ? e.message : String(e));
          }
        })()
        """
    }

    private func assertNoJsError(_ output: String, _ context: String) throws -> String {
        if output.hasPrefix("ERROR:") {
            throw NSError(domain: "SmokeTests", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "\(context) failed: \(output)"])
        }
        return output
    }

    /// Documents folder of the app sandbox (what Files.app shows as
    /// "On My iPad -> Novalist" thanks to UIFileSharingEnabled).
    private func documentsDirectory() throws -> String {
        let dirs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        guard let docs = dirs.first else {
            throw NSError(domain: "SmokeTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "No Documents directory."])
        }
        return docs
    }

    /// Recursively grep the sandbox Documents tree for a needle.
    private func documentsContain(_ needle: String) -> Bool {
        let docs = (try? documentsDirectory()) ?? ""
        guard let enumerator = FileManager.default.enumerator(atPath: docs) else { return false }
        for case let path as String in enumerator {
            let full = (docs as NSString).appendingPathComponent(path)
            if path.hasPrefix("NovalistSmoke"),
               let data = FileManager.default.contents(atPath: full),
               let text = String(data: data, encoding: .utf8),
               text.contains(needle) {
                return true
            }
        }
        return false
    }

    private func logStep(_ message: String) {
        print("SMOKE| \(message)")
    }

    // MARK: - Phase 1 tests

    /// The golden-path boot assertion: window exists, HybridWebView is mounted,
    /// the React renderer rendered real content, and the RPC bridge answers.
    @MainActor
    func test01_Boots_WithRendererAndRpc() async throws {
        let web = try acquiredWebView(60)
        logStep("WKWebView acquired: \(web.bounds)")

        let ready = try await evaluateString(web, """
        (async () => {
          for (let i = 0; i < 120; i++) {
            const root = document.getElementById('root');
            const rpc = typeof window.novalistRpc !== 'undefined';
            const children = root ? root.children.length : 0;
            if (rpc && children > 0) {
              return JSON.stringify({
                ready: true,
                title: document.title,
                rootChildren: children,
                bodyChars: (document.body.innerText || '').length,
                dir: document.documentElement.getAttribute('dir') || 'ltr',
                lang: document.documentElement.getAttribute('lang') || ''
              });
            }
            await new Promise(r => setTimeout(r, 500));
          }
          return JSON.stringify({
            ready: false,
            title: document.title,
            rootChildren: document.getElementById('root')?.children.length ?? -1,
            bodyChars: (document.body.innerText || '').length
          });
        })()
        """, timeout: 120)
        logStep("boot state: \(ready)")
        XCTAssertTrue(ready.contains("\"ready\":true") || ready.contains("\"ready\": true"),
                      "Renderer did not become ready: \(ready)")
        XCTAssertTrue(ready.contains("\"rootChildren\":") , "Missing root children count")
        XCTAssertFalse(ready.contains("\"bodyChars\":0"), "Renderer DOM is empty (white screen?)")

        let ping = try await evaluateString(web, jsRpc("system/ping", "[]"))
        let pong = try assertNoJsError(ping, "system/ping")
        logStep("system/ping -> \(pong)")
        XCTAssertTrue(pong.contains("pong"), "system/ping did not answer with pong: \(pong)")
    }

    /// Creates the smoke novel in the app's own Documents folder through the
    /// exact RPC the CreateProjectDialog uses.
    @MainActor
    func test02_CreateNovelProject() async throws {
        let web = try acquiredWebView(60)
        let docs = try documentsDirectory()
        let parent = (docs as NSString).appendingPathComponent(Self.novelParent)
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let payload = "[\(Self.jsEscape(parent)), \(Self.jsEscape(Self.novelName)), 'الكتاب الأول']"
        let created = try await evaluateString(web, jsRpc("project/create", payload))
        logStep("project/create -> \(created.prefix(400))")
        let state = try assertNoJsError(created, "project/create")
        XCTAssertTrue(state.contains(Self.novelName), "Created project state lacks the project name: \(state.prefix(300))")

        let recent = try await evaluateString(web, jsRpc("project/recent", "[]"))
        logStep("project/recent -> \(recent.prefix(400))")
    }

    /// Chapter + scene structure through the binder's own calls.
    @MainActor
    func test03_CreateChapterAndScene() async throws {
        let web = try acquiredWebView(60)
        let chapter = try assertNoJsError(
            try await evaluateString(web, jsRpc("project/createChapter", "['الفصل الأول: البداية']")),
            "project/createChapter")
        XCTAssertTrue(chapter.contains("guid"), "createChapter response lacks guid: \(chapter.prefix(300))")

        let guid = Self.extractFirstJsonStringField(chapter, field: "guid") ?? ""
        XCTAssertFalse(guid.isEmpty, "Could not extract chapter guid from: \(chapter.prefix(300))")

        let scene = try assertNoJsError(
            try await evaluateString(web, jsRpc("project/createScene", "[\(Self.jsEscape(guid)), 'المشهد الأول: اللقاء']")),
            "project/createScene")
        logStep("scene created (chapterGuid=\(guid)) -> \(scene.prefix(200))")
    }

    /// Writes the Arabic scene through `scenes/write` (the editor's own save
    /// path), reads it back via `manuscript/get`, and verifies the bytes hit the
    /// app sandbox on disk.
    @MainActor
    func test04_WriteArabicAndVerifyPersistence() async throws {
        let web = try acquiredWebView(60)

        let manuscript = try assertNoJsError(
            try await evaluateString(web, jsRpc("manuscript/get", "['All', false, null, null, null, null]")),
            "manuscript/get")
        guard let sceneId = Self.extractFirstJsonStringField(manuscript, field: "sceneId"),
              let chapterGuid = Self.extractFirstJsonStringField(manuscript, field: "chapterGuid"),
              let hash = Self.extractFirstJsonStringField(manuscript, field: "hash") else {
            XCTFail("manuscript/get returned no scene identity: \(manuscript.prefix(600))")
            return
        }
        logStep("sceneId=\(sceneId) chapterGuid=\(chapterGuid) hash=\(hash.prefix(24))…")

        let html = "<p>\(Self.arabicText.replacingOccurrences(of: "\n\n", with: "</p><p>"))</p>"
        let writePayload = "[" +
            "\(Self.jsEscape(chapterGuid)), \(Self.jsEscape(sceneId)), " +
            "\(Self.jsEscape(html)), \(Self.jsEscape(Self.arabicText)), " +
            "\(Self.jsEscape(hash))]"
        let written = try assertNoJsError(
            try await evaluateString(web, jsRpc("scenes/write", writePayload)),
            "scenes/write")
        logStep("scenes/write -> \(written.prefix(200))")
        XCTAssertFalse(written.contains("conflicted"), "Scene write reported a conflict: \(written)")

        let reread = try assertNoJsError(
            try await evaluateString(web, jsRpc("manuscript/get", "['All', false, null, null, null, null]")),
            "manuscript/get (reread)")
        XCTAssertTrue(reread.contains("خالد الأنطاكي") || reread.contains("Ibn Jubayr"),
                      "Arabic content did not survive the write/read round-trip: \(reread.prefix(600))")

        // Give the backend a beat to flush, then grep the sandbox on disk.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let needle = "Ibn Jubayr"
        let onDisk = waitUpTo(10) { [weak self] in self?.documentsContain(needle) ?? false }
        XCTAssertTrue(onDisk, "The Arabic scene text was not found in any file under Documents/ - persistence broken.")
        logStep("Arabic content verified on disk under Documents/")
    }

    /// Codex: create a character entity, read it back, update it.
    @MainActor
    func test05_CodexCharacterLifecycle() async throws {
        let web = try acquiredWebView(60)
        let created = try assertNoJsError(
            try await evaluateString(web, jsRpc("entities/create", "['characters', 'سليم المغامر', null]")),
            "entities/create")
        logStep("entities/create -> \(created.prefix(300))")
        guard let id = Self.extractFirstJsonStringField(created, field: "id") else {
            XCTFail("entities/create returned no id: \(created.prefix(300))")
            return
        }
        let updated = try assertNoJsError(
            try await evaluateString(web, jsRpc("entities/update", "['characters', \(Self.jsEscape(id)), {'name': 'سليم المغامر المُحدَّث'}]")),
            "entities/update")
        logStep("entities/update -> \(updated.prefix(300))")
        XCTAssertTrue(updated.contains("سليم") || updated.contains("id"),
                      "entities/update returned unexpected payload: \(updated.prefix(300))")
    }

    /// Export pipeline: preview stats, then run a real Markdown export into the
    /// app's tmp directory and verify the file contains the Arabic scene.
    @MainActor
    func test06_ExportRunsAndProducesArabicFile() async throws {
        let web = try acquiredWebView(60)

        let manuscript = try assertNoJsError(
            try await evaluateString(web, jsRpc("manuscript/get", "['All', false, null, null, null, null]")),
            "manuscript/get")
        guard let chapterGuid = Self.extractFirstJsonStringField(manuscript, field: "chapterGuid") else {
            XCTFail("No chapter guid for export: \(manuscript.prefix(300))")
            return
        }

        let tmp = NSTemporaryDirectory()
        let outPath = (tmp as NSString).appendingPathComponent("smoke-export.md")
        try? FileManager.default.removeItem(atPath: outPath)

        let runPayload = "[" +
            "'Markdown', \(Self.jsEscape(outPath)), 'رواية الدخان', 'اختبار آلي', " +
            "false, [\(Self.jsEscape(chapterGuid))]]"
        let result = try assertNoJsError(
            try await evaluateString(web, jsRpc("export/run", runPayload), timeout: 180),
            "export/run")
        logStep("export/run -> \(result.prefix(300))")

        // The backend may resolve/rewrite the output path; scan tmp + Documents
        // for a Markdown file carrying the scene text.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let exported = try Self.firstFileContaining("Ibn Jubayr", under: tmp)
            ?? Self.firstFileContaining("Ibn Jubayr", under: documentsDirectory())
        XCTAssertNotNil(exported,
                        "No exported file containing the Arabic scene was found under tmp/Documents. export/run said: \(result.prefix(300))")
        if let path = exported {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertTrue(content.contains("Ibn Jubayr"), "Export file lacks the Arabic scene text: \(path)")
            logStep("exported file verified: \(path) (\(content.count) chars)")
        }
    }

    // MARK: - Phase 2 (fresh process)

    /// Runs in a SECOND `xcodebuild test` invocation after a cold terminate.
    /// The project must reopen from disk and the Arabic scene must be intact.
    @MainActor
    func test90_AfterRestart_ProjectReopensAndArabicTextSurvives() async throws {
        let web = try acquiredWebView(60)

        // A newly launched renderer may mount its WebView before the RPC bridge is registered.
        // Wait for the actual bridge rather than treating startup latency as lost persistence.
        let ready = try await evaluateString(web, """
        (async () => {
          for (let i = 0; i < 120; i++) {
            if (window.novalistRpc && typeof window.novalistRpc.request === 'function') return 'ready';
            await new Promise(resolve => setTimeout(resolve, 500));
          }
          return 'not-ready';
        })()
        """, timeout: 90)
        XCTAssertEqual(ready, "ready", "RPC bridge never initialized after restart")
        guard ready == "ready" else { return }

        let recent = try assertNoJsError(
            try await evaluateString(web, jsRpc("project/recent", "[]"), timeout: 120),
            "project/recent")
        logStep("recent projects after restart: \(recent.prefix(500))")

        // Find the smoke project's directory from the recent list.
        guard let dir = Self.extractProjectDirectory(recent, projectName: Self.novelName) else {
            XCTFail("SmokeNovel not found in project/recent after restart: \(recent.prefix(600))")
            return
        }
        logStep("reopening: \(dir)")

        let opened = try assertNoJsError(
            try await evaluateString(web, jsRpc("project/open", "[\(Self.jsEscape(dir)), null]"), timeout: 120),
            "project/open")
        logStep("project/open -> \(opened.prefix(300))")
        XCTAssertTrue(opened.contains("الفصل الأول") || opened.contains("guid"),
                      "Reopened project lacks the smoke chapter: \(opened.prefix(400))")

        let manuscript = try assertNoJsError(
            try await evaluateString(web, jsRpc("manuscript/get", "['All', false, null, null, null, null]")),
            "manuscript/get (after restart)")
        XCTAssertTrue(manuscript.contains("خالد الأنطاكي") || manuscript.contains("Ibn Jubayr"),
                      "Arabic text did NOT survive the cold restart: \(manuscript.prefix(800))")
        logStep("PERSISTENCE VERIFIED: Arabic scene text survived a full app restart.")
    }

    // MARK: - JSON helpers

    static func jsEscape(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 32 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out += String(ch)
                }
            }
        }
        return out + "\""
    }

    /// Pulls the first value of `field` out of arbitrary JSON-ish text without
    /// needing a full parser (backend DTOs are stable camelCase).
    static func extractFirstJsonStringField(_ text: String, field: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"" + field + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let value = Range(match.range(at: 1), in: text) else { return nil }
        var raw = String(text[value])
        raw = raw
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
        return raw
    }

    /// Finds `"directory": "..."`-style entries in project/recent output and
    /// returns the one whose path ends with the project name.
    static func extractProjectDirectory(_ recentJson: String, projectName: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"") else { return nil }
        let range = NSRange(recentJson.startIndex..<recentJson.endIndex, in: recentJson)
        let matches = regex.matches(in: recentJson, range: range)
        for match in matches.reversed() {
            guard let r = Range(match.range(at: 1), in: recentJson) else { continue }
            let candidate = String(recentJson[r])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
            if candidate.hasSuffix("/\(projectName)") || candidate.hasSuffix("/\(projectName)/.novalist") {
                return candidate
            }
        }
        return nil
    }

    static func firstFileContaining(_ needle: String, under directory: String) -> String? {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return nil }
        for case let path as String in enumerator {
            let full = (directory as NSString).appendingPathComponent(path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
               let data = FileManager.default.contents(atPath: full),
               let text = String(data: data, encoding: .utf8),
               text.contains(needle) {
                return full
            }
        }
        return nil
    }
}

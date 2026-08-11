import XCTest
@testable import Lush

#if os(macOS)
@MainActor
final class PatchworkWebViewHostTests: XCTestCase {
    func testCancellationBeforeWaitStartsResumesWithCancellation() async {
        let host = PatchworkWebViewHost()
        let task = Task { @MainActor in
            try await host.waitUntilLoaded()
        }
        task.cancel()
        await assertCancelled(task)
        host.webView(host.webView, didFinish: nil)
    }

    func testCancellationAfterWaitRegistersResumesWithCancellation() async {
        let host = PatchworkWebViewHost()
        let task = Task { @MainActor in
            try await host.waitUntilLoaded()
        }
        await Task.yield()
        task.cancel()
        await assertCancelled(task)
        host.webView(host.webView, didFinish: nil)
    }

    func testManyCancelledWaitersAreRemovedBeforeLoadFinishes() async {
        let host = PatchworkWebViewHost()
        let tasks = (0..<128).map { _ in
            Task { @MainActor in
                try await host.waitUntilLoaded()
            }
        }
        await Task.yield()
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await assertCancelled(task)
        }
        host.webView(host.webView, didFinish: nil)
        do {
            try await host.waitUntilLoaded()
        } catch {
            XCTFail("Loaded host threw \(error)")
        }
    }

    func testNavigationFailureResumesEveryWaiterOnce() async {
        let host = PatchworkWebViewHost()
        let tasks = (0..<128).map { _ in
            Task { @MainActor in
                try await host.waitUntilLoaded()
            }
        }
        await Task.yield()
        let expected = URLError(.cannotParseResponse)
        host.webView(host.webView, didFail: nil, withError: expected)
        for task in tasks {
            do {
                try await task.value
                XCTFail("Wait unexpectedly succeeded")
            } catch let error as URLError {
                XCTAssertEqual(error.code, expected.code)
            } catch {
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    private func assertCancelled(
        _ task: Task<Void, any Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("Wait unexpectedly succeeded", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
        }
    }
}
#endif

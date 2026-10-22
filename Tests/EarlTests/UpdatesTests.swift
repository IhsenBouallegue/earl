import Testing
@testable import Earl

struct UpdatesTests {
    @Test func installsOnlyWhenNothingIsGoingOn() {
        #expect(Updates.mayInstallNow(busy: false, serving: false, downloading: false))
        #expect(!Updates.mayInstallNow(busy: true, serving: false, downloading: false))
        #expect(!Updates.mayInstallNow(busy: false, serving: true, downloading: false))
        #expect(!Updates.mayInstallNow(busy: false, serving: false, downloading: true))
        #expect(!Updates.mayInstallNow(busy: true, serving: true, downloading: true))
    }

    @Test func noFeedMeansNoUpdater() {
        #expect(!Updates.hasFeed)
    }
}

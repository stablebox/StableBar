import Foundation
import Testing
@testable import StableBar

/// The Store lists note 2; note 1 and note 2 are installed.
@Test @MainActor func anOlderVersionOffersNoUpdateWhenANewerOneIsInstalled() async throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let index = LocalPackageIndex(fixture: fixture)
    let empty = #"{"widgets":[]}"#
    _ = try await index.add(id: "note", kind: "widgets", configuration: empty, name: "Note")
    let old = try fixture.packages.install(fixture.directory.appending(path: "sources/note"))
    _ = try await index.add(id: "note", kind: "widgets", configuration: empty, version: "2", name: "Note")
    _ = try fixture.packages.install(fixture.directory.appending(path: "sources/note"), record: PackageInstallRecord(PackageSource.store))
    let store = try fixture.store()
    defer { store.stop() }
    let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
    defer { library.stopUpdateChecks() }
    await library.loadInstalled()
    await library.loadStore()
    #expect(library.update(for: old.manifest) == nil)
    #expect(library.updates.isEmpty)
}

/// Note 2 is installed outside Settings after it listed the installed versions.
@Test @MainActor func updatingRereadsWhatIsInstalled() async throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let index = LocalPackageIndex(fixture: fixture)
    let empty = #"{"widgets":[]}"#
    _ = try await index.add(id: "note", kind: "widgets", configuration: empty, name: "Note")
    let old = try fixture.packages.install(fixture.directory.appending(path: "sources/note"))
    _ = try await index.add(id: "note", kind: "widgets", configuration: empty, version: "2", name: "Note")
    let store = try fixture.store()
    defer { store.stop() }
    let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
    defer { library.stopUpdateChecks() }
    await library.loadInstalled()
    await library.loadStore()
    #expect(library.updates.map(\.id) == ["note"])
    _ = try fixture.packages.install(fixture.directory.appending(path: "sources/note"), record: PackageInstallRecord(PackageSource.store))
    await library.update(old.manifest)
    #expect(library.error == nil)
    #expect(library.updates.isEmpty)
}

/// Note 2 was installed before install records existed, so nothing says whose files it holds.
@Test @MainActor func aCopyWithoutARecordKeepsTheUpdateOffered() async throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let index = LocalPackageIndex(fixture: fixture)
    let empty = #"{"widgets":[]}"#
    _ = try await index.add(id: "note", kind: "widgets", configuration: empty, name: "Note")
    let old = try fixture.packages.install(fixture.directory.appending(path: "sources/note"))
    _ = try await index.add(id: "note", kind: "widgets", configuration: empty, version: "2", name: "Note")
    _ = try fixture.packages.install(fixture.directory.appending(path: "sources/note"))
    try FileManager.default.removeItem(at: fixture.directory.appending(path: "packages/note/\(PackageInstallRecord.fileName)"))
    let store = try fixture.store()
    defer { store.stop() }
    let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
    defer { library.stopUpdateChecks() }
    await library.loadInstalled()
    await library.loadStore()
    #expect(library.update(for: old.manifest)?.version == "2")
}

/// Note 2 adds a host, and is installed outside Settings while its access review is open.
@Test @MainActor func confirmingAnUpdateInstalledDuringItsReviewSucceeds() async throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let index = LocalPackageIndex(fixture: fixture)
    let empty = #"{"widgets":[]}"#
    _ = try await index.add(id: "note", kind: "widgets", configuration: empty, name: "Note")
    let old = try fixture.packages.install(fixture.directory.appending(path: "sources/note"), record: PackageInstallRecord(PackageSource.store))
    _ = try await index.add(id: "note", kind: "widgets", configuration: empty, version: "2", hosts: #"["example.com"]"#, name: "Note")
    let store = try fixture.store()
    defer { store.stop() }
    let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
    defer { library.stopUpdateChecks() }
    await library.loadInstalled()
    await library.loadStore()
    await library.update(old.manifest)
    let review = try #require(library.pendingUpdate)
    _ = try fixture.packages.install(fixture.directory.appending(path: "sources/note"), record: PackageInstallRecord(PackageSource.store))
    await library.confirmUpdate(review)
    #expect(library.error == nil)
    #expect(library.updates.isEmpty)
}

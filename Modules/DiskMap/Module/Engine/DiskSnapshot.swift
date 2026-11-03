/// A completed, bounded database projection shared by the tile, root and navigation pages.
struct DiskSnapshot: Sendable {
    let index: DiskIndex
    let files: [DiskFile]
    init(_ index: DiskIndex) { self.index = index; files = index.largeFiles }
}

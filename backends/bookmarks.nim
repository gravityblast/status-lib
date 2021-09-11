import backend_type, backend_wrapper
import base/bookmarks
import ../types/[bookmark]

proc storeBookmark*(self: BackendWrapper, url: string, name: string): Bookmark =
    self.backend.storeBookmark(url, name)

proc updateBookmark*(self: BackendWrapper, ogUrl: string, url: string, name: string) =
    self.backend.updateBookmark(ogUrl, url, name)

proc getBookmarks*(self: BackendWrapper): string =
    self.backend.getBookmarks()

proc deleteBookmark*(self: BackendWrapper, url: string) =
    self.backend.deleteBookmark(url)

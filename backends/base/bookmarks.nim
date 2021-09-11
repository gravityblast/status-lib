import ../../types/[bookmark]
import ../backend_type

method storeBookmark*(self: Backend, url: string, name: string): Bookmark =
    raise newException(ValueError, "No implementation available")

method updateBookmark*(self: Backend, ogUrl: string, url: string, name: string) =
    raise newException(ValueError, "No implementation available")

method getBookmarks*(self: Backend): string =
    raise newException(ValueError, "No implementation available")

method deleteBookmark*(self: Backend, url: string) =
    raise newException(ValueError, "No implementation available")

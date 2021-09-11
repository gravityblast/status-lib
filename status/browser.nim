import statusgo_backend/browser as status_browser
import ../eventemitter

import ../types/[bookmark]

import ../backends/backend

type
    BrowserModel* = ref object
        events*: EventEmitter
        backend*: BackendWrapper

proc newBrowserModel*(events: EventEmitter, backend: BackendWrapper): BrowserModel =
  result = BrowserModel()
  result.events = events
  result.backend = backend

proc storeBookmark*(self: BrowserModel, url: string, name: string): Bookmark =
  result = self.backend.storeBookmark(url, name)

proc updateBookmark*(self: BrowserModel, ogUrl: string, url: string, name: string) =
  self.backend.updateBookmark(ogUrl, url, name)

proc getBookmarks*(self: BrowserModel): string =
  result = self.backend.getBookmarks()

proc deleteBookmark*(self: BrowserModel, url: string) =
  self.backend.deleteBookmark(url)

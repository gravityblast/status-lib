import types
import core, ../../types/[bookmark], json, chronicles
import ../backend_type

method storeBookmark*(self: StatusGoBackend, url: string, name: string): Bookmark =
  echo "------ new backend"
  echo "------ new backend"
  echo "------ new backend"
  echo "------ new backend"
  echo "------ new backend"
  echo "------ new backend"
  let payload = %* [{"url": url, "name": name}]
  result = Bookmark(name: name, url: url)
  try:
    let resp = callPrivateRPC("browsers_storeBookmark", payload).parseJson["result"]
    result.imageUrl = resp["imageUrl"].getStr
  except Exception as e:
    error "Error updating bookmark", msg = e.msg
    discard

method updateBookmark*(self: StatusGoBackend, ogUrl: string, url: string, name: string) =
  let payload = %* [ogUrl, {"url": url, "name": name}]
  try:
    discard callPrivateRPC("browsers_updateBookmark", payload)
  except Exception as e:
    error "Error updating bookmark", msg = e.msg
    discard

method getBookmarks*(self: StatusGoBackend, ): string =
  let payload = %* []
  result = callPrivateRPC("browsers_getBookmarks", payload)

method deleteBookmark*(self: StatusGoBackend, url: string) =
  let payload = %* [url]
  discard callPrivateRPC("browsers_deleteBookmark", payload)

import backend_type

import backend_wrapper
export backend_wrapper

import statusgo/types
export StatusGoBackend

import base/bookmarks

import statusgo/statusgo_instance
export newStatusGoBackendInstance

import statusgo/bookmark

from bookmarks as bookmarks_methods import storeBookmark, updateBookmark, getBookmarks, deleteBookmark
export storeBookmark, updateBookmark, getBookmarks, deleteBookmark

method loadBackend*(self: BackendWrapper, name: string) =
    if name == "statusgo":
        self.backend = newStatusGoBackendInstance()
    else:
        raise newException(ValueError, "unknown backend")

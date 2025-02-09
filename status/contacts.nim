import json, chronicles
import statusgo_backend/contacts as status_contacts
import statusgo_backend/accounts as status_accounts
import statusgo_backend/chat as status_chat
import profile/profile
import ../eventemitter

const DELETE_CONTACT* = "__deleteThisContact__"

type
  ContactModel* = ref object
    events*: EventEmitter

type
  ContactUpdateArgs* = ref object of Args
    contacts*: seq[Profile]

  ContactIdArgs* = ref object of Args
    id*: string

proc newContactModel*(events: EventEmitter): ContactModel =
    result = ContactModel()
    result.events = events

proc saveContact(self: ContactModel, contact: Profile): string = 
  var 
    thumbnail = ""
    largeImage = ""
  if contact.identityImage != nil:
    thumbnail = contact.identityImage.thumbnail
    largeImage = contact.identityImage.large    
  
  return status_contacts.saveContact(contact.id, contact.ensVerified, contact.ensName, contact.alias, contact.identicon, thumbnail, largeImage, contact.systemTags, contact.localNickname)

proc getContactByID*(self: ContactModel, id: string): Profile =
  let response = status_contacts.getContactByID(id)
  # TODO: change to options
  let responseResult = parseJSON($response)["result"]
  if responseResult == nil or responseResult.kind == JNull:
    result = nil
  else:
    result = toProfileModel(parseJSON($response)["result"])

proc blockContact*(self: ContactModel, id: string): string =
  var contact = self.getContactByID(id)
  contact.systemTags.add(contactBlocked)
  discard self.saveContact(contact)
  self.events.emit("contactBlocked", ContactIdArgs(id: id))

proc unblockContact*(self: ContactModel, id: string): string =
  var contact = self.getContactByID(id)
  contact.systemTags.delete(contact.systemTags.find(contactBlocked))
  discard self.saveContact(contact)
  self.events.emit("contactUnblocked", ContactIdArgs(id: id))

proc getContacts*(self: ContactModel, useCache: bool = true): seq[Profile] =
  let (contacts, usedCache) = status_contacts.getContacts(useCache)
  if not usedCache:
    self.events.emit("contactUpdate", ContactUpdateArgs(contacts: contacts))

  return contacts

proc getOrCreateContact*(self: ContactModel, id: string): Profile =
  result = self.getContactByID(id)
  if result == nil:
    let alias = status_accounts.generateAlias(id)
    result = Profile(
      id: id,
      username: alias,
      localNickname: "",
      identicon: status_accounts.generateIdenticon(id),
      alias: alias,
      ensName: "",
      ensVerified: false,
      appearance: 0,
      systemTags: @[]
    )

proc setNickName*(self: ContactModel, id: string, localNickname: string, accountKeyUID: string): string =
  var contact = self.getOrCreateContact(id)
  let nickname =
    if (localNickname == ""):
      contact.localNickname
    elif (localNickname == DELETE_CONTACT):
      ""
    else:
      localNickname

  contact.localNickname = nickname
  result = self.saveContact(contact)
  self.events.emit("contactAdded", Args())
  discard sendContactUpdate(contact.id, accountKeyUID)

proc addContact*(self: ContactModel, id: string, accountKeyUID: string): string =
  var contact = self.getOrCreateContact(id)
  
  let updating = contact.systemTags.contains(contactAdded)

  if not updating:
    contact.systemTags.add(contactAdded)
    discard status_chat.createProfileChat(contact.id)
  else:
    let index = contact.systemTags.find(contactBlocked)
    if (index > -1):
      contact.systemTags.delete(index)

  result = self.saveContact(contact)
  self.events.emit("contactAdded", Args())
  discard sendContactUpdate(contact.id, accountKeyUID)

  if updating:
    let profile = Profile(
      id: contact.id,
      username: contact.alias,
      identicon: contact.identicon,
      alias: contact.alias,
      ensName: contact.ensName,
      ensVerified: contact.ensVerified,
      appearance: 0,
      systemTags: contact.systemTags,
      localNickname: contact.localNickname
    )
    self.events.emit("contactUpdate", ContactUpdateArgs(contacts: @[profile]))

proc removeContact*(self: ContactModel, id: string) =
  let contact = self.getContactByID(id)
  contact.systemTags.delete(contact.systemTags.find(contactAdded))
  contact.systemTags.delete(contact.systemTags.find(contactRequest))

  discard self.saveContact(contact)
  self.events.emit("contactRemoved", Args())

proc isAdded*(self: ContactModel, id: string): bool =
  var contact = self.getContactByID(id)
  if contact.isNil: return false
  contact.systemTags.contains(contactAdded)

proc contactRequestReceived*(self: ContactModel, id: string): bool =
  var contact = self.getContactByID(id)
  if contact.isNil: return false
  contact.systemTags.contains(contactRequest)

proc rejectContactRequest*(self: ContactModel, id: string) =
  let contact = self.getContactByID(id)
  contact.systemTags.delete(contact.systemTags.find(contactRequest))

  discard self.saveContact(contact)
  self.events.emit("contactRemoved", Args())

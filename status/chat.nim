import json, strutils, sequtils, tables, chronicles, times, sugar, algorithm
import statusgo_backend/chat as status_chat
import statusgo_backend/contacts as status_contacts
import statusgo_backend/chatCommands as status_chat_commands
import types/[message, status_update, activity_center_notification, 
  sticker, removed_message]
import types/chat as chat_type
import utils as status_utils
import stickers
import ../eventemitter

import profile/profile
import contacts
import chat/[chat, utils]
import ens, accounts

include utils/json_utils

logScope:
  topics = "chat-model"

const backToFirstChat* = "__goBackToFirstChat"
const ZERO_ADDRESS* = "0x0000000000000000000000000000000000000000"

proc buildFilter*(chat: Chat):JsonNode =
  if chat.chatType == ChatType.PrivateGroupChat:
    return newJNull()
  result = %* { "ChatID": chat.id, "OneToOne": chat.chatType == ChatType.OneToOne }

type 
  ChatUpdateArgs* = ref object of Args
    chats*: seq[Chat]
    messages*: seq[Message]
    pinnedMessages*: seq[Message]
    emojiReactions*: seq[Reaction]
    communities*: seq[Community]
    communityMembershipRequests*: seq[CommunityMembershipRequest]
    activityCenterNotifications*: seq[ActivityCenterNotification]
    statusUpdates*: seq[StatusUpdate]
    deletedMessages*: seq[RemovedMessage]

  ChatIdArg* = ref object of Args
    chatId*: string

  ChannelArgs* = ref object of Args
    chat*: Chat

  ChatArgs* = ref object of Args
    chats*: seq[Chat]
  
  CommunityActiveChangedArgs* = ref object of Args
    active*: bool

  MsgsLoadedArgs* = ref object of Args
    chatId*: string
    messages*: seq[Message]
    statusUpdates*: seq[StatusUpdate]

  ActivityCenterNotificationsArgs* = ref object of Args
    activityCenterNotifications*: seq[ActivityCenterNotification]

  ReactionsLoadedArgs* = ref object of Args
    reactions*: seq[Reaction]
  
  MessageArgs* = ref object of Args
    id*: string
    channel*: string

  MessageSendingSuccess* = ref object of Args
    chat*: Chat
    message*: Message

  MarkAsReadNotificationProperties* = ref object of Args
    communityId*: string
    channelId*: string
    notificationTypes*: seq[ActivityCenterNotificationType]

type ChatModel* = ref object
  publicKey*: string
  events*: EventEmitter
  communitiesToFetch*: seq[string]
  mailserverReady*: bool
  channels*: Table[string, Chat]
  msgCursor: Table[string, string]
  pinnedMsgCursor: Table[string, string]
  activityCenterCursor*: string
  emojiCursor: Table[string, string]
  lastMessageTimestamps*: Table[string, int64]
  
proc newChatModel*(events: EventEmitter): ChatModel =
  result = ChatModel()
  result.events = events
  result.mailserverReady = false
  result.communitiesToFetch = @[]
  result.channels = initTable[string, Chat]()
  result.msgCursor = initTable[string, string]()
  result.pinnedMsgCursor = initTable[string, string]()
  result.emojiCursor = initTable[string, string]()
  result.lastMessageTimestamps = initTable[string, int64]()

proc getContacts*(self: ChatModel): Table[string, Profile] =
  let (index, usedCache) = status_contacts.getContactsIndex()
  if not usedCache:
    let (contacts, _) = status_contacts.getContacts()
    self.events.emit("contactUpdate", ContactUpdateArgs(contacts: contacts))

  return index

proc update*(self: ChatModel, chats: seq[Chat], messages: seq[Message], emojiReactions: seq[Reaction], communities: seq[Community], communityMembershipRequests: seq[CommunityMembershipRequest], pinnedMessages: seq[Message], activityCenterNotifications: seq[ActivityCenterNotification], statusUpdates: seq[StatusUpdate], deletedMessages: seq[RemovedMessage]) =
  for chat in chats:
    self.channels[chat.id] = chat

  for message in messages:
    let chatId = message.chatId
    let ts = times.convert(Milliseconds, Seconds, message.whisperTimestamp.parseInt())
    if not self.lastMessageTimestamps.hasKey(chatId):
      self.lastMessageTimestamps[chatId] = ts
    else:
      if self.lastMessageTimestamps[chatId] > ts:
        self.lastMessageTimestamps[chatId] = ts
      
  self.events.emit("chatUpdate", ChatUpdateArgs(messages: messages,chats: chats, emojiReactions: emojiReactions, communities: communities, communityMembershipRequests: communityMembershipRequests, pinnedMessages: pinnedMessages, activityCenterNotifications: activityCenterNotifications, statusUpdates: statusUpdates, deletedMessages: deletedMessages))

proc parseChatResponse(self: ChatModel, response: string): (seq[Chat], seq[Message]) =
  var parsedResponse = parseJson(response)
  var chats: seq[Chat] = @[]
  var messages: seq[Message] = @[]
  if parsedResponse{"result"}{"messages"} != nil:
    for jsonMsg in parsedResponse["result"]["messages"]:
      messages.add(jsonMsg.toMessage())
  if parsedResponse{"result"}{"chats"} != nil:
    for jsonChat in parsedResponse["result"]["chats"]:
      let chat = jsonChat.toChat
      self.channels[chat.id] = chat
      chats.add(chat) 
  result = (chats, messages)

proc emitUpdate(self: ChatModel, response: string) =
  var (chats, messages) = self.parseChatResponse(response)
  self.events.emit("chatUpdate", ChatUpdateArgs(messages: messages, chats: chats))

proc removeFiltersByChatId(self: ChatModel, chatId: string, filters: JsonNode)

proc removeChatFilters(self: ChatModel, chatId: string) =
  # TODO: this code should be handled by status-go / stimbus instead of the client
  # Clients should not have to care about filters. For more info about filters:
  # https://github.com/status-im/specs/blob/master/docs/stable/3-whisper-usage.md#keys-management
  let filters = parseJson(status_chat.loadFilters(@[]))["result"]

  case self.channels[chatId].chatType
  of ChatType.Public:
    for filter in filters:
      if filter["chatId"].getStr == chatId:
        status_chat.removeFilters(chatId, filter["filterId"].getStr)
  of ChatType.OneToOne, ChatType.Profile:
    # Check if user does not belong to any active chat group
    var inGroup = false
    for channel in self.channels.values:
      if channel.isActive and channel.id != chatId and channel.chatType == ChatType.PrivateGroupChat:
        inGroup = true
        break
    if not inGroup: self.removeFiltersByChatId(chatId, filters)
  of ChatType.PrivateGroupChat:
    for member in self.channels[chatId].members:
      # Check that any of the members are not in other active group chats, or that you don’t have a one-to-one open.
      var hasConversation = false
      for channel in self.channels.values:
        if (channel.isActive and channel.chatType == ChatType.OneToOne and channel.id == member.id) or
          (channel.isActive and channel.id != chatId and channel.chatType == ChatType.PrivateGroupChat and channel.isMember(member.id)):
          hasConversation = true
          break
      if not hasConversation: self.removeFiltersByChatId(member.id, filters)
  else:
    error "Unknown chat type removed", chatId

proc removeFiltersByChatId(self: ChatModel, chatId: string, filters: JsonNode) =
  var partitionedTopic = ""
  for filter in filters:
    # Contact code filter should be removed
    if filter["identity"].getStr == chatId and filter["chatId"].getStr.endsWith("-contact-code"):
      status_chat.removeFilters(chatId, filter["filterId"].getStr)

    # Remove partitioned topic if no other user in an active group chat or one-to-one is from the 
    # same partitioned topic
    if filter["identity"].getStr == chatId and filter["chatId"].getStr.startsWith("contact-discovery-"):
      partitionedTopic = filter["topic"].getStr
      var samePartitionedTopic = false
      for f in filters.filterIt(it["topic"].getStr == partitionedTopic and it["filterId"].getStr != filter["filterId"].getStr):
        let fIdentity = f["identity"].getStr;
        if self.channels.hasKey(fIdentity) and self.channels[fIdentity].isActive:
          samePartitionedTopic = true
          break
      if not samePartitionedTopic:
        status_chat.removeFilters(chatId, filter["filterId"].getStr)

proc hasChannel*(self: ChatModel, chatId: string): bool =
  self.channels.hasKey(chatId)

proc getActiveChannel*(self: ChatModel): string =
  if (self.channels.len == 0): "" else: toSeq(self.channels.values)[self.channels.len - 1].id

proc emitTopicAndJoin(self: ChatModel, chat: Chat) =
  let filterResult = status_chat.loadFilters(@[buildFilter(chat)])
  self.events.emit("channelJoined", ChannelArgs(chat: chat))

proc join*(self: ChatModel, chatId: string, chatType: ChatType, ensName: string = "", pubKey: string = "") =
  if self.hasChannel(chatId): return
  var chat = newChat(chatId, ChatType(chatType))
  self.channels[chat.id] = chat
  status_chat.saveChat(chatId, chatType, color=chat.color, ensName=ensName, profile=pubKey)
  self.emitTopicAndJoin(chat)

proc createOneToOneChat*(self: ChatModel, publicKey: string, ensName: string = "") =
  if self.hasChannel(publicKey): 
    self.emitTopicAndJoin(self.channels[publicKey])
    return

  var chat = newChat(publicKey, ChatType.OneToOne)
  if ensName != "":
    chat.name = ensName
    chat.ensName = ensName
  self.channels[chat.id] = chat
  discard status_chat.createOneToOneChat(publicKey)
  self.emitTopicAndJoin(chat)

proc createPublicChat*(self: ChatModel, chatId: string) =
  if self.hasChannel(chatId): return
  var chat = newChat(chatId, ChatType.Public)
  self.channels[chat.id] = chat
  discard status_chat.createPublicChat(chatId)
  self.emitTopicAndJoin(chat)


proc requestMissingCommunityInfos*(self: ChatModel) =
  if (self.communitiesToFetch.len == 0):
    return
  for communityId in self.communitiesToFetch:
    status_chat.requestCommunityInfo(communityId)

proc sortChats(x, y: chat_type.Chat): int =
  var t1 = x.lastMessage.whisperTimestamp
  var t2 = y.lastMessage.whisperTimestamp

  if t1 <= $x.joined:
    t1 = $x.joined
  if t2 <= $y.joined:
    t2 = $y.joined

  if t1 > t2: 1
  elif t1 == t2: 0
  else: -1

proc init*(self: ChatModel, pubKey: string) =
  self.publicKey = pubKey

  var (contacts, _) = status_contacts.getContacts()
  contacts = contacts.filter(c => c.systemTags.contains(contactAdded))
  var chatList = status_chat.loadChats()
  chatList.sort(sortChats)

  let profileUpdatesChatIds = chatList.filter(c => c.chatType == ChatType.Profile).map(c => c.id)

  if chatList.filter(c => c.chatType == ChatType.Timeline).len == 0:
    var timelineChannel = newChat(status_utils.getTimelineChatId(), ChatType.Timeline)
    self.join(timelineChannel.id, timelineChannel.chatType)
    chatList.add(timelineChannel)

  let timelineChatId = status_utils.getTimelineChatId(pubKey)

  if not profileUpdatesChatIds.contains(timelineChatId):
    var profileUpdateChannel = newChat(timelineChatId, ChatType.Profile)
    status_chat.saveChat(profileUpdateChannel.id, profileUpdateChannel.chatType, profile=pubKey)
    chatList.add(profileUpdateChannel)

  # For profile updates and timeline, we have to make sure that for
  # each added contact, a chat has been saved for the currently logged-in
  # user. Users that will use a version of Status with timeline support for the
  # first time, won't have any of those otherwise.
  if profileUpdatesChatIds.filter(id => id != timelineChatId).len != contacts.len:
    for contact in contacts:
      if not profileUpdatesChatIds.contains(status_utils.getTimelineChatId(contact.address)):
        let profileUpdatesChannel = newChat(status_utils.getTimelineChatId(contact.address), ChatType.Profile)
        status_chat.saveChat(profileUpdatesChannel.id, profileUpdatesChannel.chatType, ensName=contact.ensName, profile=contact.address)
        chatList.add(profileUpdatesChannel)

  var filters:seq[JsonNode] = @[]
  for chat in chatList:
    if self.hasChannel(chat.id):
      continue
    filters.add buildFilter(chat)
    self.channels[chat.id] = chat
    self.events.emit("channelLoaded", ChannelArgs(chat: chat))

  if filters.len == 0: return

  let filterResult = status_chat.loadFilters(filters)

  self.events.emit("chatsLoaded", ChatArgs(chats: chatList))

  self.events.once("mailserverAvailable") do(a: Args):
    self.mailserverReady = true
    self.requestMissingCommunityInfos()

proc statusUpdates*(self: ChatModel) =
  let statusUpdates = status_chat.statusUpdates()
  self.events.emit("messagesLoaded", MsgsLoadedArgs(statusUpdates: statusUpdates))

proc leave*(self: ChatModel, chatId: string) =
  self.removeChatFilters(chatId)

  if self.channels[chatId].chatType == ChatType.PrivateGroupChat:
    let leaveGroupResponse = status_chat.leaveGroupChat(chatId)
    self.emitUpdate(leaveGroupResponse)

  discard status_chat.deactivateChat(self.channels[chatId])

  self.channels.del(chatId)
  discard status_chat.clearChatHistory(chatId)
  self.events.emit("channelLeft", ChatIdArg(chatId: chatId))

proc clearHistory*(self: ChatModel, chatId: string) =
  discard status_chat.clearChatHistory(chatId)
  let chat = self.channels[chatId]
  self.events.emit("chatHistoryCleared", ChannelArgs(chat: chat))

proc setActiveChannel*(self: ChatModel, chatId: string) =
  self.events.emit("activeChannelChanged", ChatIdArg(chatId: chatId))

proc processMessageUpdateAfterSend(self: ChatModel, response: string): (seq[Chat], seq[Message])  =
  result = self.parseChatResponse(response)
  var (chats, messages) = result
  if chats.len == 0 and messages.len == 0:
    self.events.emit("messageSendingFailed", Args())
    return

  # This fixes issue#3490
  var msg = messages[0]
  for m in messages:
    if(m.responseTo.len > 0):
      msg = m
      break
  
  self.events.emit("messageSendingSuccess", MessageSendingSuccess(message: msg, chat: chats[0]))

proc sendMessage*(self: ChatModel, chatId: string, msg: string, replyTo: string = "", contentType: int = ContentType.Message.int, communityId: string = "") =
  var response = status_chat.sendChatMessage(chatId, msg, replyTo, contentType, communityId)
  discard self.processMessageUpdateAfterSend(response)

proc editMessage*(self: ChatModel, messageId: string, msg: string) =
  var response = status_chat.editMessage(messageId, msg)
  discard self.processMessageUpdateAfterSend(response)

proc sendImage*(self: ChatModel, chatId: string, image: string) =
  var response = status_chat.sendImageMessage(chatId, image)
  discard self.processMessageUpdateAfterSend(response)

proc sendImages*(self: ChatModel, chatId: string, images: var seq[string]) =
  var response = status_chat.sendImageMessages(chatId, images)
  discard self.processMessageUpdateAfterSend(response)

proc deleteMessageAndSend*(self: ChatModel, messageId: string) =
  var response = status_chat.deleteMessageAndSend(messageId)    
  discard self.processMessageUpdateAfterSend(response)

proc sendSticker*(self: ChatModel, chatId: string, replyTo: string, sticker: Sticker) =
  var response = status_chat.sendStickerMessage(chatId, replyTo, sticker)
  self.events.emit("stickerSent", StickerArgs(sticker: sticker, save: true))
  var (chats, messages) = self.parseChatResponse(response)
  self.events.emit("chatUpdate", ChatUpdateArgs(messages: messages, chats: chats))
  self.events.emit("sendingMessage", MessageArgs(id: messages[0].id, channel: messages[0].chatId))

proc addEmojiReaction*(self: ChatModel, chatId: string, messageId: string, emojiId: int) =
  let reactions = status_chat.addEmojiReaction(chatId, messageId, emojiId)
  self.events.emit("reactionsLoaded", ReactionsLoadedArgs(reactions: reactions))

proc removeEmojiReaction*(self: ChatModel, emojiReactionId: string) =
  let reactions = status_chat.removeEmojiReaction(emojiReactionId)
  self.events.emit("reactionsLoaded", ReactionsLoadedArgs(reactions: reactions))

proc onMarkMessagesRead(self: ChatModel, response: string, chatId: string): JsonNode =
  result = parseJson(response)
  if self.channels.hasKey(chatId):
    self.channels[chatId].unviewedMessagesCount = 0
    self.channels[chatId].mentionsCount = 0
    self.events.emit("channelUpdate", ChatUpdateArgs(messages: @[], chats: @[self.channels[chatId]]))

proc onAsyncMarkMessagesRead*(self: ChatModel, response: string) =
  let parsedResponse = parseJson(response)
  discard self.onMarkMessagesRead(parsedResponse{"response"}.getStr, parsedResponse{"chatId"}.getStr)

proc markAllChannelMessagesRead*(self: ChatModel, chatId: string): JsonNode =
  var response = status_chat.markAllRead(chatId)
  return self.onMarkMessagesRead(response, chatId)

proc markMessagesSeen*(self: ChatModel, chatId: string, messageIds: seq[string]): JsonNode =
  var response = status_chat.markMessagesSeen(chatId, messageIds)
  return self.onMarkMessagesRead(response, chatId)

proc confirmJoiningGroup*(self: ChatModel, chatId: string) =
  var response = status_chat.confirmJoiningGroup(chatId)
  self.emitUpdate(response)

proc renameGroup*(self: ChatModel, chatId: string, newName: string) =
  var response = status_chat.renameGroup(chatId, newName)
  self.emitUpdate(response)

proc getUserName*(self: ChatModel, id: string, defaultUserName: string):string =
  let contacts = self.getContacts()
  if(contacts.hasKey(id)):
    return userNameOrAlias(contacts[id])
  else:
    return defaultUserName

proc processGroupChatCreation*(self: ChatModel, result: string) =
  var response = parseJson(result)
  var (chats, messages) = formatChatUpdate(response)
  let chat = chats[0]
  self.channels[chat.id] = chat
  self.events.emit("chatUpdate", ChatUpdateArgs(messages: messages, chats: chats))
  self.events.emit("activeChannelChanged", ChatIdArg(chatId: chat.id))

proc createGroup*(self: ChatModel, groupName: string, pubKeys: seq[string]) =
  var result = status_chat.createGroup(groupName, pubKeys)
  self.processGroupChatCreation(result) 

proc createGroupChatFromInvitation*(self: ChatModel, groupName: string, chatID: string, adminPK: string) =
  var result = status_chat.createGroupChatFromInvitation(groupName, chatID, adminPK)
  self.processGroupChatCreation(result)

proc addGroupMembers*(self: ChatModel, chatId: string, pubKeys: seq[string]) =
  var response = status_chat.addGroupMembers(chatId, pubKeys)
  self.emitUpdate(response)

proc kickGroupMember*(self: ChatModel, chatId: string, pubKey: string) =
  var response = status_chat.kickGroupMember(chatId, pubKey)
  self.emitUpdate(response)

proc makeAdmin*(self: ChatModel, chatId: string, pubKey: string) =
  var response = status_chat.makeAdmin(chatId, pubKey)
  self.emitUpdate(response)

proc resendMessage*(self: ChatModel, messageId: string) =
  discard status_chat.reSendChatMessage(messageId)

proc muteChat*(self: ChatModel, chat: Chat) =
  discard status_chat.muteChat(chat.id)
  self.events.emit("chatUpdate", ChatUpdateArgs(messages: @[], chats: @[chat]))

proc unmuteChat*(self: ChatModel, chat: Chat) =
  discard status_chat.unmuteChat(chat.id)
  self.events.emit("chatUpdate", ChatUpdateArgs(messages: @[], chats: @[chat]))

proc processUpdateForTransaction*(self: ChatModel, messageId: string, response: string) =
  var (chats, messages) = self.processMessageUpdateAfterSend(response)
  self.events.emit("messageDeleted", MessageArgs(id: messageId, channel: chats[0].id))

proc acceptRequestAddressForTransaction*(self: ChatModel, messageId: string, address: string) =
  let response = status_chat_commands.acceptRequestAddressForTransaction(messageId, address)
  self.processUpdateForTransaction(messageId, response)

proc declineRequestAddressForTransaction*(self: ChatModel, messageId: string) =
  let response = status_chat_commands.declineRequestAddressForTransaction(messageId)
  self.processUpdateForTransaction(messageId, response)

proc declineRequestTransaction*(self: ChatModel, messageId: string) =
  let response = status_chat_commands.declineRequestTransaction(messageId)
  self.processUpdateForTransaction(messageId, response)

proc requestAddressForTransaction*(self: ChatModel, chatId: string, fromAddress: string, amount: string, tokenAddress: string) =
  let address = if (tokenAddress == ZERO_ADDRESS): "" else: tokenAddress
  let response = status_chat_commands.requestAddressForTransaction(chatId, fromAddress, amount, address)
  discard self.processMessageUpdateAfterSend(response)

proc acceptRequestTransaction*(self: ChatModel, transactionHash: string, messageId: string, signature: string) =
  let response = status_chat_commands.acceptRequestTransaction(transactionHash, messageId, signature)
  discard self.processMessageUpdateAfterSend(response)

proc requestTransaction*(self: ChatModel, chatId: string, fromAddress: string, amount: string, tokenAddress: string) =
  let address = if (tokenAddress == ZERO_ADDRESS): "" else: tokenAddress
  let response = status_chat_commands.requestTransaction(chatId, fromAddress, amount, address)
  discard self.processMessageUpdateAfterSend(response)

proc getAllComunities*(self: ChatModel): seq[Community] =
  result = status_chat.getAllComunities()

proc getJoinedComunities*(self: ChatModel): seq[Community] =
  result = status_chat.getJoinedComunities()

proc createCommunity*(self: ChatModel, name: string, description: string, access: int, ensOnly: bool, color: string, imageUrl: string, aX: int, aY: int, bX: int, bY: int): Community =
  result = status_chat.createCommunity(name, description, access, ensOnly, color, imageUrl, aX, aY, bX, bY)

proc editCommunity*(self: ChatModel, id: string, name: string, description: string, access: int, ensOnly: bool, color: string, imageUrl: string, aX: int, aY: int, bX: int, bY: int): Community =
  result = status_chat.editCommunity(id, name, description, access, ensOnly, color, imageUrl, aX, aY, bX, bY)

proc createCommunityChannel*(self: ChatModel, communityId: string, name: string, description: string): Chat =
  result = status_chat.createCommunityChannel(communityId, name, description)

proc editCommunityChannel*(self: ChatModel, communityId: string, channelId: string, name: string, description: string, categoryId: string): Chat =
  result = status_chat.editCommunityChannel(communityId, channelId, name, description, categoryId)

proc deleteCommunityChat*(self: ChatModel, communityId: string, channelId: string) =
  status_chat.deleteCommunityChat(communityId, channelId)

proc reorderCommunityCategories*(self: ChatModel, communityId: string, categoryId: string, position: int) =
  status_chat.reorderCommunityCategories(communityId, categoryId, position)

proc createCommunityCategory*(self: ChatModel, communityId: string, name: string, channels: seq[string]): CommunityCategory =
  result = status_chat.createCommunityCategory(communityId, name, channels)

proc editCommunityCategory*(self: ChatModel, communityId: string, categoryId: string, name: string, channels: seq[string]) =
  status_chat.editCommunityCategory(communityId, categoryId, name, channels)

proc deleteCommunityCategory*(self: ChatModel, communityId: string, categoryId: string) =
  status_chat.deleteCommunityCategory(communityId, categoryId)

proc reorderCommunityChannel*(self: ChatModel, communityId: string, categoryId: string, chatId: string, position: int) =
  status_chat.reorderCommunityChat(communityId, categoryId, chatId, position)

proc joinCommunity*(self: ChatModel, communityId: string) =
  status_chat.joinCommunity(communityId)

proc requestCommunityInfo*(self: ChatModel, communityId: string) =
  if (not self.mailserverReady):
    self.communitiesToFetch.add(communityId)
    self.communitiesToFetch = self.communitiesToFetch.deduplicate()
    return
  status_chat.requestCommunityInfo(communityId)

proc leaveCommunity*(self: ChatModel, communityId: string) =
  status_chat.leaveCommunity(communityId)

proc inviteUserToCommunity*(self: ChatModel, communityId: string, pubKey: string) =
  let response = status_chat.inviteUsersToCommunity(communityId, @[pubKey])
  discard self.processMessageUpdateAfterSend(response)

proc inviteUsersToCommunity*(self: ChatModel, communityId: string, pubKeys: seq[string]) =
  let response = status_chat.inviteUsersToCommunity(communityId, pubKeys)
  discard self.processMessageUpdateAfterSend(response)

proc removeUserFromCommunity*(self: ChatModel, communityId: string, pubKey: string) =
  status_chat.removeUserFromCommunity(communityId, pubKey)

proc banUserFromCommunity*(self: ChatModel, pubKey: string, communityId: string): string =
  return status_chat.banUserFromCommunity(pubKey, communityId)

proc exportCommunity*(self: ChatModel, communityId: string): string =
  result = status_chat.exportCommunity(communityId)

proc importCommunity*(self: ChatModel, communityKey: string): string =
  result = status_chat.importCommunity(communityKey)

proc requestToJoinCommunity*(self: ChatModel, communityKey: string, ensName: string): seq[CommunityMembershipRequest] =
  status_chat.requestToJoinCommunity(communityKey, ensName)

proc acceptRequestToJoinCommunity*(self: ChatModel, requestId: string) =
  status_chat.acceptRequestToJoinCommunity(requestId)

proc declineRequestToJoinCommunity*(self: ChatModel, requestId: string) =
  status_chat.declineRequestToJoinCommunity(requestId)

proc pendingRequestsToJoinForCommunity*(self: ChatModel, communityKey: string): seq[CommunityMembershipRequest] =
  result = status_chat.pendingRequestsToJoinForCommunity(communityKey)

proc setCommunityMuted*(self: ChatModel, communityId: string, muted: bool) =
  status_chat.setCommunityMuted(communityId, muted)

proc myPendingRequestsToJoin*(self: ChatModel): seq[CommunityMembershipRequest] =
  result = status_chat.myPendingRequestsToJoin()

proc setPinMessage*(self: ChatModel, messageId: string, chatId: string, pinned: bool) =
  status_chat.setPinMessage(messageId, chatId, pinned)

proc activityCenterNotifications*(self: ChatModel, initialLoad: bool = true) =
  # Notifications were already loaded, since cursor will 
  # be nil/empty if there are no more notifs
  if(not initialLoad and self.activityCenterCursor == ""): return

  let activityCenterNotificationsTuple = status_chat.activityCenterNotification(self.activityCenterCursor)
  self.activityCenterCursor = activityCenterNotificationsTuple[0];

  self.events.emit("activityCenterNotificationsLoaded", ActivityCenterNotificationsArgs(activityCenterNotifications: activityCenterNotificationsTuple[1]))

proc activityCenterNotifications*(self: ChatModel, cursor: string = "", activityCenterNotifications: seq[ActivityCenterNotification]) =
  self.activityCenterCursor = cursor

  self.events.emit("activityCenterNotificationsLoaded", ActivityCenterNotificationsArgs(activityCenterNotifications: activityCenterNotifications))

proc markAllActivityCenterNotificationsRead*(self: ChatModel): string =
  try:
    status_chat.markAllActivityCenterNotificationsRead()
  except Exception as e:
    error "Error marking all as read", msg = e.msg
    result = e.msg
  
  # This proc should accept ActivityCenterNotificationType in order to clear all notifications
  # per type, that's why we have this part here. If we add all types to notificationsType that 
  # means that we need to clear all notifications for all types.
  var types : seq[ActivityCenterNotificationType]
  for t in ActivityCenterNotificationType:
    types.add(t)

  self.events.emit("markNotificationsAsRead", MarkAsReadNotificationProperties(notificationTypes: types))

proc markActivityCenterNotificationRead*(self: ChatModel, notificationId: string,
markAsReadProps: MarkAsReadNotificationProperties): string =
  try:
    status_chat.markActivityCenterNotificationsRead(@[notificationId])
  except Exception as e:
    error "Error marking as read", msg = e.msg
    result = e.msg
  
  self.events.emit("markNotificationsAsRead", markAsReadProps)

proc acceptActivityCenterNotifications*(self: ChatModel, ids: seq[string]): string =
  try:
    let response = status_chat.acceptActivityCenterNotifications(ids)

    let (chats, messages) = self.parseChatResponse(response)
    self.events.emit("chatUpdate", ChatUpdateArgs(messages: messages, chats: chats))

  except Exception as e:
    error "Error marking as accepted", msg = e.msg
    result = e.msg

proc dismissActivityCenterNotifications*(self: ChatModel, ids: seq[string]): string =
  try:
    discard status_chat.dismissActivityCenterNotifications(ids)
  except Exception as e:
    error "Error marking as dismissed", msg = e.msg
    result = e.msg

proc unreadActivityCenterNotificationsCount*(self: ChatModel): int =
  status_chat.unreadActivityCenterNotificationsCount()

proc getLinkPreviewData*(link: string, success: var bool): JsonNode =
  result = status_chat.getLinkPreviewData(link, success)

proc getCommunityIdForChat*(self: ChatModel, chatId: string): string =
  if (not self.hasChannel(chatId)):
    return ""
  return self.channels[chatId].communityId

proc onAsyncSearchMessages*(self: ChatModel, response: string) =
  let responseObj = response.parseJson
  if (responseObj.kind != JObject):
    info "search messages response is not an json object"
    return

  var chatId: string
  discard responseObj.getProp("chatId", chatId)

  var messagesObj: JsonNode
  if (not responseObj.getProp("messages", messagesObj)):
    info "search messages response doesn't contain messages property"
    return

  var messagesArray: JsonNode
  if (not messagesObj.getProp("messages", messagesArray)):
    info "search messages response doesn't contain messages array"
    return      

  var messages: seq[Message] = @[]
  if (messagesArray.kind == JArray):
    for jsonMsg in messagesArray:
      messages.add(jsonMsg.toMessage())
  
  self.events.emit("searchMessagesLoaded", MsgsLoadedArgs(chatId: chatId, messages: messages))

proc onLoadMoreMessagesForChannel*(self: ChatModel, response: string) =
  let responseObj = response.parseJson
  if (responseObj.kind != JObject):
    info "load more messages response is not an json object"
    
    # notify view
    self.events.emit("messagesLoaded", MsgsLoadedArgs())
    self.events.emit("reactionsLoaded", ReactionsLoadedArgs())
    self.events.emit("pinnedMessagesLoaded", MsgsLoadedArgs())
    return
  
  var chatId: string
  discard responseObj.getProp("chatId", chatId)
  
  # handling chat messages
  var chatMessagesObj: JsonNode
  var chatCursor: string
  discard responseObj.getProp("messages", chatMessagesObj)
  discard responseObj.getProp("messagesCursor", chatCursor)

  self.msgCursor[chatId] = chatCursor

  var messages: seq[Message] = @[]
  if (chatMessagesObj.kind == JArray):
    for jsonMsg in chatMessagesObj:
      messages.add(jsonMsg.toMessage())

  if messages.len > 0:
    let lastMsgIndex = messages.len - 1
    let ts = times.convert(Milliseconds, Seconds, messages[lastMsgIndex].whisperTimestamp.parseInt())
    self.lastMessageTimestamps[chatId] = ts

  # handling reactions
  var reactionsObj: JsonNode
  var reactionsCursor: string
  discard responseObj.getProp("reactions", reactionsObj)
  discard responseObj.getProp("reactionsCursor", reactionsCursor)

  self.emojiCursor[chatId] = reactionsCursor;

  var reactions: seq[Reaction] = @[]
  if (reactionsObj.kind == JArray):
    for jsonMsg in reactionsObj:
      reactions.add(jsonMsg.toReaction)

  # handling pinned messages
  var pinnedMsgObj: JsonNode
  var pinnedMsgCursor: string
  discard responseObj.getProp("pinnedMessages", pinnedMsgObj)
  discard responseObj.getProp("pinnedMessagesCursor", pinnedMsgCursor)

  self.pinnedMsgCursor[chatId] = pinnedMsgCursor

  var pinnedMessages: seq[Message] = @[]
  if (pinnedMsgObj.kind == JArray):
    for jsonMsg in pinnedMsgObj:
      var msgObj: JsonNode
      if(jsonMsg.getProp("message", msgObj)):
        var msg: Message
        msg = msgObj.toMessage()
        discard jsonMsg.getProp("pinnedBy", msg.pinnedBy)
        pinnedMessages.add(msg)

  # notify view
  self.events.emit("messagesLoaded", MsgsLoadedArgs(chatId: chatId, messages: messages))
  self.events.emit("reactionsLoaded", ReactionsLoadedArgs(reactions: reactions))
  self.events.emit("pinnedMessagesLoaded", MsgsLoadedArgs(chatId: chatId, messages: pinnedMessages))

proc userNameOrAlias*(self: ChatModel, pubKey: string, 
  prettyForm: bool = false): string =
  ## Returns ens name or alias, in case if prettyForm is true and ens name
  ## ends with ".stateofus.eth" that part will be removed.
  var alias: string
  let contacts = self.getContacts()
  if contacts.hasKey(pubKey):
    alias = ens.userNameOrAlias(contacts[pubKey])
  else:
    alias = generateAlias(pubKey)

  if (prettyForm and alias.endsWith(".stateofus.eth")):
    alias = alias[0 .. ^15]

  return alias

proc chatName*(self: ChatModel, chatItem: Chat): string =
  if (not chatItem.chatType.isOneToOne): 
    return chatItem.name

  let contacts = self.getContacts()
  if (contacts.hasKey(chatItem.id) and contacts[chatItem.id].hasNickname()):
    return contacts[chatItem.id].localNickname

  if chatItem.ensName != "":
    return "@" & userName(chatItem.ensName).userName(true)

  return self.userNameOrAlias(chatItem.id)

proc isMessageCursorSet*(self: ChatModel, channelId: string): bool =
  self.msgCursor.hasKey(channelId)

proc getCurrentMessageCursor*(self: ChatModel, channelId: string): string =
  if(not self.msgCursor.hasKey(channelId)):
    self.msgCursor[channelId] = ""

  return self.msgCursor[channelId]

proc isEmojiCursorSet*(self: ChatModel, channelId: string): bool =
  self.emojiCursor.hasKey(channelId)

proc getCurrentEmojiCursor*(self: ChatModel, channelId: string): string =
  if(not self.emojiCursor.hasKey(channelId)):
    self.emojiCursor[channelId] = ""

  return self.emojiCursor[channelId]

proc isPinnedMessageCursorSet*(self: ChatModel, channelId: string): bool =
  self.pinnedMsgCursor.hasKey(channelId)

proc getCurrentPinnedMessageCursor*(self: ChatModel, channelId: string): string =
  if(not self.pinnedMsgCursor.hasKey(channelId)):
    self.pinnedMsgCursor[channelId] = ""

  return self.pinnedMsgCursor[channelId]
import # global deps
  atomics, sequtils, strutils, tables

import # project deps
  chronicles, web3/[ethtypes, conversions], stint

import # local deps
  utils as status_utils,
  statusgo_backend/settings as status_settings,
  eth/contracts as status_contracts,
  eth/stickers as status_stickers,
  transactions,
  statusgo_backend/wallet, ../eventemitter
import ./types/[sticker, transaction, rpc_response, network_type, network]
from utils as statusgo_backend_utils import eth2Wei, gwei2Wei, toUInt64, parseAddress

logScope:
  topics = "stickers-model"

type
    StickersModel* = ref object
      events*: EventEmitter
      recentStickers*: seq[Sticker]
      availableStickerPacks*: Table[int, StickerPack]
      installedStickerPacks*: Table[int, StickerPack]
      purchasedStickerPacks*: seq[int]

    StickerArgs* = ref object of Args
      sticker*: Sticker
      save*: bool

# forward declaration
proc addStickerToRecent*(self: StickersModel, sticker: Sticker, save: bool = false)

proc newStickersModel*(events: EventEmitter): StickersModel =
  result = StickersModel()
  result.events = events
  result.recentStickers = @[]
  result.availableStickerPacks = initTable[int, StickerPack]()
  result.installedStickerPacks = initTable[int, StickerPack]()
  result.purchasedStickerPacks = @[]

proc init*(self: StickersModel) =
  self.events.on("stickerSent") do(e: Args):
    var evArgs = StickerArgs(e)
    self.addStickerToRecent(evArgs.sticker, evArgs.save)

proc buildTransaction(packId: Uint256, address: Address, price: Uint256, approveAndCall: var ApproveAndCall[100], sntContract: var Erc20Contract, gas = "", gasPrice = "", isEIP1559Enabled = false, maxPriorityFeePerGas = "", maxFeePerGas = ""): TransactionData =
  let network = status_settings.getCurrentNetwork().toNetwork()
  sntContract = status_contracts.findErc20Contract(network.chainId, network.sntSymbol())
  let
    stickerMktContract = status_contracts.findContract(network.chainId, "sticker-market")
    buyToken = BuyToken(packId: packId, address: address, price: price)
    buyTxAbiEncoded = stickerMktContract.methods["buyToken"].encodeAbi(buyToken)
  approveAndCall = ApproveAndCall[100](to: stickerMktContract.address, value: price, data: DynamicBytes[100].fromHex(buyTxAbiEncoded))
  transactions.buildTokenTransaction(address, sntContract.address, gas, gasPrice, isEIP1559Enabled, maxPriorityFeePerGas, maxFeePerGas)

proc estimateGas*(packId: int, address: string, price: string, success: var bool): int =
  var
    approveAndCall: ApproveAndCall[100]
    network = status_settings.getCurrentNetwork().toNetwork()
    sntContract = status_contracts.findErc20Contract(network.chainId, network.sntSymbol())
    tx = buildTransaction(
      packId.u256,
      parseAddress(address),
      eth2Wei(parseFloat(price), sntContract.decimals),
      approveAndCall,
      sntContract
    )

  let response = sntContract.methods["approveAndCall"].estimateGas(tx, approveAndCall, success)
  if success:
    result = fromHex[int](response)

proc buyPack*(self: StickersModel, packId: int, address, price, gas, gasPrice: string, isEIP1559Enabled: bool, maxPriorityFeePerGas: string, maxFeePerGas: string, password: string, success: var bool): string =
  var
    sntContract: Erc20Contract
    approveAndCall: ApproveAndCall[100]
    tx = buildTransaction(
      packId.u256,
      parseAddress(address),
      eth2Wei(parseFloat(price), 18), # SNT
      approveAndCall,
      sntContract,
      gas,
      gasPrice,
      isEIP1559Enabled,
      maxPriorityFeePerGas,
      maxFeePerGas
    )

  result = sntContract.methods["approveAndCall"].send(tx, approveAndCall, password, success)
  if success:
    trackPendingTransaction(result, address, $sntContract.address, PendingTransactionType.BuyStickerPack, $packId)

proc getStickerMarketAddress*(self: StickersModel): Address =
  let network = status_settings.getCurrentNetwork().toNetwork()
  result = status_contracts.findContract(network.chainId, "sticker-market").address

proc getPurchasedStickerPacks*(self: StickersModel, address: Address): seq[int] =
  try:
    let
      network = status_settings.getCurrentNetwork().toNetwork()
      balance = status_stickers.getBalance(network.chainId, address)
      tokenIds = toSeq[0..<balance].mapIt(status_stickers.tokenOfOwnerByIndex(network.chainId, address, it.u256))
      purchasedPackIds = tokenIds.mapIt(status_stickers.getPackIdFromTokenId(network.chainId, it.u256))
    self.purchasedStickerPacks = self.purchasedStickerPacks.concat(purchasedPackIds)
    result = self.purchasedStickerPacks
  except RpcException:
    error "Error getting purchased sticker packs", message = getCurrentExceptionMsg()
    result = @[]

proc getInstalledStickerPacks*(self: StickersModel): Table[int, StickerPack] =
  if self.installedStickerPacks != initTable[int, StickerPack]():
    return self.installedStickerPacks

  self.installedStickerPacks = status_stickers.getInstalledStickerPacks()
  result = self.installedStickerPacks

proc getAvailableStickerPacks*(running: var Atomic[bool]): Table[int, StickerPack] =
  let network = status_settings.getCurrentNetwork().toNetwork()
  return status_stickers.getAvailableStickerPacks(network.chainId, running)

proc getRecentStickers*(self: StickersModel): seq[Sticker] =
  result = status_stickers.getRecentStickers()

proc installStickerPack*(self: StickersModel, packId: int) =
  if not self.availableStickerPacks.hasKey(packId):
    return
  let pack = self.availableStickerPacks[packId]
  self.installedStickerPacks[packId] = pack
  status_stickers.saveInstalledStickerPacks(self.installedStickerPacks)

proc removeRecentStickers*(self: StickersModel, packId: int) =
  self.recentStickers.keepItIf(it.packId != packId)
  status_stickers.saveRecentStickers(self.recentStickers)

proc uninstallStickerPack*(self: StickersModel, packId: int) =
  if not self.installedStickerPacks.hasKey(packId):
    return
  let pack = self.availableStickerPacks[packId]
  self.installedStickerPacks.del(packId)
  status_stickers.saveInstalledStickerPacks(self.installedStickerPacks)

proc addStickerToRecent*(self: StickersModel, sticker: Sticker, save: bool = false) =
  self.recentStickers.insert(sticker, 0)
  self.recentStickers = self.recentStickers.deduplicate()
  if self.recentStickers.len > 24:
    self.recentStickers = self.recentStickers[0..23] # take top 24 most recent
  if save:
    status_stickers.saveRecentStickers(self.recentStickers)

proc decodeContentHash*(value: string): string =
  result = status_utils.decodeContentHash(value)

proc getPackIdFromTokenId*(tokenId: Stuint[256]): int =
  let network = status_settings.getCurrentNetwork().toNetwork()
  result = status_stickers.getPackIdFromTokenId(network.chainId, tokenId)

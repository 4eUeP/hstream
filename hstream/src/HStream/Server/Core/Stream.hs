{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE CPP               #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards     #-}

module HStream.Server.Core.Stream
  ( createStream
  , deleteStream
  , getStream
  , listStreams
  , listStreamsWithPrefix
  , appendStream
  , listShards
  , getTailRecordId
  , trimShard
  , trimStream
  , createStreamV2
  , deleteStreamV2
  , listShardsV2
  , getTailRecordIdV2
  , trimShards
  ) where

import           Control.Concurrent                (getNumCapabilities)
import           Control.Exception                 (Exception (displayException, fromException, toException),
                                                    SomeException, catch,
                                                    throwIO, try)
import           Control.Monad                     (forM, forM_, unless, void,
                                                    when)
import qualified Data.Attoparsec.Text              as AP
import qualified Data.ByteString                   as BS
import qualified Data.ByteString.Lazy              as BSL
import           Data.Either                       (partitionEithers)
import           Data.Functor                      ((<&>))
import           Data.IORef                        (readIORef)
import qualified Data.List                         as L
import qualified Data.Map.Strict                   as M
import           Data.Maybe                        (fromJust, fromMaybe)
import qualified Data.Text                         as T
import           Data.Vector                       (Vector)
import qualified Data.Vector                       as V
import           Data.Word                         (Word32, Word64)
import           GHC.Stack                         (HasCallStack)
import           Google.Protobuf.Timestamp         (Timestamp)
import           HStream.Base.Time                 (getSystemNsTimestamp)
import           HStream.Common.Server.Shard       (createShard, mkShardAttrs,
                                                    mkShardWithDefaultId)
import           HStream.Common.Types
import qualified HStream.Common.ZookeeperSlotAlloc as Slot
import qualified HStream.Exception                 as HE
import qualified HStream.Logger                    as Log
import qualified HStream.Server.CacheStore         as DB
import qualified HStream.Server.HStreamApi         as API
import qualified HStream.Server.MetaData           as P
import           HStream.Server.Types              (ServerContext (..),
                                                    ServerInternalOffset (..),
                                                    ServerMode (..),
                                                    ToOffset (..))
import qualified HStream.Stats                     as Stats
import qualified HStream.Store                     as S
import           HStream.Utils
import qualified Proto3.Suite                      as PT
import qualified Z.Data.CBytes                     as CB
import qualified ZooKeeper.Exception               as ZK

-------------------------------------------------------------------------------

createStream :: HasCallStack => ServerContext -> API.Stream -> IO API.Stream
createStream ServerContext{..} stream@API.Stream{
  streamBacklogDuration = backlogSec, streamShardCount = shardCount, ..} = do
  timeStamp <- getProtoTimestamp
  let extraAttr = M.fromList [("createTime", lazyByteStringToCBytes $ PT.toLazyByteString timeStamp)]
  let streamId = S.transToStreamName streamStreamName
      attrs = S.def { S.logReplicationFactor = S.defAttr1 $ fromIntegral streamReplicationFactor
                    , S.logBacklogDuration   = S.defAttr1 $
                       if backlogSec > 0 then Just $ fromIntegral backlogSec else Nothing
                    , S.logAttrsExtras       = extraAttr
                    }
  catch (S.createStream scLDClient streamId attrs) $ \(_ :: S.EXISTS) ->
    throwIO $ HE.StreamExists streamStreamName

  let partitions = devideKeySpace (fromIntegral shardCount)
  shards <- forM partitions $ \(startKey, endKey) -> do
    let shard = mkShardWithDefaultId streamId startKey endKey (fromIntegral shardCount)
    createShard scLDClient shard
  Log.debug $ "create shards for stream " <> Log.build streamStreamName <> ": " <> Log.buildString' (show shards)
  return stream{API.streamCreationTime = Just timeStamp}

-- NOTE:
-- 1. We will ignore streamReplicationFactor,streamBacklogDuration setting in the request
createStreamV2
  :: HasCallStack
  => ServerContext -> Slot.SlotConfig
  -> API.Stream -> IO API.Stream
createStreamV2 ServerContext{..} slotConfig stream@API.Stream{..} = do
  -- NOTE: the bytestring get from getProtoTimestamp is not a valid utf8
  timeStamp <- getSystemNsTimestamp
  let !extraAttr = M.fromList [("createTime", T.pack $ show timeStamp)]
      partitions = devideKeySpace (fromIntegral streamShardCount)
      shardAttrs = partitions <&> (\(startKey, endKey) -> Slot.SlotValueAttrs $
        mkShardAttrs startKey endKey (fromIntegral streamShardCount))

  shards <- catch (Slot.allocateSlot slotConfig (textToCBytes streamStreamName) extraAttr shardAttrs) $
    \(_ :: ZK.ZNODEEXISTS) -> throwIO $ HE.StreamExists streamStreamName

  Log.debug $ "create shards for stream " <> Log.build streamStreamName <> ": " <> Log.buildString' (show shards)
  return stream{API.streamCreationTime = Just $ nsTimestampToProto timeStamp}

deleteStream :: ServerContext
             -> API.DeleteStreamRequest
             -> IO ()
deleteStream ServerContext{..} API.DeleteStreamRequest{deleteStreamRequestForce = force,
  deleteStreamRequestStreamName = sName, ..} = do
  storeExists <- S.doesStreamExist scLDClient streamId
  if storeExists
     then doDelete
     else unless deleteStreamRequestIgnoreNonExist $ throwIO $ HE.StreamNotFound sName
  where
    streamId = S.transToStreamName sName
    doDelete = do
      subs <- P.getSubscriptionWithStream metaHandle sName
      if null subs
      then do S.removeStream scLDClient streamId
              Stats.stream_stat_erase scStatsHolder (textToCBytes sName)
#ifdef HStreamEnableSchema
              P.unregisterSchema metaHandle sName
#endif
      else if force
           then do
             -- TODO:
             -- 1. delete the archived stream when the stream is no longer needed
             -- 2. erase stats for archived stream
             _archivedStream <- S.archiveStream scLDClient streamId
             P.updateSubscription metaHandle sName (cBytesToText $ S.getArchivedStreamName _archivedStream)
#ifdef HStreamEnableSchema
             P.unregisterSchema metaHandle sName
#endif
           else
             throwIO HE.FoundSubscription

-- NOTE:
-- 1. do not support archive stream
deleteStreamV2
  :: ServerContext -> Slot.SlotConfig
  -> API.DeleteStreamRequest -> IO ()
deleteStreamV2 ServerContext{..} slotConfig
               API.DeleteStreamRequest{ deleteStreamRequestForce = force
                                      , deleteStreamRequestStreamName = sName
                                      , ..
                                      } = do
  storeExists <- Slot.doesSlotExist slotConfig streamName
  if storeExists
     then doDelete
     else unless deleteStreamRequestIgnoreNonExist $ throwIO $ HE.StreamNotFound sName
  where
    streamName = textToCBytes sName
    -- TODO: archive stream
    doDelete = do
      subs <- P.getSubscriptionWithStream metaHandle sName
      if null subs
         then deallocate
         else if force then deallocate else throwIO HE.FoundSubscription
    deallocate = do
      logids <- Slot.deallocateSlot slotConfig streamName
      -- delete all data in the logid
      forM_ logids $ S.trimLast scLDClient
      Stats.stream_stat_erase scStatsHolder (textToCBytes sName)

getStream :: ServerContext -> API.GetStreamRequest -> IO API.GetStreamResponse
getStream ServerContext{..} API.GetStreamRequest{ getStreamRequestName = sName} = do
  let streamId = S.transToStreamName sName
  storeExists <- S.doesStreamExist scLDClient streamId
  unless storeExists $ throwIO $ HE.StreamNotFound sName
  attrs <- S.getStreamLogAttrs scLDClient streamId
  let reFac = fromMaybe 0 . S.attrValue . S.logReplicationFactor $ attrs
      backlogSec = fromMaybe 0 . fromMaybe Nothing . S.attrValue . S.logBacklogDuration $ attrs
      createdAt = PT.fromByteString . BSL.toStrict . cBytesToLazyByteString $ S.logAttrsExtras attrs M.! "createTime"
  shardsCount <- fromIntegral . M.size <$> S.listStreamPartitions scLDClient streamId
  return API.GetStreamResponse {
      getStreamResponseStream = Just API.Stream{
          streamStreamName = sName
        , streamReplicationFactor = fromIntegral reFac
        , streamBacklogDuration = fromIntegral backlogSec
        , streamCreationTime = either (const Nothing) Just createdAt
        , streamShardCount =  shardsCount
        }
      }

listStreams
  :: HasCallStack
  => ServerContext
  -> API.ListStreamsRequest
  -> IO (V.Vector API.Stream)
listStreams sc@ServerContext{..} API.ListStreamsRequest = do
  streams <- S.findStreams scLDClient S.StreamTypeStream
  V.forM (V.fromList streams) (getStreamInfo sc)

listStreamsWithPrefix
  :: HasCallStack
  => ServerContext
  -> API.ListStreamsWithPrefixRequest
  -> IO (V.Vector API.Stream)
listStreamsWithPrefix sc@ServerContext{..} API.ListStreamsWithPrefixRequest{..} = do
  streams <- filter (T.isPrefixOf listStreamsWithPrefixRequestPrefix . T.pack . S.showStreamName) <$> S.findStreams scLDClient S.StreamTypeStream
  V.forM (V.fromList streams) (getStreamInfo sc)

trimStream
  :: HasCallStack
  => ServerContext
  -> T.Text
  -> API.StreamOffset
  -> IO ()
trimStream ServerContext{..} streamName trimPoint = do
  streamExists <- S.doesStreamExist scLDClient streamId
  unless streamExists $ do
    Log.info $ "trimStream failed because stream " <> Log.build streamName <> " is not found."
    throwIO $ HE.StreamNotFound $ "stream " <> T.pack (show streamName) <> " is not found."
  shards <- M.elems <$> S.listStreamPartitions scLDClient streamId
  concurrentCap <- getNumCapabilities
  void $ limitedMapConcurrently (min 8 concurrentCap) (\shardId -> getTrimLSN scLDClient shardId trimPoint >>= S.trim scLDClient shardId) shards
 where
   streamId = S.transToStreamName streamName

data Rid = Rid
  { rShardId  :: Word64
  , rBatchId  :: Word64
  , rBatchIdx :: Word32
  } deriving (Eq)

instance Ord Rid where
  Rid{rShardId=rs1, rBatchId=rb1, rBatchIdx=rbx1} <= Rid{rShardId=rs2, rBatchId=rb2, rBatchIdx=rbx2}
    | rs1 /= rs2 = rs1 <= rs2
    | rb1 /= rb2 = rb1 <= rb2
    | otherwise = rbx1 <= rbx2

instance Show Rid where
  show Rid{..} = show rShardId <> "-" <> show rBatchId <> "-" <> show rBatchIdx

mkRid :: T.Text -> Either String Rid
mkRid r = case AP.parseOnly parseRid r of
  Right res -> Right res
  Left e    -> Left $ show r <> " is a invalid recordId: " <> show e
 where
   parseRid = do shardId <- AP.decimal
                 _ <- AP.char '-'
                 batchId <- AP.decimal
                 _ <- AP.char '-'
                 batchIndex <- AP.decimal
                 AP.endOfInput
                 return $ Rid shardId batchId batchIndex

trimShards
  :: HasCallStack
  => ServerContext
  -> T.Text
  -> Vector T.Text
  -> IO (M.Map Word64 T.Text)
trimShards ServerContext{..} streamName recordIds = do
  let rids = V.toList $ V.map mkRid recordIds
      (emsgs, rids') = partitionEithers rids
  unless (null emsgs) $ do
    Log.fatal $ "parse recordId error: " <> Log.build (show emsgs)
    throwIO . HE.InvalidRecordId $ show emsgs

  -- remove Rids with batchId == 0, which refer to the Earliest Position of a shard
  let ridWithoutEarliest = filter (\Rid{..} -> rBatchId /= 0) $ rids'
  -- Group rids by shardId.
  -- Since we call sort first, after groupBy, elements in each group are sorted,
  -- which means the head of elements in each group is the min RecordId of the shard
  let points = map head $ L.groupBy (\Rid{rShardId=rs1} Rid{rShardId=rs2} -> rs1 == rs2) $ L.sort ridWithoutEarliest
  Log.info $ "min recordIds for stream " <> Log.build streamName <> ": " <> Log.build (show points)

  let streamId = S.transToStreamName streamName
  shards <- M.elems <$> S.listStreamPartitions scLDClient streamId
  concurrentCap <- getNumCapabilities
  (errors, res) <- partitionEithers <$> limitedMapConcurrently (min 8 concurrentCap) (trim shards) points
  if null errors
    then return $ M.fromList res
    else throwIO @HE.SomeHStreamException . fromJust . fromException $ head errors
 where
   trim shards r@Rid{..}
     | rShardId `elem` shards = do
         try (S.trim scLDClient rShardId (rBatchId - 1)) >>= \case
           Left (e:: SomeException)
             | Just e' <- fromException @S.TOOBIG e -> do
                 Log.warning $ "trim shard " <> Log.build rShardId <> " with stream " <> Log.build streamName
                            <> " return error: " <> Log.build (displayException e')
                 return . Left . toException . HE.InvalidRecordId $ "recordId " <> show r <> " is beyond the tail of log: " <> displayException e'
             | otherwise -> do
                 Log.warning $ "trim shard " <> Log.build rShardId <> " with stream " <> Log.build streamName
                            <> " return error: " <> Log.build (displayException e)
                 return . Left . toException . HE.SomeStoreInternal $ "trim shard with recordId " <> show r <> " error: " <> displayException e
           Right _ -> do
             Log.info $ "trim to " <> Log.build (show $ rBatchId - 1)
                     <> " for shard " <> Log.build (show rShardId)
                     <> ", stream " <> Log.build streamName
             return . Right $ (rShardId, T.pack . show $ r)
     | otherwise = do
         Log.warning $ "trim shards error, shard " <> Log.build rShardId <> " doesn't belong to stream " <> Log.build streamName
         return . Left . toException . HE.ShardNotExists $ "shard " <> show rShardId <> " doesn't belong to stream " <> show streamName

getStreamInfo :: ServerContext -> S.StreamId -> IO API.Stream
getStreamInfo ServerContext{..} stream = do
    attrs <- S.getStreamLogAttrs scLDClient stream
    -- FIXME: should the default value be 0?
    let r = fromMaybe 0 . S.attrValue . S.logReplicationFactor $ attrs
        b = fromMaybe 0 . fromMaybe Nothing . S.attrValue . S.logBacklogDuration $ attrs
        extraAttr = getCreateTime $ S.logAttrsExtras attrs
    shardCnt <- length <$> S.listStreamPartitions scLDClient stream
    return $ API.Stream (T.pack . S.showStreamName $ stream) (fromIntegral r) (fromIntegral b) (fromIntegral shardCnt) extraAttr
 where
   getCreateTime :: M.Map CB.CBytes CB.CBytes -> Maybe Timestamp
   getCreateTime attr = M.lookup "createTime" attr >>= \tmp -> do
     case PT.fromByteString . BSL.toStrict . cBytesToLazyByteString $ tmp of
       Left _          -> Nothing
       Right timestamp -> Just timestamp

getTailRecordId :: ServerContext -> API.GetTailRecordIdRequest -> IO API.GetTailRecordIdResponse
getTailRecordId ServerContext{..} API.GetTailRecordIdRequest{getTailRecordIdRequestShardId=sId} = do
  -- FIXME: this should be 'S.doesStreamPartitionValExist', however, at most
  -- time S.logIdHasGroup should also work, and is faster than
  -- 'S.doesStreamPartitionValExist'
  shardExists <- S.logIdHasGroup scLDClient sId
  unless shardExists $ throwIO $ HE.ShardNotFound $ "Shard with id " <> T.pack (show sId) <> " is not found."
  lsn <- S.getTailLSN scLDClient sId
  let recordId = API.RecordId { recordIdShardId    = sId
                              , recordIdBatchId    = lsn
                              , recordIdBatchIndex = 0
                              }
  return $ API.GetTailRecordIdResponse { getTailRecordIdResponseTailRecordId = Just recordId}

getTailRecordIdV2
  :: ServerContext
  -> Slot.SlotConfig
  -> API.GetTailRecordIdRequest -> IO API.GetTailRecordIdResponse
getTailRecordIdV2 ServerContext{..} slotConfig API.GetTailRecordIdRequest{..} = do
  let streamName = textToCBytes getTailRecordIdRequestStreamName
      sId = getTailRecordIdRequestShardId
  shardExists <- Slot.doesSlotValueExist slotConfig streamName sId
  unless shardExists $ throwIO $ HE.ShardNotFound $
       "Stream " <> getTailRecordIdRequestStreamName
    <> " with shard id " <> T.pack (show sId) <> " is not found."
  lsn <- S.getTailLSN scLDClient sId
  let recordId = API.RecordId { recordIdShardId    = sId
                              , recordIdBatchId    = lsn
                              , recordIdBatchIndex = 0
                              }
  return $ API.GetTailRecordIdResponse { getTailRecordIdResponseTailRecordId = Just recordId}

appendStream :: HasCallStack
             => ServerContext
             -> T.Text
             -> Word64
             -> API.BatchedRecord
             -> IO API.AppendResponse
appendStream ServerContext{..} streamName shardId record = do
  let payload = encodBatchRecord record
      recordSize = API.batchedRecordBatchSize record
      payloadSize = BS.length payload
  when (payloadSize > scMaxRecordSize) $ throwIO $ HE.InvalidRecordSize payloadSize

  state <- readIORef serverState
  S.AppendCompletion{..} <- case state of
    ServerNormal -> do
      Stats.handle_time_series_add_queries_in scStatsHolder "append" 1
      Stats.stream_stat_add_append_total scStatsHolder cStreamName 1
      Stats.stream_time_series_add_append_in_requests scStatsHolder cStreamName 1

      !append_start <- getPOSIXTime
      appendRes <- S.appendCompressedBS scLDClient shardId payload cmpStrategy Nothing `catch` record_failed

      Stats.serverHistogramAdd scStatsHolder Stats.SHL_AppendLatency =<< msecSince append_start
      Stats.stream_stat_add_append_in_bytes scStatsHolder cStreamName (fromIntegral payloadSize)
      Stats.stream_stat_add_append_in_records scStatsHolder cStreamName (fromIntegral recordSize)
      Stats.stream_time_series_add_append_in_bytes scStatsHolder cStreamName (fromIntegral payloadSize)
      Stats.stream_time_series_add_append_in_records scStatsHolder cStreamName (fromIntegral recordSize)
      return appendRes
    ServerBackup -> do
      DB.writeRecord cacheStore streamName shardId payload

  let rids = V.zipWith (API.RecordId shardId) (V.replicate (fromIntegral recordSize) appendCompLSN) (V.fromList [0..])
  return $ API.AppendResponse
    { appendResponseStreamName = streamName
    , appendResponseShardId    = shardId
    , appendResponseRecordIds  = rids
    }
 where
   cStreamName = textToCBytes streamName
   record_failed (e :: S.SomeHStoreException) = do
     Stats.stream_stat_add_append_failed scStatsHolder cStreamName 1
     Stats.stream_time_series_add_append_failed_requests scStatsHolder cStreamName 1
     throwIO e

listShards
  :: HasCallStack
  => ServerContext
  -> API.ListShardsRequest
  -> IO (V.Vector API.Shard)
listShards ServerContext{..} API.ListShardsRequest{..} = do
  shards <- M.elems <$> S.listStreamPartitions scLDClient streamId
  V.foldM' getShardInfo V.empty $ V.fromList shards
 where
   streamId = S.transToStreamName listShardsRequestStreamName
   startKey = "startKey"
   endKey   = "endKey"
   epoch    = "epoch"

   getShardInfo shards logId = do
     attr <- S.getStreamPartitionExtraAttrs scLDClient logId
     case getInfo attr of
       -- FIXME: should raise an exception when get Nothing
       Nothing -> return shards
       Just(sKey, eKey, ep) -> return . V.snoc shards $
         API.Shard { API.shardStreamName        = listShardsRequestStreamName
                   , API.shardShardId           = logId
                   , API.shardStartHashRangeKey = sKey
                   , API.shardEndHashRangeKey   = eKey
                   , API.shardEpoch             = ep
                   -- FIXME: neet a way to find if this shard is active
                   , API.shardIsActive          = True
                   }

   getInfo mp = do
     startHashRangeKey <- cBytesToText <$> M.lookup startKey mp
     endHashRangeKey   <- cBytesToText <$> M.lookup endKey mp
     shardEpoch        <- read . CB.unpack <$> M.lookup epoch mp
     return (startHashRangeKey, endHashRangeKey, shardEpoch)

listShardsV2
  :: HasCallStack
  => ServerContext
  -> Slot.SlotConfig
  -> API.ListShardsRequest
  -> IO (V.Vector API.Shard)
listShardsV2 ServerContext{..} slotConfig API.ListShardsRequest{..} = do
  let streamName = textToCBytes listShardsRequestStreamName
  Slot.Slot{..} <- Slot.getSlotByName slotConfig streamName
  V.foldM' getShardInfo V.empty (V.fromList $ M.toList slotVals)
 where
   startKey = "startKey"
   endKey   = "endKey"
   epoch    = "epoch"

   getShardInfo shards (logId, m_attr) = do
     case getInfo m_attr of
       -- FIXME: should raise an exception when get Nothing
       Nothing -> return shards
       Just (sKey, eKey, ep) -> return . V.snoc shards $
         API.Shard{ API.shardStreamName        = listShardsRequestStreamName
                  , API.shardShardId           = logId
                  , API.shardStartHashRangeKey = sKey
                  , API.shardEndHashRangeKey   = eKey
                  , API.shardEpoch             = ep
                  -- FIXME: neet a way to find if this shard is active
                  , API.shardIsActive          = True
                  }

   getInfo m_mp = do
     Slot.SlotValueAttrs mp <- m_mp
     startHashRangeKey <- M.lookup startKey mp
     endHashRangeKey   <- M.lookup endKey mp
     shardEpoch        <- read . T.unpack <$> M.lookup epoch mp
     return (startHashRangeKey, endHashRangeKey, shardEpoch)

trimShard
  :: HasCallStack
  => ServerContext
  -> Word64
  -> API.ShardOffset
  -> IO ()
trimShard ServerContext{..} shardId trimPoint = do
  shardExists <- S.logIdHasGroup scLDClient shardId
  unless shardExists $ do
    Log.info $ "trimShard failed because shard " <> Log.build shardId <> " is not exist."
    throwIO $ HE.ShardNotFound $ "Shard with id " <> T.pack (show shardId) <> " is not found."
  getTrimLSN scLDClient shardId trimPoint >>= S.trim scLDClient shardId

--------------------------------------------------------------------------------
-- helper

getTrimLSN :: (ToOffset g, Show g) => S.LDClient -> Word64 -> g -> IO S.LSN
getTrimLSN client shardId trimPoint = do
  lsn <- getLSN client shardId (toOffset trimPoint)
  Log.info $ "getTrimLSN for shard " <> Log.build (show shardId)
          <> ", trimPoint: " <> Log.build (show trimPoint)
          <> ", lsn: " <> Log.build (show lsn)
  return lsn
 where
  getLSN :: S.LDClient -> S.C_LogID -> ServerInternalOffset -> IO S.LSN
  getLSN scLDClient logId offset =
    case offset of
      OffsetEarliest -> return S.LSN_MIN
      OffsetLatest -> S.getTailLSN scLDClient logId
      OffsetRecordId API.RecordId{..} -> return recordIdBatchId
      OffsetTimestamp API.TimestampOffset{..} -> do
        let accuracy = if timestampOffsetStrictAccuracy then S.FindKeyStrict else S.FindKeyApproximate
        S.findTime scLDClient logId timestampOffsetTimestampInMs accuracy

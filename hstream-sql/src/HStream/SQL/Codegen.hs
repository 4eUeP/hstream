{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE StrictData        #-}

module HStream.SQL.Codegen where

import           Data.Aeson                                      (Object,
                                                                  Value (Bool, Number, String),
                                                                  encode)
import qualified Data.ByteString.Char8                           as BS
import qualified Data.ByteString.Lazy                            as BSL
import qualified Data.HashMap.Strict                             as HM
import qualified Data.List                                       as L
import           Data.Scientific                                 (fromFloatDigits,
                                                                  scientific)
import           Data.Text                                       (pack)
import qualified Data.Text                                       as T
import           Data.Time                                       (diffTimeToPicoseconds,
                                                                  showGregorian)
import qualified Database.ClickHouseDriver.Types                 as Clickhouse
import qualified Database.MySQL.Base                             as MySQL
import           Numeric                                         (showHex)
import           RIO
import qualified RIO.ByteString.Lazy                             as BL
import qualified Z.Data.CBytes                                   as CB
import           Z.IO.Time                                       (SystemTime (MkSystemTime),
                                                                  getSystemTime')

import           HStream.Processing.Processor                    (Record (..),
                                                                  TaskBuilder)
import           HStream.Processing.Store                        (mkInMemoryStateKVStore,
                                                                  mkInMemoryStateSessionStore,
                                                                  mkInMemoryStateTimestampedKVStore)
import           HStream.Processing.Stream                       (Materialized (..),
                                                                  Stream,
                                                                  StreamBuilder,
                                                                  StreamJoined (..),
                                                                  StreamSinkConfig (..),
                                                                  StreamSourceConfig (..))
import qualified HStream.Processing.Stream                       as HS
import qualified HStream.Processing.Stream.GroupedStream         as HG
import           HStream.Processing.Stream.JoinWindows           (JoinWindows (..))
import qualified HStream.Processing.Stream.SessionWindowedStream as HSW
import           HStream.Processing.Stream.SessionWindows        (mkSessionWindows)
import qualified HStream.Processing.Stream.TimeWindowedStream    as HTW
import           HStream.Processing.Stream.TimeWindows           (TimeWindowKey (..),
                                                                  mkHoppingWindow,
                                                                  mkTumblingWindow,
                                                                  timeWindowKeySerde)
import qualified HStream.Processing.Table                        as HT
import qualified HStream.Processing.Type                         as HPT
import           HStream.SQL.AST                                 hiding
                                                                 (StreamName)
import           HStream.SQL.Codegen.Boilerplate                 (objectSerde)
import           HStream.SQL.Codegen.Utils                       (binOpOnValue,
                                                                  compareValue,
                                                                  composeColName,
                                                                  diffTimeToMs,
                                                                  genJoiner,
                                                                  genRandomSinkStream,
                                                                  getFieldByName,
                                                                  unaryOpOnValue)
import           HStream.SQL.Exception                           (SomeSQLException (..),
                                                                  throwSQLException)
import           HStream.SQL.Parse                               (parseAndRefine)
import           HStream.Utils                                   (genUnique)

--------------------------------------------------------------------------------

type StreamName     = HPT.StreamName
type ViewName = T.Text
type ConnectorName  = T.Text
type SourceStream   = [StreamName]
type SinkStream     = StreamName
type CheckIfExist  = Bool
type ViewSchema = [String]
type OtherOptions = [(Text,Constant)]

data ShowObject = SStreams | SQueries | SConnectors | SViews
data DropObject = DStream Text | DView Text
data TerminationSelection = AllQuery | OneQuery CB.CBytes
data InsertType = JsonFormat | RawFormat

data ConnectorConfig
  = ClickhouseConnector Clickhouse.ConnParams
  | MySqlConnector MySQL.ConnectInfo

data ExecutionPlan
  = SelectPlan          SourceStream SinkStream TaskBuilder
  | CreatePlan          StreamName Int
  | CreateSinkConnectorPlan ConnectorName Bool StreamName ConnectorConfig OtherOptions
  | CreateBySelectPlan  SourceStream SinkStream TaskBuilder Int
  | CreateViewPlan      ViewSchema SourceStream SinkStream TaskBuilder Int (Materialized Object Object)
  | InsertPlan          StreamName InsertType BL.ByteString
  | DropPlan            CheckIfExist DropObject
  | ShowPlan            ShowObject
  | TerminatePlan       TerminationSelection
  | SelectViewPlan      RSelectView

--------------------------------------------------------------------------------

streamCodegen :: HasCallStack => Text -> IO ExecutionPlan
streamCodegen input = do
  rsql <- parseAndRefine input
  case rsql of
    RQSelect select                     -> do
      tName <- genTaskName
      (builder, source, sink, _) <- genStreamBuilderWithStream tName Nothing select
      return $ SelectPlan source sink (HS.build builder)
    RQCreate (RCreateAs stream select rOptions) -> do
      tName <- genTaskName
      (builder, source, sink, _) <- genStreamBuilderWithStream tName (Just stream) select
      return $ CreateBySelectPlan source sink (HS.build builder) (rRepFactor rOptions)
    RQCreate (RCreateView view select@(RSelect sel _ _ _ _)) -> do
      tName <- genTaskName
      (builder, source, sink, Just mat) <- genStreamBuilderWithStream tName (Just view) select
      let schema = case sel of
            RSelAsterisk -> throwSQLException CodegenException Nothing "Impossible happened"
            RSelList fields -> map snd fields
      return $ CreateViewPlan schema source sink (HS.build builder) 1 mat
    RQCreate (RCreate stream rOptions) -> return $ CreatePlan stream (rRepFactor rOptions)
    RQCreate rCreateSinkConnector -> return $ genCreateSinkConnectorPlan rCreateSinkConnector
    RQInsert (RInsert stream tuples)   -> return $ InsertPlan stream JsonFormat (encode $ HM.fromList $ second constantToValue <$> tuples)
    RQInsert (RInsertBinary stream bs) -> return $ InsertPlan stream RawFormat  (BSL.fromStrict bs)
    RQInsert (RInsertJSON stream bs)   -> return $ InsertPlan stream JsonFormat (BSL.fromStrict bs)
    RQShow (RShow RShowStreams)        -> return $ ShowPlan SStreams
    RQShow (RShow RShowQueries)        -> return $ ShowPlan SQueries
    RQShow (RShow RShowConnectors)     -> return $ ShowPlan SConnectors
    RQShow (RShow RShowViews)          -> return $ ShowPlan SViews
    RQDrop (RDrop RDropStream x)       -> return $ DropPlan False (DStream x)
    RQDrop (RDrop RDropView x)         -> return $ DropPlan False (DView x)
    RQDrop (RDropIf RDropStream x)     -> return $ DropPlan True (DStream x)
    RQDrop (RDropIf RDropView x)       -> return $ DropPlan True (DView x)
    RQTerminate (RTerminateQuery qid)  -> return $ TerminatePlan (OneQuery $ CB.pack qid)
    RQTerminate RTerminateAll          -> return $ TerminatePlan AllQuery
    RQSelectView rSelectView           -> return $ SelectViewPlan rSelectView

--------------------------------------------------------------------------------

genCreateSinkConnectorPlan :: RCreate -> ExecutionPlan
genCreateSinkConnectorPlan (RCreateSinkConnector cName ifNotExist sName connectorType (RConnectorOptions cOptions)) =
  case connectorType of
    "clickhouse" -> CreateSinkConnectorPlan cName ifNotExist sName (ClickhouseConnector createClickhouseSinkConnector) []
    "mysql" -> CreateSinkConnectorPlan cName ifNotExist sName (MySqlConnector createMysqlSinkConnector) []
    _ -> throwSQLException CodegenException Nothing "Connector type not supported"
  where
    extractInt = \case Just (ConstantInt s) -> Just s; _ -> Nothing
    extractString = \case Just (ConstantString s) -> Just s; _ -> Nothing
    getStringValue field value = fromMaybe value $ extractString (lookup field cOptions)
    getByteStringValue = (BS.pack .) . getStringValue
    createClickhouseSinkConnector = Clickhouse.ConnParams
      (getByteStringValue "username" "default")
      (getByteStringValue "host" "127.0.0.1")
      (getByteStringValue "port" "9000")
      (getByteStringValue "password" "")
      False (getByteStringValue "database" "default")
    createMysqlSinkConnector = MySQL.ConnectInfo
      (getStringValue "host" "127.0.0.1")
      (fromIntegral . fromMaybe 3306 . extractInt $ lookup "port" cOptions)
      (getByteStringValue "database" "mysql")
      (getByteStringValue "username" "root")
      (getByteStringValue "password" "password") 33
genCreateSinkConnectorPlan _ =
  throwSQLException CodegenException Nothing "Implementation: Wrong function called"

----
type SourceConfigType = HS.StreamSourceConfig Object Object
genStreamSourceConfig :: RFrom -> (SourceConfigType, Maybe SourceConfigType)
genStreamSourceConfig frm =
  let boilerplate = HS.StreamSourceConfig "" objectSerde objectSerde
   in case frm of
        RFromSingle s -> (boilerplate {sscStreamName = s}, Nothing)
        RFromJoin (s1,_) (s2,_) _ _ ->
          ( boilerplate {sscStreamName = s1}
          , Just $ boilerplate {sscStreamName = s2}
          )

defaultTimeWindowSize :: Int64
defaultTimeWindowSize = 3000

data SinkConfigType = SinkConfigType SinkStream (HS.StreamSinkConfig Object Object)
                    | SinkConfigTypeWithWindow SinkStream (HS.StreamSinkConfig (TimeWindowKey Object) Object)

genStreamSinkConfig :: Maybe StreamName -> RGroupBy -> IO SinkConfigType
genStreamSinkConfig sinkStream' grp = do
  stream <- maybe genRandomSinkStream return sinkStream'
  case grp of
    RGroupBy _ _ (Just _) ->
      return $ SinkConfigTypeWithWindow stream HS.StreamSinkConfig
      { sicStreamName = stream
      , sicKeySerde = timeWindowKeySerde objectSerde defaultTimeWindowSize
      , sicValueSerde = objectSerde
      }
    _ ->
      return $ SinkConfigType stream HS.StreamSinkConfig
      { sicStreamName  = stream
      , sicKeySerde   = objectSerde
      , sicValueSerde = objectSerde
      }

genStreamJoinedConfig :: IO (HS.StreamJoined Object Object Object Object)
genStreamJoinedConfig = do
  store1 <- mkInMemoryStateTimestampedKVStore
  store2 <- mkInMemoryStateTimestampedKVStore
  return HS.StreamJoined
    { sjK1Serde    = objectSerde
    , sjV1Serde    = objectSerde
    , sjK2Serde    = objectSerde
    , sjV2Serde    = objectSerde
    , sjThisStore  = store1
    , sjOtherStore = store2
    }

genJoinWindows :: RJoinWindow -> JoinWindows
genJoinWindows diffTime =
  let defaultGraceMs = 3600 * 1000
      windowWidth = diffTimeToMs  diffTime
   in JoinWindows
      { jwBeforeMs = windowWidth
      , jwAfterMs  = windowWidth
      , jwGraceMs  = defaultGraceMs
      }

genKeySelector :: FieldName -> Record Object Object -> Object
genKeySelector field Record{..} =
  HM.singleton "SelectedKey" $ (HM.!) recordValue field

type TaskName = Text
genStreamWithSourceStream :: HasCallStack => TaskName -> RFrom -> IO (Stream Object Object, SourceStream)
genStreamWithSourceStream taskName frm = do
  let (srcConfig1, srcConfig2') = genStreamSourceConfig frm
  baseStream <- HS.mkStreamBuilder taskName >>= HS.stream srcConfig1
  case frm of
    RFromSingle _                     -> return (baseStream, [sscStreamName srcConfig1])
    RFromJoin (s1,f1) (s2,f2) typ win ->
      case srcConfig2' of
        Nothing         ->
          throwSQLException CodegenException Nothing "Impossible happened"
        Just srcConfig2 ->
          case typ of
            RJoinInner -> do
              anotherStream <- HS.mkStreamBuilder "" >>= HS.stream srcConfig2
              streamJoined  <- genStreamJoinedConfig
              joinedStream  <- HS.joinStream anotherStream (genJoiner s1 s2)
                                 (genKeySelector f1) (genKeySelector f2)
                                 (genJoinWindows win) streamJoined
                                 baseStream
              return (joinedStream, [sscStreamName srcConfig1, sscStreamName srcConfig2])
            _          ->
              throwSQLException CodegenException Nothing "Impossible happened"

genTaskName :: IO Text
-- Please do not encode the this id to other forms,
-- since there is a minor issue related with parsing.
-- When parsing a identifier, the first letter is required to be a letter.
-- When parsing a string, quotes are required.
-- Currently there is no way to parse an id start with digit but contains letters/
genTaskName = pack . show <$> genUnique

----
constantToValue :: Constant -> Value
constantToValue (ConstantInt n)         = Number (scientific (toInteger n) 0)
constantToValue (ConstantNum n)         = Number (fromFloatDigits n)
constantToValue (ConstantString s)      = String (pack s)
constantToValue (ConstantBool b)        = Bool b
constantToValue (ConstantDate day)      = String (pack $ showGregorian day) -- FIXME: No suitable type in `Value`
constantToValue (ConstantTime diff)     = Number (scientific (diffTimeToPicoseconds diff) (-12)) -- FIXME: No suitable type in `Value`
constantToValue (ConstantInterval diff) = Number (scientific (diffTimeToPicoseconds diff) (-12)) -- FIXME: No suitable type in `Value`

-- May raise exceptions
genRExprValue :: HasCallStack => RValueExpr -> Object -> (Text, Value)
genRExprValue (RExprCol name stream' field) o = (pack name, getFieldByName o (composeColName stream' field))
genRExprValue (RExprConst name constant)          _ = (pack name, constantToValue constant)
genRExprValue (RExprBinOp name op expr1 expr2)    o =
  let (_,v1) = genRExprValue expr1 o
      (_,v2) = genRExprValue expr2 o
   in (pack name, binOpOnValue op v1 v2)
genRExprValue (RExprUnaryOp name op expr) o =
  let (_,v) = genRExprValue expr o
  in (pack name, unaryOpOnValue op v)
genRExprValue (RExprAggregate _ _) _ =
  throwSQLException CodegenException Nothing "Impossible happened"

genFilterR :: RWhere -> Record Object Object -> Bool
genFilterR RWhereEmpty _ = True
genFilterR (RWhere cond) record@Record{..} =
  case cond of
    RCondOp op expr1 expr2 ->
      let (_,v1) = genRExprValue expr1 recordValue
          (_,v2) = genRExprValue expr2 recordValue
       in case op of
            RCompOpEQ  -> v1 == v2
            RCompOpNE  -> v1 /= v2
            RCompOpLT  -> case compareValue v1 v2 of
                            LT -> True
                            _  -> False
            RCompOpGT  -> case compareValue v1 v2 of
                            GT -> True
                            _  -> False
            RCompOpLEQ -> case compareValue v1 v2 of
                            GT -> False
                            _  -> True
            RCompOpGEQ -> case compareValue v1 v2 of
                            LT -> False
                            _  -> True
    RCondOr cond1 cond2    ->
      genFilterR (RWhere cond1) record || genFilterR (RWhere cond2) record
    RCondAnd cond1 cond2   ->
      genFilterR (RWhere cond1) record && genFilterR (RWhere cond2) record
    RCondNot cond1         ->
      not $ genFilterR (RWhere cond1) record
    RCondBetween expr1 expr expr2 ->
      let (_,v1)    = genRExprValue expr1 recordValue
          (_,v)     = genRExprValue expr recordValue
          (_,v2)    = genRExprValue expr2 recordValue
          ordering1 = compareValue v1 v
          ordering2 = compareValue v v2
       in case ordering1 of
            GT -> False
            _  -> case ordering2 of
                    GT -> False
                    _  -> True

genFilterNode :: RWhere -> Stream Object Object -> IO (Stream Object Object)
genFilterNode = HS.filter . genFilterR

----
genMapR :: RSel -> Record Object Object -> Record Object Object
genMapR RSelAsterisk record = record
genMapR (RSelList exprsWithAlias) record@Record{..} =
  record { recordValue = HM.fromList scalarValues }
  where
    scalars      = L.filter (\(e,_) -> isLeft e) exprsWithAlias
    scalarValues = (\(Left expr,alias) -> let (_,v) = genRExprValue expr recordValue in (pack alias,v)) <$> exprsWithAlias

genTimeWindowKeyMapR :: RSel
                     -> Record (TimeWindowKey Object) Object
                     -> Record (TimeWindowKey Object) Object
genTimeWindowKeyMapR RSelAsterisk record = record
genTimeWindowKeyMapR (RSelList exprsWithAlias) record@Record{..} =
  record { recordValue = HM.filterWithKey (\k _ -> k `L.elem` aliases) recordValue }
  where aliases = pack <$> (snd <$> exprsWithAlias)

genMapNode :: RSel -> Stream Object Object -> IO (Stream Object Object)
genMapNode = HS.map . genMapR

genTimeWindowKeyMapNode :: RSel
                        -> Stream (TimeWindowKey Object) Object
                        -> IO (Stream (TimeWindowKey Object) Object)
genTimeWindowKeyMapNode rsel = HS.map (genTimeWindowKeyMapR rsel)

----
genMaterialized :: HasCallStack => RGroupBy -> IO (HS.Materialized Object Object)
genMaterialized grp = do
  aggStore <- case grp of
    RGroupByEmpty     ->
      throwSQLException CodegenException Nothing "Impossible happened"
    RGroupBy _ _ win' ->
      case win' of
        Just (RSessionWindow _) -> mkInMemoryStateSessionStore
        _                       -> mkInMemoryStateKVStore
  return $ HS.Materialized
           { mKeySerde   = objectSerde
           , mValueSerde = objectSerde
           , mStateStore = aggStore
           }

data AggregateComponents = AggregateCompontnts
  { aggregateInit   :: Object
  , aggregateF      :: Object -> Record Object Object -> Object
  , aggregateMergeF :: Object -> Object -> Object -> Object
  }

genAggregateComponents :: HasCallStack => RSel -> AggregateComponents
genAggregateComponents RSelAsterisk =
  throwSQLException CodegenException Nothing "SELECT * does not support GROUP BY clause"
genAggregateComponents (RSelList dcols) =
  fuseAggregateComponents $ genAggregateComponentsFromDerivedCol <$> dcols

genAggregateComponentsFromDerivedCol :: HasCallStack
                       => (Either RValueExpr Aggregate, FieldAlias)
                       -> AggregateComponents
genAggregateComponentsFromDerivedCol (Right agg, alias) =
  case agg of
    Nullary AggCountAll ->
      AggregateCompontnts
      { aggregateInit = HM.singleton (pack alias) (Number 0)
      , aggregateF    = \o _ -> HM.update (\(Number n) -> Just (Number $ n+1)) (pack alias) o
      , aggregateMergeF = \_ o1 o2 -> let (Number n1) = (HM.!) o1 (pack alias)
                                          (Number n2) = (HM.!) o2 (pack alias)
                                       in HM.singleton (pack alias) (Number $ n1+n2)
      }
    Unary AggCount (RExprCol _ stream' field) ->
      AggregateCompontnts
      { aggregateInit = HM.singleton (pack alias) (Number 0)
      , aggregateF = \o Record{..} ->
          case HM.lookup (composeColName stream' field) recordValue of
            Nothing -> o
            Just _  -> HM.update (\(Number n) -> Just (Number $ n+1)) (pack alias) o
      , aggregateMergeF = \_ o1 o2 -> let (Number n1) = (HM.!) o1 (pack alias)
                                          (Number n2) = (HM.!) o2 (pack alias)
                                       in HM.singleton (pack alias) (Number $ n1+n2)
      }
    Unary AggSum (RExprCol _ stream' field)   ->
      AggregateCompontnts
      { aggregateInit = HM.singleton (pack alias) (Number 0)
      , aggregateF = \o Record{..} ->
          case HM.lookup (composeColName stream' field) recordValue of
            Nothing         -> o
            Just (Number x) -> HM.update (\(Number n) -> Just (Number $ n+x)) (pack alias) o
            _               ->
              throwSQLException CodegenException Nothing "Only columns with Int or Number type can use SUM function"
      , aggregateMergeF = \_ o1 o2 -> let (Number n1) = (HM.!) o1 (pack alias)
                                          (Number n2) = (HM.!) o2 (pack alias)
                                       in HM.singleton (pack alias) (Number $ n1+n2)
      }
    Unary AggMax (RExprCol _ stream' field)   ->
      AggregateCompontnts
      { aggregateInit = HM.singleton (pack alias) (Number $ scientific (toInteger (minBound :: Int)) 0)
      , aggregateF = \o Record{..} ->
          case HM.lookup (composeColName stream' field) recordValue of
            Nothing         -> o
            Just (Number x) -> HM.update (\(Number n) -> Just (Number $ max n x)) (pack alias) o
            _               ->
              throwSQLException CodegenException Nothing "Only columns with Int or Number type can use MAX function"
      , aggregateMergeF = \_ o1 o2 -> let (Number n1) = (HM.!) o1 (pack alias)
                                          (Number n2) = (HM.!) o2 (pack alias)
                                       in HM.singleton (pack alias) (Number $ max n1 n2)
      }
    Unary AggMin (RExprCol _ stream' field)   ->
      AggregateCompontnts
      { aggregateInit = HM.singleton (pack alias) (Number $ scientific (toInteger (maxBound :: Int)) 0)
      , aggregateF = \o Record{..} ->
          case HM.lookup (composeColName stream' field) recordValue of
            Nothing         -> o
            Just (Number x) -> HM.update (\(Number n) -> Just (Number $ min n x)) (pack alias) o
            _               ->
              throwSQLException CodegenException Nothing "Only columns with Int or Number type can use MIN function"
      , aggregateMergeF = \_ o1 o2 -> let (Number n1) = (HM.!) o1 (pack alias)
                                          (Number n2) = (HM.!) o2 (pack alias)
                                       in HM.singleton (pack alias) (Number $ min n1 n2)
      }
    _                                         ->
      throwSQLException CodegenException Nothing ("Unsupported aggregate function: " <> show agg)
genAggregateComponentsFromDerivedCol (Left rexpr, alias) =
  AggregateCompontnts
  { aggregateInit = HM.singleton (pack alias) (Number 0)
  , aggregateF = \old record -> HM.adjust (\_ -> updateV record rexpr) (pack alias) old
  , aggregateMergeF = \_ _ o2 -> let v = (HM.!) o2 (pack alias) in HM.singleton (pack alias) v
  }
  where updateV Record{..} rexpr = let (_,v) = genRExprValue rexpr recordValue in v

fuseAggregateComponents :: [AggregateComponents] -> AggregateComponents
fuseAggregateComponents components =
  AggregateCompontnts
  { aggregateInit = HM.unions (aggregateInit <$> components)
  , aggregateF = \old record -> L.foldr (\f acc -> f acc record) old (aggregateF <$> components)
  , aggregateMergeF = \o o1 o2 -> HM.unions $ [ f o o1 o2 | f <- aggregateMergeF <$> components]
  }

genGroupByNode :: RSelect
               -> Stream Object Object
               -> IO (Either (Stream Object Object) (Stream (TimeWindowKey Object) Object), Materialized Object Object)
genGroupByNode (RSelect _ _ _ RGroupByEmpty _ ) s =
  throwSQLException CodegenException Nothing "Impossible happened"
genGroupByNode (RSelect sel _ _ grp@(RGroupBy stream' field win') _) s = do
  grped <- HS.groupBy
    (\record -> let col = composeColName stream' field
                 in HM.singleton col $ getFieldByName (recordValue record) col) s
  materialized <- genMaterialized grp
  let AggregateCompontnts{..} = genAggregateComponents sel
  case win' of
    Nothing                       -> do
      table  <- HG.aggregate aggregateInit aggregateF materialized grped
      stream <- HT.toStream table
      return (Left stream, materialized)
    Just (RTumblingWindow diff)   -> do
      timed  <- HG.timeWindowedBy (mkTumblingWindow (diffTimeToMs diff)) grped
      table  <- HTW.aggregate aggregateInit aggregateF materialized timed
      stream <- HT.toStream table
      return (Right stream, materialized)
    Just (RHoppingWIndow len hop) -> do
      timed  <- HG.timeWindowedBy (mkHoppingWindow (diffTimeToMs len) (diffTimeToMs hop)) grped
      table  <- HTW.aggregate aggregateInit aggregateF materialized timed
      stream <-  HT.toStream table
      return (Right stream, materialized)
    Just (RSessionWindow diff)    -> do
      timed  <- HG.sessionWindowedBy (mkSessionWindows (diffTimeToMs diff)) grped
      table  <- HSW.aggregate aggregateInit aggregateF aggregateMergeF materialized timed
      stream <- HT.toStream table
      return (Right stream, materialized)

----
genFilterRFromHaving :: RHaving -> Record Object Object -> Bool
genFilterRFromHaving RHavingEmpty   = const True
genFilterRFromHaving (RHaving cond) = genFilterR (RWhere cond)

genFilteRNodeFromHaving :: RHaving -> Stream Object Object -> IO (Stream Object Object)
genFilteRNodeFromHaving = HS.filter . genFilterRFromHaving

----
genStreamBuilderWithStream :: HasCallStack
                           => TaskName
                           -> Maybe StreamName
                           -> RSelect
                           -> IO (StreamBuilder, SourceStream, SinkStream, Maybe (Materialized Object Object))
genStreamBuilderWithStream taskName sinkStream' select@(RSelect sel frm whr grp hav) = do
  streamSinkConfig <- genStreamSinkConfig sinkStream' grp
  (s0, source)     <- genStreamWithSourceStream taskName frm
  s1               <- genFilterNode whr s0
  case grp of
    RGroupByEmpty -> do
      s2 <- genMapNode sel s1
      s3 <- genFilteRNodeFromHaving hav s2
      case streamSinkConfig of
        SinkConfigType sink sinkConfig -> do
          builder <- HS.to sinkConfig s3
          return (builder, source, sink, Nothing)
        _                              ->
          throwSQLException CodegenException Nothing "Impossible happened"
    _ -> do
      (s2, materialized) <- genGroupByNode select s1
      case streamSinkConfig of
        SinkConfigTypeWithWindow sink sinkConfig -> do
          case s2 of
            Right timeStream -> do
              s3 <- genTimeWindowKeyMapNode sel timeStream
              builder <- HS.to sinkConfig s3
              return (builder, source, sink, Just materialized)
            Left _ -> throwSQLException CodegenException Nothing "Expected timeStream but got stream"
        SinkConfigType sink sinkConfig -> do
          case s2 of
            Left stream -> do
              s3 <- genFilteRNodeFromHaving hav stream
              builder <- HS.to sinkConfig s3
              return (builder, source, sink, Just materialized)
            Right _ -> throwSQLException CodegenException Nothing "Expected stream but got timeStream"

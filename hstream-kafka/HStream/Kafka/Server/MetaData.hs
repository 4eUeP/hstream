module HStream.Kafka.Server.MetaData where

import           Data.Text                      (Text)
import           GHC.Stack                      (HasCallStack)
import           Z.Data.CBytes                  (CBytes)
import           ZooKeeper.Types                (ZHandle)

import           HStream.Common.Server.MetaData
import           HStream.Common.ZookeeperClient (ZookeeperClient)
import           HStream.Kafka.Common.AclEntry
import           HStream.Kafka.Common.AclStore  ()
import           HStream.MetaStore.Types
import qualified HStream.ThirdParty.Protobuf    as Proto
import           HStream.Utils                  (textToCBytes)

-- FIXME: Some metadata still use hstream's 'rootPath' instead of 'kafkaRootPath'

kafkaZkPaths :: [CBytes]
kafkaZkPaths =
  [ textToCBytes rootPath
  , textToCBytes kafkaRootPath
  , textToCBytes $ myRootPath @Proto.Timestamp @ZookeeperClient
  , textToCBytes $ myRootPath @TaskAllocation @ZookeeperClient
  , textToCBytes $ myRootPath @GroupMetadataValue @ZookeeperClient
  , textToCBytes $ myRootPath @AclResourceNode @ZookeeperClient
  ]

kafkaRqTables :: [Text]
kafkaRqTables =
  [ myRootPath @TaskAllocation @RHandle
  , myRootPath @GroupMetadataValue @RHandle
  , myRootPath @Proto.Timestamp @RHandle
  , myRootPath @AclResourceNode @RHandle
  ]

kafkaFileTables :: [Text]
kafkaFileTables =
  [ myRootPath @TaskAllocation @FHandle
  , myRootPath @GroupMetadataValue @FHandle
  , myRootPath @Proto.Timestamp @FHandle
  , myRootPath @AclResourceNode @FHandle
  ]

initKafkaZkPaths :: HasCallStack => ZookeeperClient -> IO ()
initKafkaZkPaths zk = initializeZkPaths zk kafkaZkPaths

initKafkaRqTables :: RHandle -> IO ()
initKafkaRqTables rh = initializeRqTables rh kafkaRqTables

initKafkaFileTables :: FHandle -> IO ()
initKafkaFileTables fh = initializeFileTables fh kafkaFileTables

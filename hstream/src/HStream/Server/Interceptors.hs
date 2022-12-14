module HStream.Server.Interceptors
  ( getServerInterceptors
  ) where

import           Foreign.Ptr         (Ptr)
import           HsGrpc.Server.Types (CServerInterceptorFactory,
                                      ServerInterceptor (..))

getServerInterceptors :: IO [ServerInterceptor]
getServerInterceptors = do
  createStream <- ServerInterceptorFromPtr <$> createStreamInterceptorFactory
  pure [createStream]

foreign import ccall unsafe "createStreamInterceptorFactory"
  createStreamInterceptorFactory :: IO (Ptr CServerInterceptorFactory)

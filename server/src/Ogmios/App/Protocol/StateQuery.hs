--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -fno-warn-partial-fields #-}

-- | The state query protocol is likely the most versatile of the three Ouroboros
-- mini-protocols. As a matter of fact, it allows for querying various types of
-- information directly from the ledger. In essence, it is like a very simpler
-- request/response pattern where the types of questions one can ask are
-- specified by the protocols. Those questions include: information about the
-- chain tip, information about stake pools but also the balance of a particular
-- address.
--
-- In order to run a question by the ledger, one must first acquire a particular
-- position on the chain, so that the node can reliably answer a few questions
-- on a chosen, frozen state while continuing maintaining more recent version of
-- the ledger on the side. It is important to note that:
--
-- 1. The node cannot acquire any arbitrary state. One can only rewind up
--    to a certain point.
--
-- 2. Should a client keep a state acquired for too long, it is likely to become
--    unreachable at some point, forcing clients to re-acquire.
--
-- @
--                     ┌───────────────┐
--             ┌──────▶│     Idle      │⇦ START
--             │       └───┬───────────┘
--             │           │       ▲
--             │   Acquire │       │ Failure
--             │           ▼       │
--             │       ┌───────────┴───┐
--     Release │       │   Acquiring   │◀─────────────────┐
--             │       └───┬───────────┘                  │
--             │           │       ▲                      │ Result
--             │  Acquired │       │ ReAcquire            │
--             │           ▼       │                      │
--             │       ┌───────────┴───┐         ┌────────┴───────┐
--             └───────┤   Acquired    │────────▶│    Querying    │
--                     └───────────────┘         └────────────────┘
-- @
module Ogmios.App.Protocol.StateQuery
    ( mkStateQueryClient
    , TraceStateQuery (..)
    ) where

import Ogmios.Prelude

import Data.Aeson
    ( ToJSON (..)
    , genericToEncoding
    )
import Ogmios.Control.Exception
    ( MonadThrow
    )
import Ogmios.Control.MonadLog
    ( HasSeverityAnnotation (..)
    , Logger
    , MonadLog (..)
    , Severity (..)
    )
import Ogmios.Control.MonadSTM
    ( MonadSTM (..)
    , TQueue
    , readTQueue
    )
import Ogmios.Data.Json
    ( Json
    , ViaEncoding (..)
    )
import Ogmios.Data.Json.Query
    ( AdHocQuery (..)
    , Query (..)
    , QueryInEra
    , SomeQuery (..)
    )
import Ogmios.Data.Protocol.StateQuery
    ( AcquireLedgerState (..)
    , AcquireLedgerStateResponse (..)
    , GetGenesisConfig (..)
    , QueryLedgerStateResponse (..)
    , ReleaseLedgerState (..)
    , ReleaseLedgerStateResponse (..)
    , StateQueryCodecs (..)
    , StateQueryMessage (..)
    )
import Ouroboros.Consensus.HardFork.Combinator
    ( HardForkBlock
    )
import Ouroboros.Network.Block
    ( Point (..)
    )
import Ouroboros.Network.Protocol.LocalStateQuery.Client
    ( LocalStateQueryClient (..)
    )

import qualified Codec.Json.Rpc as Rpc
import qualified Data.Aeson as Json
import qualified Ouroboros.Consensus.HardFork.Combinator as LSQ
import qualified Ouroboros.Consensus.Ledger.Query as Ledger
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Client as LSQ

-- | A generic state-query client, which receives commands from a queue, and
-- yield results as JSON.
--
-- This client is meant to be driven by another client (e.g. from a WebSocket
-- connection) and simply ensures correct execution of the state-query protocol.
-- In particular, it also makes it easier to run queries _in the current era_.
mkStateQueryClient
    :: forall m crypto block point query.
        ( MonadThrow m
        , MonadSTM m
        , MonadLog m
        , block ~ HardForkBlock (CardanoEras crypto)
        , point ~ Point block
        , query ~ Ledger.Query block
        )
    => Logger (TraceStateQuery block)
        -- ^ A tracer for logging
    -> StateQueryCodecs block
        -- ^ For encoding Haskell types to JSON
    -> GetGenesisConfig m
        -- ^ A handle to access genesis configurations
    -> TQueue m (StateQueryMessage block)
        -- ^ Incoming request queue
    -> (Json -> m ())
        -- ^ An emitter for yielding JSON objects
    -> LocalStateQueryClient block point query m ()
mkStateQueryClient tr StateQueryCodecs{..} GetGenesisConfig{..} queue yield =
    LocalStateQueryClient clientStIdle
  where
    await :: m (StateQueryMessage block)
    await = atomically (readTQueue queue)

    clientStIdle
        :: m (LSQ.ClientStIdle block point query m ())
    clientStIdle = await >>= \case
        MsgAcquireLedgerState (AcquireLedgerState pt) toResponse _ ->
            pure $ LSQ.SendMsgAcquire (Just pt) (clientStAcquiring pt toResponse)
        MsgReleaseLedgerState ReleaseLedgerState toResponse _ -> do
            yield $ encodeReleaseLedgerStateResponse (toResponse ReleaseLedgerStateResponse)
            clientStIdle
        MsgQueryLedgerState query toResponse _ -> do
            pure $ LSQ.SendMsgAcquire Nothing (clientStAcquiringTip query toResponse)

    clientStAcquiring
        :: Point block
        -> Rpc.ToResponse (AcquireLedgerStateResponse block)
        -> LSQ.ClientStAcquiring block point query m ()
    clientStAcquiring pt toResponse =
        LSQ.ClientStAcquiring
            { LSQ.recvMsgAcquired = do
                yield $ encodeAcquireLedgerStateResponse $ toResponse $ AcquireSuccess pt
                clientStAcquired pt
            , LSQ.recvMsgFailure = \failure -> do
                yield $ encodeAcquireLedgerStateResponse $ toResponse $ AcquireFailure failure
                clientStIdle
            }

    clientStAcquiringTip
        :: Query Proxy block
        -> Rpc.ToResponse (QueryLedgerStateResponse block)
        -> LSQ.ClientStAcquiring block point query m ()
    clientStAcquiringTip Query{rawQuery = query, queryInEra} toResponse =
        LSQ.ClientStAcquiring
            { LSQ.recvMsgAcquired = do
                withCurrentEra queryInEra $ \case
                    Nothing -> do
                        let response = QueryUnavailableInCurrentEra
                        yield $ encodeQueryLedgerStateResponse $ toResponse response
                        pure $ LSQ.SendMsgRelease clientStIdle

                    Just (era, SomeStandardQuery qry encodeResult _proxy) -> do
                        logWith tr $ StateQueryRequest { query, point = Nothing, era }
                        pure $ LSQ.SendMsgQuery qry $ LSQ.ClientStQuerying
                            { LSQ.recvMsgResult = \(encodeResult -> result) -> do
                                whenRight_ result $ logWith tr . StateQueryResponse . ViaEncoding
                                yield $ encodeQueryLedgerStateResponse $ toResponse $
                                    either QueryEraMismatch QueryResponse result
                                pure $ LSQ.SendMsgRelease clientStIdle
                            }

                    Just (_era, SomeAdHocQuery qry encodeResult _proxy) -> do
                        case qry of
                            GetByronGenesis -> do
                                result <- encodeResult <$> getByronGenesis
                                yield $ encodeQueryLedgerStateResponse $ toResponse $
                                    either QueryEraMismatch QueryResponse result
                                pure $ LSQ.SendMsgRelease clientStIdle
                            GetShelleyGenesis -> do
                                result <- encodeResult <$> getShelleyGenesis
                                yield $ encodeQueryLedgerStateResponse $ toResponse $
                                    either QueryEraMismatch QueryResponse result
                                pure $ LSQ.SendMsgRelease clientStIdle
                            GetAlonzoGenesis -> do
                                result <- encodeResult <$> getAlonzoGenesis
                                yield $ encodeQueryLedgerStateResponse $ toResponse $
                                    either QueryEraMismatch QueryResponse result
                                pure $ LSQ.SendMsgRelease clientStIdle
                            GetConwayGenesis -> do
                                result <- encodeResult <$> getConwayGenesis
                                yield $ encodeQueryLedgerStateResponse $ toResponse $
                                    either QueryEraMismatch QueryResponse result
                                pure $ LSQ.SendMsgRelease clientStIdle

            , LSQ.recvMsgFailure = \failure -> do
                let response = QueryAcquireFailure failure
                yield $ encodeQueryLedgerStateResponse $ toResponse response
                clientStIdle
            }

    clientStAcquired
        :: Point block
        -> m (LSQ.ClientStAcquired block point query m ())
    clientStAcquired pt = await >>= \case
        MsgAcquireLedgerState (AcquireLedgerState pt') toResponse _ ->
            pure $ LSQ.SendMsgReAcquire (Just pt') (clientStAcquiring pt' toResponse)
        MsgReleaseLedgerState ReleaseLedgerState toResponse _ -> do
            yield $ encodeReleaseLedgerStateResponse (toResponse ReleaseLedgerStateResponse)
            pure $ LSQ.SendMsgRelease clientStIdle
        MsgQueryLedgerState Query{rawQuery = query,queryInEra} toResponse _ ->
            withCurrentEra queryInEra $ \case
                Nothing -> do
                    let response = QueryUnavailableInCurrentEra
                    yield $ encodeQueryLedgerStateResponse $ toResponse response
                    clientStAcquired pt

                Just (_era, SomeAdHocQuery qry encodeResult _proxy) -> do
                    case qry of
                        GetByronGenesis -> do
                            result <- encodeResult <$> getByronGenesis
                            yield $ encodeQueryLedgerStateResponse $ toResponse $
                                either QueryEraMismatch QueryResponse result
                            pure $ LSQ.SendMsgRelease clientStIdle
                        GetShelleyGenesis -> do
                            result <- encodeResult <$> getShelleyGenesis
                            yield $ encodeQueryLedgerStateResponse $ toResponse $
                                either QueryEraMismatch QueryResponse result
                            pure $ LSQ.SendMsgRelease clientStIdle
                        GetAlonzoGenesis -> do
                            result <- encodeResult <$> getAlonzoGenesis
                            yield $ encodeQueryLedgerStateResponse $ toResponse $
                                either QueryEraMismatch QueryResponse result
                            pure $ LSQ.SendMsgRelease clientStIdle
                        GetConwayGenesis -> do
                            result <- encodeResult <$> getConwayGenesis
                            yield $ encodeQueryLedgerStateResponse $ toResponse $
                                either QueryEraMismatch QueryResponse result
                            pure $ LSQ.SendMsgRelease clientStIdle

                Just (era, SomeStandardQuery qry encodeResult _proxy) -> do
                    logWith tr $ StateQueryRequest { query, point = Just pt, era }
                    pure $ LSQ.SendMsgQuery qry $ LSQ.ClientStQuerying
                        { LSQ.recvMsgResult = \(encodeResult -> result) -> do
                            whenRight_ result $ logWith tr . StateQueryResponse . ViaEncoding
                            yield $ encodeQueryLedgerStateResponse $ toResponse $
                                either QueryEraMismatch QueryResponse result
                            clientStAcquired pt
                        }

--
-- Helpers
--

-- | Run a query in the context of the current era. As a matter of fact, queries
-- are typed and bound to a particular era. Different era may support small
-- variations of the same queries.
--
-- This is quite cumbersome to handle client-side and usually not desirable. In
-- most cases:
--
-- - Query don't change from an era to another
-- - New eras may add new queries
-- - Clients only care about queries available in the current / latest era
--
-- Thus, Ogmios is doing the "heavy lifting" by sending queries directly in the
-- current era, if they exist / are compatible.
withCurrentEra
    :: forall crypto block point query m f.
        ( block ~ HardForkBlock (CardanoEras crypto)
        , query ~ Ledger.Query block
        , Applicative m
        )
    => QueryInEra f block
    -> (Maybe (SomeShelleyEra, SomeQuery f block) -> m (LSQ.ClientStAcquired block point query m ()))
    -> m (LSQ.ClientStAcquired block point query m ())
withCurrentEra queryInEra callback = pure
    $ LSQ.SendMsgQuery (Ledger.BlockQuery $ LSQ.QueryHardFork LSQ.GetCurrentEra)
    $ LSQ.ClientStQuerying
        { LSQ.recvMsgResult = \eraIndex ->
            callback (fromEraIndex eraIndex >>= (\e -> (e,) <$> queryInEra e))
        }

--
-- Logs
--

data TraceStateQuery block where
    StateQueryRequest
        :: { point :: Maybe (Point block)
           , query :: Json.Value
           , era :: SomeShelleyEra
           }
        -> TraceStateQuery block

    StateQueryResponse
        :: { result :: ViaEncoding }
        -> TraceStateQuery block

    deriving (Show, Generic)

instance ToJSON (Point block) => ToJSON (TraceStateQuery block) where
    toEncoding = genericToEncoding Json.defaultOptions

instance HasSeverityAnnotation (TraceStateQuery block) where
    getSeverityAnnotation = \case
        StateQueryRequest{} -> Info
        StateQueryResponse{} -> Info

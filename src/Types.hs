{-# LANGUAGE FlexibleInstances #-}
module Types where

import Control.Monad.State
import Control.Monad.Writer
import Control.Concurrent
import Control.Concurrent.Timer
import Control.Concurrent.Suspend
import Control.Concurrent.STM
import System.Time
import qualified Data.Map as Map
import Data.Maybe (fromJust)
import Text.Printf

data Role = Leader |
            Follower |
            Candidate
            deriving (Show, Eq)

type NWS = WriterT Log (StateT NodeStateDetails IO)
type Port = String
type ConnectionMap = TVar (Map.Map NodeId (TChan Command))

toNWS :: NodeStateDetails -> NWS ()
toNWS = put

liftio :: IO a -> WriterT Log (StateT NodeStateDetails IO) a
liftio = lift . lift

liftstm :: STM a -> WriterT Log (StateT NodeStateDetails IO) a
liftstm = liftio . atomically

-- | Log a string. Uses the current term and index
logInfo :: String -> NWS ()
logInfo info = do
        nsd <- get
        let nodeid = nodeId nsd
            index = lastLogIndex nsd
            term = lastLogTerm nsd
        tell [((index,term),"-# " ++ fromJust nodeid ++  " #- " ++ info)]

-- | Encapsulates the state of a Raft node
data NodeStateDetails = NodeStateDetails {
                          currRole :: Role, -- ^ Current role of this node
                          commitIndex :: Integer,
                          curLeaderId :: NodeId, -- ^  Id of the current leader. Used by followers to redirect requests sent to them by clients
                          votedFor :: NodeId, -- ^ Id of the last node we voted for
                          followerList :: [NodeId], -- ^ List of NodeIds of this node's followers
                          lastLogIndex :: Index, -- ^ The last index in the log written thus far
                          lastLogTerm :: Term, -- ^ The last term in the log written thus far
                          currTerm :: Term, -- ^ The latest term seen by this node
                          nodeId :: NodeId,  -- ^ The id of this node
                          inbox :: TChan Command,
                          cMap :: ConnectionMap
                        }


incTerm :: NodeStateDetails -> NWS NodeStateDetails
incTerm nsd = do
       let newNsd = nsd{currTerm=currTerm nsd + 1}
       put newNsd
       return newNsd

incTermIndex :: NodeStateDetails -> NWS NodeStateDetails
incTermIndex nsd = do
       let newNsd = nsd{lastLogIndex=lastLogIndex nsd + 1, lastLogTerm=lastLogTerm nsd + 1}
       put newNsd
       return newNsd

broadCastExceptSelf :: Command -> ConnectionMap -> NodeId -> IO ()
broadCastExceptSelf cmd connectionMap nid = do
        m <- readTVarIO connectionMap
        mapM_ (sendCommand' cmd) $ Map.elems $ Map.filterWithKey (\n _ -> n /= nid) m

broadCast :: Command -> ConnectionMap -> IO ()
broadCast cmd connectionMap = do
        m <- readTVarIO connectionMap
        mapM_ (sendCommand' cmd) $ Map.elems m

-- | Send a command to a node
sendCommand :: Command -> NodeId -> ConnectionMap -> IO ()
sendCommand cmd nid cm = do
        m <- atomically $ readTVar cm
        case Map.lookup nid m of
            Nothing -> error $ "No mapping for node Id " ++ fromJust nid
            Just tChan -> sendCommand' cmd tChan

-- | Send a command to a node's inbox
sendCommand' :: Command -> TChan Command -> IO ()
sendCommand' cmd ibox =
        --printf "Sending command: %s\n" $ show cmd
        atomically $ writeTChan ibox cmd

createTimeout :: NWS ()
createTimeout = do
    tVar <- liftio newEmptyMVar
    liftio $ forkIO (do oneShotTimer (putMVar tVar True) (sDelay 2); return ()) --TODO randomize this duration -- TODO: make it configurable
    startTime <- liftio getClockTime
    logInfo $ "Waiting... " ++ show startTime
    liftio $ takeMVar tVar -- wait for election timeout to expire
    endTime <- liftio getClockTime
    logInfo $ printf "Election time expired " ++ show endTime

type NodeId = Maybe String

data Node = Node {getId :: NodeId} deriving (Ord, Eq, Show)

type Index = Integer
type Term = Integer
type LogState = (Index, Term)
type Log = [(LogState, String)]

type StateMap = Map.Map Node NodeStateDetails

data Command =
    -- used to make candidates kick off leader election
    StartCanvassing |

    -- broadcast by candidates
    -- 5.4.1 candidate includes its state. Used at follower end to determine if the follower is more
    -- "up-to-date" than the candidate. See RejectVote definition to see how "up-to-date" is
    -- determined
    RequestVotes Term NodeId LogState |

    -- 5.4.1 sent by follower to candidate in response to RequestVotes if its log is more up to date than
    -- the candidate's. Up-to-dateness is determined using the following two rules:
    -- a. the log with the larger term in its last entry is more up to date
    -- b. if both logs have the same number of entries, the longer log (i,e., larger index) is more up to date
    -- The response consists of the current term at the receiver and a Bool
    -- indicating whether the vote was granted.
    RespondRequestVotes Term Bool |

    -- sent by leader to its followers
    -- 2nd arg: highest index so far committed
    -- 3rd arg: (index, term) of previous log entry. Used for log consistency check at follower end
    AppendEntries Term NodeId LogState Log Index |

    -- sent by follower to leader in response to AppendEntry if log consistency check fails
    RespondAppendEntries Term Bool |

    -- sent by client to leader. if the node that receives this is not the leader, it forwards it
    -- to the leader.
    -- TODO: have some data as an argument?
    AcceptClientReq |

    RespondClientReq
    deriving (Show)

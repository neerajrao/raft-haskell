module Node where

{-
  Generalized Raft node.
  This models all the state transitions and functionality
  of a node.

  Leader needs to keep track of its followers (this list can
  be initialized when the leader was still a candidate) so it knows
  how many followers it has. This way, it can decide when
  a "majority" has responded. Leader also must keep track
  of the nextIndex and matchIndex for each of its followers.

  Followers need to keep track of the leader so e.g. they
  can forward requests erroneously sent to them by clients
-}

import Types
import Control.Monad.State
import Control.Monad.Writer
import Control.Concurrent.STM
import Follower
import Candidate
import Leader
import System.IO

startInboxListener :: NodeStateDetails -> Handle -> IO ()
startInboxListener nsd logFileHandle = do
    (lg,newNsd) <- run nsd
    hPutStr logFileHandle $ unlines $ map show lg -- write out the node log to a file
    startInboxListener newNsd logFileHandle -- feed the updated state back in to run

run :: NodeStateDetails -> IO (Log, NodeStateDetails)
run = runStateT (execWriterT updateState) -- runStateT :: StateT s m a -> s -> m (a, s); s = NodeStateDetails, m = IO, a = Log
                                          -- execWriterT :: Monad m => WriterT w m a -> m w; w = Log, m = StateT NodeStateDetails IO, a = NodeStateDetails

updateState :: NWS NodeStateDetails
updateState = do
        nsd <- get
        let currentRole = currRole nsd
            ibox = inbox nsd
        cmd <- liftstm $ tryReadTChan ibox
        case currentRole of
          Follower -> Follower.processCommand cmd
          Candidate -> Candidate.processCommand cmd
          Leader -> Leader.processCommand cmd

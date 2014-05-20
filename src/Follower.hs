module Follower where

import Types
import Control.Monad.State
import Control.Concurrent
import Control.Concurrent.Timer
import Control.Concurrent.Suspend
import Control.Concurrent.STM
import Text.Printf
import System.Time
import Data.Maybe (fromJust)

processCommand :: Maybe Command -> NWS NodeStateDetails
processCommand cmd = do
    case cmd of
        --start election timeout
        Nothing -> get >>= \nsd -> do
            logInfo $ "Role: " ++ (show $ currRole nsd)
            tVar <- liftio newEmptyMVar
            liftio $ forkIO (do oneShotTimer (putMVar tVar True) (sDelay 2); return ()) --TODO randomize this duration -- TODO: make it configurable
            startTime <- liftio getClockTime
            logInfo $ "Waiting... " ++ show startTime
            liftio $ takeMVar tVar -- wait for election timeout to expire
            endTime <- liftio getClockTime
            logInfo $ printf "Election time expired " ++ show endTime
            let ibox = inbox nsd
            empty <- liftstm $ isEmptyTChan ibox
            if empty -- nothing in our inbox, switch to candidate
                then do
                    logInfo "Nothing waiting in inbox"
                    logInfo "Incrementing term, Switching to Candidate"
                    liftstm $ writeTChan ibox StartCanvassing
                    let newNsd = nsd{currRole=Candidate, currTerm=currTerm nsd+1}
                    put newNsd
                    return newNsd
                else do
                    logInfo "Something waiting in inbox"
                    return nsd
        Just (RequestVotes cTerm cid logState) -> do
            get >>= \nsd -> do
                logInfo $ "Role: " ++ (show $ currRole nsd)
                logInfo $ "Received: " ++ (show $ fromJust cmd)
                if cTerm < (currTerm nsd)
                    then do -- our current term is more than the candidate's
                            -- reject the RequestVote
                        logInfo $ "Reject vote: our currTerm " ++ (show $ currTerm nsd) ++ "> "++(fromJust cid) ++"'s currTerm" ++ (show cTerm)
                        liftio $ sendCommand (RespondRequestVotes (currTerm nsd) False) cid (cMap nsd)
                        return nsd
                    else do
                        if cTerm > (currTerm nsd)
                            then do
                                let newNsd = nsd{votedFor=Nothing, currTerm=cTerm} -- this is a fresh term we haven't seen before
                                put newNsd
                                castBallot newNsd
                            else castBallot nsd -- this is the current term
                        where castBallot :: NodeStateDetails -> NWS NodeStateDetails
                              castBallot n = do
                                  if votedFor n /= Nothing && votedFor n /= cid
                                     then do
                                         logInfo $ "Reject vote: already voted for " ++ (fromJust $ votedFor n)
                                         rejectCandidate n
                                     else do
                                        if isMoreUpToDate n logState
                                           then do
                                               logInfo $ "Reject vote: our currTerm " ++ (show $ currTerm n) ++ " > "++(fromJust cid) ++"'s currTerm " ++ (show cTerm)
                                               rejectCandidate n
                                           else do -- we're less up to date than the candidate that requested a vote
                                                   -- accept the RequestVote
                                               logInfo $ "Accept vote: our currTerm " ++ (show $ currTerm n) ++ " <= "++(fromJust cid) ++"'s currTerm " ++ (show cTerm)
                                               liftio $ sendCommand (RespondRequestVotes (currTerm n) True) cid (cMap n)
                                               let newNsd = n{votedFor=cid} -- update votedFor
                                               put newNsd
                                               return newNsd

                              rejectCandidate :: NodeStateDetails -> NWS NodeStateDetails
                              rejectCandidate n = do -- we're more up to date than the candidate that requested a vote
                                                    -- reject the RequestVote
                                         liftio $ sendCommand (RespondRequestVotes (currTerm n) False) cid (cMap n)
                                         return n
        Just _ -> get >>= \nsd -> do
            logInfo $ "Role: " ++ (show $ currRole nsd)
            logInfo $ "Received: " ++ (show $ fromJust cmd)
            logInfo $ printf "Invalid command: %s %s" ((show . currRole) nsd) (show $ fromJust cmd)
            return nsd

-- | Decides if the node with the state passed in (first arg) is more
-- up to date than the node with the log state passed in (second arg)
-- 5.4.1 Up-to-dateness is determined using the following two rules:
-- a. the log with the larger term in its last entry is more up to date
-- b. if both logs have the same number of entries, the longer log (i,e., larger index) is more up to date
isMoreUpToDate :: NodeStateDetails -> LogState -> Bool
isMoreUpToDate nsd logState | (lastLogTerm nsd > snd logState) = True
                            | (lastLogTerm nsd < snd logState) = False
                            | otherwise = case (compare (lastLogIndex nsd) (fst logState)) of
                                              GT -> True
                                              _ -> False


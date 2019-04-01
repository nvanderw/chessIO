module Game.Chess.UCI (
  UCIException(..)
, Engine, name, author, options, game
, currentPosition, readInfo, tryReadInfo, readBestMove, tryReadBestMove
, start, start', isready
, Option(..), getOption, setOptionSpinButton
, Info(..)
, send
, addMove, move
, quit, quit'
) where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TChan
import Control.Exception
import Control.Monad
import Data.Attoparsec.Combinator
import Data.Attoparsec.ByteString.Char8
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Functor
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.IORef
import Data.Ix
import Data.List
import Data.Maybe
import Data.String
import Game.Chess
import System.Exit
import System.IO
import System.Process
import System.Timeout (timeout)

data Engine = Engine {
  inH :: Handle
, outH :: Handle
, procH :: ProcessHandle
, outputStrLn :: String -> IO ()
, infoThread :: Maybe ThreadId
, name :: Maybe ByteString
, author :: Maybe ByteString
, options :: HashMap ByteString Option
, isReady :: MVar ()
, infoChan :: TChan [Info]
, bestMoveChan :: TChan (Move, Maybe Move)
, game :: IORef (Position, [Move])
}

readInfo :: Engine -> STM [Info]
readInfo = readTChan . infoChan

tryReadInfo :: Engine -> STM (Maybe [Info])
tryReadInfo = tryReadTChan . infoChan

readBestMove :: Engine -> STM (Move, Maybe Move)
readBestMove = readTChan . bestMoveChan

tryReadBestMove :: Engine -> STM (Maybe (Move, Maybe Move))
tryReadBestMove = tryReadTChan . bestMoveChan

data UCIException = SANError String
                  | IllegalMove Move
                  deriving Show


instance Exception UCIException

data Command = Name ByteString
             | Author ByteString
             | Option ByteString Option
             | UCIOk
             | ReadyOK
             | Info [Info]
             | BestMove !(Move, (Maybe Move))
             deriving (Show)

data Info = PV [Move]
          | Depth Int
          | SelDepth Int
          | Time Int
          | MultiPV Int
          | Score Int
          | UpperBound
          | LowerBound
          | Nodes Int
          | NPS Int
          | TBHits Int
          | HashFull Int
          | CurrMove ByteString
          | CurrMoveNumber Int
          deriving Show

data Option = CheckBox Bool
            | ComboBox { comboBoxValue :: ByteString, comboBoxValues :: [ByteString] }
            | SpinButton { spinButtonValue, spinButtonMinBound, spinButtonMaxBound :: Int }
            | String ByteString
            | Button
            deriving (Eq, Show)

instance IsString Option where
  fromString = String . BS.pack

command :: Position -> Parser Command
command pos = skipSpace *> choice [
    name, author, option, uciok, readyok, info, bestmove
  ] <* skipSpace
 where
  name = fmap Name $
    "id" *> skipSpace *> "name" *> skipSpace *> takeByteString
  author = fmap Author $
    "id" *> skipSpace *> "author" *> skipSpace *> takeByteString
  option = do
    void "option"
    skipSpace
    void "name"
    skipSpace
    optName <- BS.pack <$> manyTill anyChar (skipSpace *> "type")
    skipSpace
    optValue <- spin <|> check <|> combo <|> str <|> button
    pure $ Option optName optValue
  check =
    fmap CheckBox $ "check" *> skipSpace *> "default" *> skipSpace *>
                    ("false" $> False <|> "true" $> True)
  spin = do
    void "spin"
    skipSpace
    value <- "default" *> skipSpace *> signed decimal <* skipSpace
    minValue <- "min" *> skipSpace *> signed decimal <* skipSpace
    maxValue <- "max" *> skipSpace *> signed decimal
    pure $ SpinButton value minValue maxValue
  combo = do
    void "combo"
    skipSpace
    def <- fmap BS.pack $ "default" *> skipSpace *> manyTill anyChar var
    (vars, lastVar) <- (,) <$> many (manyTill anyChar var)
                           <*> takeByteString
    pure $ ComboBox def (map BS.pack vars <> [lastVar])
  var = skipSpace *> "var" *> skipSpace
  str = fmap String $
    "string" *> skipSpace *> "default" *> skipSpace *> takeByteString
  button = "button" $> Button
  uciok = "uciok" $> UCIOk
  readyok = "readyok" $> ReadyOK
  info = do
    "info"
    skipSpace
    Info <$> sepBy1 infoItem skipSpace
  infoItem = Depth <$> ("depth" *> skipSpace *> decimal)
         <|> SelDepth <$> ("seldepth" *> skipSpace *> decimal)
         <|> MultiPV <$> ("multipv" *> skipSpace *> decimal)
         <|> Score <$> ("score" *> skipSpace *> "cp" *> skipSpace *> signed decimal)
         <|> UpperBound <$ "upperbound"
         <|> LowerBound <$ "lowerbound"
         <|> Nodes <$> ("nodes" *> skipSpace *> decimal)
         <|> NPS <$> ("nps" *> skipSpace *> decimal)
         <|> HashFull <$> ("hashfull" *> skipSpace *> decimal)
         <|> TBHits <$> ("tbhits" *> skipSpace *> decimal)
         <|> Time <$> ("time" *> skipSpace *> decimal)
         <|> pv
         <|> CurrMove <$> ("currmove" *> skipSpace *> mv)
         <|> CurrMoveNumber <$> ("currmovenumber" *> skipSpace *> decimal)
  pv = do
    xs <- (fmap . fmap) BS.unpack $ "pv" *> skipSpace *> sepBy mv skipSpace
    PV . snd <$> foldM toMove (pos, []) xs
  toMove (pos, xs) s = do
    case fromUCI pos s of
      Just m -> pure (applyMove pos m, xs <> [m])
      Nothing -> fail $ "Failed to parse move " <> s
  mv = fmap fst $ match $ satisfy f *> satisfy r *> satisfy f *> satisfy r *> optional (satisfy p) where
    f = inRange ('a','h')
    r = inRange ('1', '8')
    p 'q' = True
    p 'r' = True
    p 'b' = True
    p 'n' = True
    p _ = False 
  bestmove = do
    void "bestmove"
    skipSpace
    m <- BS.unpack <$> mv
    ponder <- (fmap . fmap) BS.unpack $
              optional (skipSpace *> "ponder" *> skipSpace *> mv)
    case fromUCI pos m of
      Just m' -> case ponder of
        Nothing -> pure $ BestMove (m', Nothing)
        Just p -> case fromUCI (applyMove pos m') p of
          Just p' -> pure $ BestMove (m', (Just p'))
          Nothing -> fail $ "Failed to parse ponder move " <> p
      Nothing -> fail $ "Failed to parse best move " <> m

start :: String -> [String] -> IO (Maybe Engine)
start = start' 2000000 putStrLn

start' :: Int -> (String -> IO ()) -> String -> [String] -> IO (Maybe Engine)
start' usec outputStrLn cmd args = do
  (Just inH, Just outH, Nothing, procH) <- createProcess (proc cmd args) {
      std_in = CreatePipe, std_out = CreatePipe
    }
  hSetBuffering inH LineBuffering
  e <- Engine inH outH procH outputStrLn Nothing Nothing Nothing HashMap.empty <$>
       newEmptyMVar <*> newTChanIO <*> newTChanIO <*> newIORef (startpos, [])
  send "uci" e
  timeout usec (initialise e) >>= \case
    Just e' -> do
      tid <- forkIO . infoReader $ e'
      pure . Just $ e' { infoThread = Just tid }
    Nothing -> quit e $> Nothing

initialise :: Engine -> IO Engine
initialise c@Engine{outH, outputStrLn, game} = do
  l <- BS.hGetLine outH
  pos <- fst <$> readIORef game
  if BS.null l then initialise c else case parseOnly (command pos <* endOfInput) l of
    Left err -> do
      outputStrLn . BS.unpack $ l
      initialise c
    Right (Name n) -> initialise (c { name = Just n })
    Right (Author a) -> initialise (c { author = Just a })
    Right (Option name opt) -> initialise (c { options = HashMap.insert name opt $ options c })
    Right UCIOk -> pure c

infoReader :: Engine -> IO ()
infoReader e@Engine{..} = forever $ do
  l <- BS.hGetLine outH
  pos <- currentPosition e
  case parseOnly (command pos <* endOfInput) l of
    Left err -> do
      outputStrLn $ err <> ":" <> show l
    Right ReadyOK -> putMVar isReady ()
    Right (Info i) -> atomically $ writeTChan infoChan i
    Right (BestMove bm) -> atomically $ writeTChan bestMoveChan bm

isready :: Engine -> IO ()
isready e@Engine{isReady} = do
  send "isready" e
  takeMVar isReady
  
send :: ByteString -> Engine -> IO ()
send s Engine{inH, procH} = do
  BS.hPutStrLn inH s
  getProcessExitCode procH >>= \case
    Nothing -> pure ()
    Just ec -> throwIO ec

getOption :: ByteString -> Engine -> Maybe Option
getOption n = HashMap.lookup n . options

setOptionSpinButton :: ByteString -> Int -> Engine -> IO Engine
setOptionSpinButton n v c
  | Just (SpinButton _ minValue maxValue) <- getOption n c
  , inRange (minValue, maxValue) v
  = do
    send ("setoption name " <> n <> " value " <> BS.pack (show v)) c
    pure $ c { options = HashMap.update (set v) n $ options c }
 where
  set v opt@SpinButton{} = Just $ opt { spinButtonValue = v }

currentPosition :: Engine -> IO Position
currentPosition Engine{game} =
  uncurry (foldl' applyMove) <$> readIORef game

nextMove :: Engine -> IO Color
nextMove Engine{game} = do
  (initialPosition, history) <- readIORef game
  pure $ if even . length $ history then color initialPosition else opponent . color $ initialPosition

move :: Engine -> String -> IO ()
move e@Engine{game} s = do
  pos <- currentPosition e
  case fromUCI pos s of
    Just m -> do
      addMove e m
      sendPosition e
    Nothing -> case fromSAN pos s of
      Left err -> throwIO $ SANError err
      Right m -> do
        addMove e m
        sendPosition e

addMove :: Engine -> Move -> IO ()
addMove e@Engine{game} m = do
  pos <- currentPosition e
  if m `elem` moves pos
    then atomicModifyIORef' game \g -> (fmap (<> [m]) g, ())
    else throwIO $ IllegalMove m
    
sendPosition :: Engine -> IO ()
sendPosition e@Engine{game} = do
  readIORef game >>= (flip send) e . cmd
 where
  cmd (p, h) = "position fen " <> BS.pack (toFEN p) <> line h
  line h
    | null h    = ""
    | otherwise = " moves " <> BS.unwords (BS.pack . toUCI <$> h)

quit :: Engine -> IO (Maybe ExitCode)
quit = quit' 1000000

quit' :: Int -> Engine -> IO (Maybe ExitCode)
quit' usec c@Engine{procH, infoThread} = (pure . Just) `handle` do
  maybe (pure ()) killThread infoThread
  send "quit" c
  timeout usec (waitForProcess procH) >>= \case
    Just ec -> pure $ Just ec
    Nothing -> terminateProcess procH $> Nothing

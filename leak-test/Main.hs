{-# LANGUAGE OverloadedStrings #-}
import Language.Haskell.LSP.Test
import Language.Haskell.LSP.Types
import Control.Monad.IO.Class
import Control.Applicative.Combinators
import Control.Concurrent
import Control.Monad


main = runSessionWithConfig (defaultConfig { logStdErr = True, logMessages = True, messageTimeout = 500 }) "/home/matt/haskell-ide-engine/prof-wrapper" fullCaps "/home/matt/lsp-test" $ do
  doc <- openDoc "src/Language/Haskell/LSP/Test/Parsing.hs" "haskell"
  waitForDiagnostics
  replicateM_ 50 $ do
    liftIO $ putStrLn "----editing----"
    let te = TextEdit (Range (Position 5 0) (Position 5 0)) " "
    applyEdit doc te
    sendNotification TextDocumentDidSave (DidSaveTextDocumentParams doc)
    waitForDiagnostics
    let pos = Position 119 54
        params = TextDocumentPositionParams doc
    print <$> getHover doc pos
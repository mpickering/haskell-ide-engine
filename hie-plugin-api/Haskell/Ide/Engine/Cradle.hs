module Haskell.Ide.Engine.Cradle (findLocalCradle) where

import HIE.Bios as BIOS

-- | Find the cradle responsible for a filepath.
-- If an explicit configuration is given, use it, otherwise
-- try to guess a cradle based on certain heuristics, such as
-- existence of stack.yaml and cabal.project.
findLocalCradle :: FilePath -> IO Cradle
findLocalCradle fp = do
  -- Get the cabal directory from the cradle
  cradleConf <- BIOS.findCradle fp
  case cradleConf of
    Just yaml -> BIOS.loadCradle yaml
    Nothing -> BIOS.loadImplicitCradle fp
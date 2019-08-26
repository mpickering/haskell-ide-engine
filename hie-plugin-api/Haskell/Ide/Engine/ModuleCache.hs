{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE ForeignFunctionInterface #-}


module Haskell.Ide.Engine.ModuleCache
  ( modifyCache
  , ifCachedInfo
  , withCachedInfo
  , ifCachedModule
  , ifCachedModuleM
  , ifCachedModuleAndData
  , withCachedModule
  , withCachedModuleAndData
  , deleteCachedModule
  , failModule
  , cacheModule
  , cacheModules
  , cacheInfoNoClear
  , runActionWithContext
  , ModuleCache(..)
  ) where

import           Control.Monad
import           Control.Monad.IO.Class
import Control.Monad.Trans.Control
import           Control.Monad.Trans.Free
import           Data.Dynamic (toDyn, fromDynamic, Dynamic)
import           Data.Generics (Proxy(..), TypeRep, typeRep, typeOf)
import qualified Data.Map as Map
import           Data.Maybe
import           Data.Typeable (Typeable)
import           System.Directory
import UnliftIO
import GHC.Exts
import Data.Bits
import Foreign.Ptr

import Debug.Trace
import Control.Concurrent

import qualified GHC           as GHC
import qualified HscMain       as GHC
import qualified Data.Trie.Convenience as T
import qualified Data.Trie as T
import qualified HIE.Bios as BIOS
import qualified Data.ByteString.Char8 as B

import           Haskell.Ide.Engine.ArtifactMap
import           Haskell.Ide.Engine.TypeMap
import           Haskell.Ide.Engine.GhcModuleCache
import           Haskell.Ide.Engine.MultiThreadState
import           Haskell.Ide.Engine.PluginsIdeMonads
import           Haskell.Ide.Engine.GhcUtils

import System.Mem
import System.Mem.Weak
import System.IO

import GHC.Exts
import GHC.Weak
import GHC.Types
import GHC.Word
import Debug.Dyepack

data Void

-- foreign import ccall unsafe "mblock_address_space" address_space_start :: IO Int


anyToPtr :: a -> IO (Ptr Void)
anyToPtr !a = IO (\s -> case anyToAddr# a s of (# s', a' #) -> (# s', Ptr a' #))

weakToPtr :: Weak v -> IO (Maybe (Ptr Void))
weakToPtr w = deRefWeak w >>= maybe (return Nothing) (fmap Just . anyToPtr)


-- ---------------------------------------------------------------------

modifyCache :: (HasGhcModuleCache m) => (GhcModuleCache -> GhcModuleCache) -> m ()
modifyCache f = do
  mc <- getModuleCache
  let x = (f mc)
  x `seq` setModuleCache x

-- ---------------------------------------------------------------------
-- | Runs an action in a ghc-mod Cradle found from the
-- directory of the given file. If no file is found
-- then runs the action in the default cradle.
-- Sets the current directory to the cradle root dir
-- in either case
runActionWithContext :: (MonadIde m, GHC.GhcMonad m, HasGhcModuleCache m, MonadBaseControl IO m)
                     => GHC.DynFlags -> Maybe FilePath -> m a -> m a
runActionWithContext _df Nothing action = do
  -- Cradle with no additional flags
  -- dir <- liftIO $ getCurrentDirectory
  --This causes problems when loading a later package which sets the
  --packageDb
  -- loadCradle df (BIOS.defaultCradle dir)
  action
runActionWithContext df (Just uri) action = do
  getCradle uri (\lc -> loadCradle df lc >> action)

loadCradle :: (MonadIde m, HasGhcModuleCache m, GHC.GhcMonad m
              , MonadBaseControl IO m) => GHC.DynFlags -> LookupCradleResult -> m ()
loadCradle _ ReuseCradle = do
    traceM ("Reusing cradle")
loadCradle iniDynFlags (NewCradle fp) = do
    traceShowM ("New cradle" , fp)
    -- Cache the existing cradle
    maybe (return ()) cacheCradle =<< (currentCradle <$> getModuleCache)

    -- Now load the new cradle
    crdl <- liftIO $ BIOS.findCradle fp
    traceShowM crdl
    liftIO (GHC.newHscEnv iniDynFlags) >>= GHC.setSession
    liftIO $ setCurrentDirectory (BIOS.cradleRootDir crdl)
    withProgress "Initialising Cradle" NotCancellable $ \f ->
      BIOS.initializeFlagsWithCradleWithMessage (Just $ toMessager f) fp crdl
    setCurrentCradle crdl
loadCradle _iniDynFlags (LoadCradle (CachedCradle crd env)) = do
    traceShowM ("Reload Cradle" , crd)
    -- Cache the existing cradle
    maybe (return ()) cacheCradle =<< (currentCradle <$> getModuleCache)
    GHC.setSession env
    setCurrentCradle crd



setCurrentCradle :: (HasGhcModuleCache m, GHC.GhcMonad m) => BIOS.Cradle -> m ()
setCurrentCradle crdl = do
    mg <- GHC.getModuleGraph
    let ps = mapMaybe (GHC.ml_hs_file . GHC.ms_location) (GHC.mgModSummaries mg)
    traceShowM ps
    ps' <- liftIO $ mapM canonicalizePath ps
    modifyCache (\s -> s { currentCradle = Just (ps', crdl) })


cacheCradle :: (HasGhcModuleCache m, GHC.GhcMonad m) => ([FilePath], BIOS.Cradle) -> m ()
cacheCradle (ds, c) = do
  env <- GHC.getSession
  let cc = CachedCradle c env
      new_map = T.fromList (map (, cc) (map B.pack ds))
  modifyCache (\s -> s { cradleCache = T.unionWith (\a _ -> a) new_map (cradleCache s) })

-- | Get the Cradle that should be used for a given URI
--getCradle :: (GM.GmEnv m, MonadIO m, HasGhcModuleCache m, GM.GmLog m
--             , MonadBaseControl IO m, ExceptionMonad m, GM.GmOut m)
getCradle :: (GHC.GhcMonad m, HasGhcModuleCache m)
         => FilePath -> (LookupCradleResult -> m r) -> m r
getCradle fp k = do
      canon_fp <- liftIO $ canonicalizePath fp
      mcache <- getModuleCache
      k (lookupCradle canon_fp mcache)

ifCachedInfo :: (HasGhcModuleCache m, MonadIO m) => FilePath -> a -> (CachedInfo -> m a) -> m a
ifCachedInfo fp def callback = do
  muc <- getUriCache fp
  case muc of
    Just (UriCacheSuccess _ uc) -> callback (cachedInfo uc)
    _ -> return def

withCachedInfo :: FilePath -> a -> (CachedInfo -> IdeDeferM a) -> IdeDeferM a
withCachedInfo fp def callback = deferIfNotCached fp go
  where go (UriCacheSuccess _ uc) = callback (cachedInfo uc)
        go UriCacheFailed = return def

ifCachedModule :: (HasGhcModuleCache m, MonadIO m, CacheableModule b) => FilePath -> a -> (b -> CachedInfo -> m a) -> m a
ifCachedModule fp def callback = ifCachedModuleM fp (return def) callback

-- | Calls the callback with the cached module for the provided path.
-- Otherwise returns the default immediately if there is no cached module
-- available.
-- If you need custom data, see also 'ifCachedModuleAndData'.
-- If you are in IdeDeferM and would like to wait until a cached module is available,
-- see also 'withCachedModule'.
ifCachedModuleM :: (HasGhcModuleCache m, MonadIO m, CacheableModule b)
                => FilePath -> m a -> (b -> CachedInfo -> m a) -> m a
ifCachedModuleM fp k callback = do
  muc <- getUriCache fp
  let x = do
        res <- muc
        case res of
          UriCacheSuccess _ uc -> do
            let ci = cachedInfo uc
            cm <- fromUriCache uc
            return (ci, cm)
          UriCacheFailed -> Nothing
  case x of
    Just (ci, cm) -> callback cm ci
    Nothing -> k

-- | Calls the callback with the cached module and data for the provided path.
-- Otherwise returns the default immediately if there is no cached module
-- available.
-- If you are in IdeDeferM and would like to wait until a cached module is available,
-- see also 'withCachedModuleAndData'.
ifCachedModuleAndData :: forall a b m. (ModuleCache a, HasGhcModuleCache m, MonadIO m, MonadMTState IdeState m)
                      => FilePath -> b -> (GHC.TypecheckedModule -> CachedInfo -> a -> m b) -> m b
ifCachedModuleAndData fp def callback = do
  muc <- getUriCache fp
  case muc of
    Just (UriCacheSuccess _ uc@(UriCache info _ (Just tm) dat)) ->
      case fromUriCache uc of
        Just modul -> lookupCachedData fp tm info dat >>= callback modul (cachedInfo uc)
        Nothing -> return def
    _ -> return def

-- | Calls the callback with the cached module for the provided path.
-- If there is no cached module immediately available, it will call the callback once
-- the module has been cached.
-- If that module fails to load, it will then return then default as a last resort.
-- If you need custom data, see also 'withCachedModuleAndData'.
-- If you don't want to wait until a cached module is available,
-- see also 'ifCachedModule'.
withCachedModule :: CacheableModule b => FilePath -> a -> (b -> CachedInfo -> IdeDeferM a) -> IdeDeferM a
withCachedModule fp def callback = deferIfNotCached fp go
  where go (UriCacheSuccess _ uc@(UriCache _ _ _ _)) =
          case fromUriCache uc of
            Just modul -> callback modul (cachedInfo uc)
            Nothing -> wrap (Defer fp go)
        go UriCacheFailed = return def

-- | Calls its argument with the CachedModule for a given URI
-- along with any data that might be stored in the ModuleCache.
-- If the module is not already cached, then the callback will be
-- called as soon as it is available.
-- The data is associated with the CachedModule and its cache is
-- invalidated when a new CachedModule is loaded.
-- If the data doesn't exist in the cache, new data is generated
-- using by calling the `cacheDataProducer` function.
withCachedModuleAndData :: forall a b. (ModuleCache a)
                        => FilePath -> b
                        -> (GHC.TypecheckedModule -> CachedInfo -> a -> IdeDeferM b) -> IdeDeferM b
withCachedModuleAndData fp def callback = deferIfNotCached fp go
  where go (UriCacheSuccess _ (uc@(UriCache info _ (Just tm) dat))) =
          lookupCachedData fp tm info dat >>= callback tm (cachedInfo uc)
        go (UriCacheSuccess l (UriCache { cachedTcMod = Nothing })) = wrap (Defer fp go)
        go UriCacheFailed = return def

getUriCache :: (HasGhcModuleCache m, MonadIO m) => FilePath -> m (Maybe UriCacheResult)
getUriCache fp = do
  canonical_fp <- liftIO $ canonicalizePath fp
  fmap (Map.lookup canonical_fp . uriCaches) getModuleCache

deferIfNotCached :: FilePath -> (UriCacheResult -> IdeDeferM a) -> IdeDeferM a
deferIfNotCached fp cb = do
  muc <- getUriCache fp
  case muc of
    Just res -> cb res
    Nothing -> wrap (Defer fp cb)

lookupCachedData :: forall a m. (HasGhcModuleCache m, MonadMTState IdeState m, MonadIO m, Typeable a, ModuleCache a)
                 => FilePath -> GHC.TypecheckedModule -> CachedInfo -> (Map.Map TypeRep Dynamic) -> m a
lookupCachedData fp tm info dat = do
  canonical_fp <- liftIO $ canonicalizePath fp
  let proxy :: Proxy a
      proxy = Proxy
  case Map.lookup (typeRep proxy) dat of
    Nothing -> do
      val <- cacheDataProducer tm info
      let dat' = Map.insert (typeOf val) (toDyn val) dat
          newUc = UriCache info (GHC.tm_parsed_module tm) (Just tm) dat'
      res <- liftIO $ mkLeakable newUc
      modifyCache (\s -> s {uriCaches = Map.insert canonical_fp res
                                                  (uriCaches s)})
      return val

    Just x ->
      case fromDynamic x of
        Just val -> return val
        Nothing  -> error "impossible"

cacheModules :: (FilePath -> FilePath) -> [GHC.TypecheckedModule] -> IdeGhcM ()
cacheModules rfm ms = mapM_ go_one ms
  where
    go_one m = case get_fp m of
                 Just fp -> cacheModule (rfm fp) (Right m)
                 Nothing -> trace ("rfm failed: " ++ (show $ get_fp m)) $ return ()
    get_fp = GHC.ml_hs_file . GHC.ms_location . GHC.pm_mod_summary . GHC.tm_parsed_module

-- A datatype that has the same layout as Word and so can be casted to it.
data Ptr' a = Ptr' a

-- Any is a type to which any type can be safely unsafeCoerced to.
aToWord# :: Any -> Word#
aToWord# a = let !mb = Ptr' a in case unsafeCoerce# mb :: Word of W# addr -> addr

unsafeAddr :: a -> Int
unsafeAddr a = I# (word2Int# (aToWord# (unsafeCoerce# a)))

-- | Saves a module to the cache and executes any deferred
-- responses waiting on that module.
cacheModule :: FilePath -> (Either GHC.ParsedModule GHC.TypecheckedModule) -> IdeGhcM ()
cacheModule fp modul = do
  canonical_fp <- liftIO $ canonicalizePath fp
  rfm <- reverseFileMap
  newUc <-
    case modul of
      Left pm -> do
        muc <- getUriCache canonical_fp
        let defInfo = CachedInfo mempty mempty mempty mempty rfm return return
        return $ case muc of
          Just (UriCacheSuccess _ uc) ->
            let newCI = oldCI { revMap = rfm . revMap oldCI }
                    --                         ^^^^^^^^^^^^
                    -- We have to retain the old mapping state, since the
                    -- old TypecheckedModule still contains spans relative to that
                oldCI = cachedInfo uc
              in uc { cachedPsMod = pm, cachedInfo = newCI }
          _ -> UriCache defInfo pm Nothing mempty

      Right tm -> do
        typm <- genTypeMap tm
        let info = CachedInfo (genLocMap tm) typm (genImportMap tm) (genDefMap tm) rfm return return
            pm = GHC.tm_parsed_module tm
        return $ UriCache info pm (Just tm) mempty

  res <- liftIO $ mkLeakable newUc

  maybeOldUc <- (Map.lookup canonical_fp . uriCaches) <$> getModuleCache

  modifyCache $ \gmc ->
      gmc { uriCaches = Map.insert canonical_fp res (uriCaches gmc) }

  liftIO $ hPutStrLn stderr "cacheModule"
  liftIO $ traceEventIO "Cache Module"
  -- check leaks
  checkSpaceLeaks fp maybeOldUc
  -- execute any queued actions for the module
  runDeferredActions canonical_fp res

-- | Marks a module that it failed to load and triggers
-- any deferred responses waiting on it
failModule :: FilePath -> IdeGhcM ()
failModule fp = do
  fp' <- liftIO $ canonicalizePath fp

  maybeUriCache <- fmap (Map.lookup fp' . uriCaches) getModuleCache

  let res = UriCacheFailed

  case maybeUriCache of
    Just _ -> return ()
    Nothing ->
      -- If there's no cache for the module mark it as failed
      modifyCache (\gmc ->
          gmc {
            uriCaches = Map.insert fp' res (uriCaches gmc)
          }
        )

      -- Fail the queued actions
  runDeferredActions fp' res


runDeferredActions :: FilePath -> UriCacheResult -> IdeGhcM ()
runDeferredActions uri res = do
      actions <- fmap (fromMaybe [] . Map.lookup uri) (requestQueue <$> readMTS)
      -- remove queued actions
      modifyMTS $ \s -> s { requestQueue = Map.delete uri (requestQueue s) }

      liftToGhc $ forM_ actions (\a -> a res)


-- | Saves a module to the cache without clearing the associated cache data - use only if you are
-- sure that the cached data associated with the module doesn't change
cacheInfoNoClear :: (MonadIO m, HasGhcModuleCache m)
                 => FilePath -> CachedInfo -> m ()
cacheInfoNoClear uri ci = do
  uri' <- liftIO $ canonicalizePath uri
  modifyCache (\gmc ->
      gmc { uriCaches = Map.adjust
                          updateCachedInfo
                          uri'
                          (uriCaches gmc)
          }
    )
  where
    updateCachedInfo :: UriCacheResult -> UriCacheResult
    updateCachedInfo (UriCacheSuccess l old) = UriCacheSuccess l (old { cachedInfo = ci })
    updateCachedInfo UriCacheFailed        = UriCacheFailed

-- | We are about to delete or remove a module from the cache so we check to see if all
-- of it has been GCd
checkSpaceLeaks :: MonadIO m => String -> Maybe (UriCacheResult) -> m ()
checkSpaceLeaks desc mucr = do  -- check leaks
  let mask x = intPtrToPtr (complement (shiftL 1 3 - 1) .&. ptrToIntPtr x)
  case mucr of
    Just (UriCacheSuccess l _) -> do
      liftIO $ checkDyed l (\s v ->
        do hPutStrLn stderr $ desc <> " leaking: " <>  s
           p <- anyToPtr v
           -- Don't complain about "leaking" static closures
           hPutStrLn stderr . show . (\x -> (mask x, x)) $ p
           let i = plusPtr nullPtr 283467841536
           hPutStrLn stderr (show (i, i < p))
           if (i < p)
            then threadDelay 100000000000
            else return  ()
           )
    Nothing -> return ()

-- | Deletes a module from the cache
deleteCachedModule :: (MonadIO m, HasGhcModuleCache m) => FilePath -> m ()
deleteCachedModule fp = do
  canonical_fp <- liftIO $ canonicalizePath fp
  mucr <- (Map.lookup canonical_fp . uriCaches) <$> getModuleCache
  liftIO $ hPutStrLn stderr "deleteCachedModule"
  modifyCache (\s -> s { uriCaches = Map.delete canonical_fp (uriCaches s) })
  checkSpaceLeaks canonical_fp mucr

-- ---------------------------------------------------------------------
-- | A ModuleCache is valid for the lifetime of a CachedModule
-- It is generated on need and the cache is invalidated
-- when a new CachedModule is loaded.
-- Allows the caching of arbitary data linked to a particular
-- TypecheckedModule.
-- TODO: this name is confusing, given GhcModuleCache. Change it
class Typeable a => ModuleCache a where
    -- | Defines an initial value for the state extension
    cacheDataProducer :: (MonadIO m, MonadMTState IdeState m)
                      => GHC.TypecheckedModule -> CachedInfo -> m a

instance ModuleCache () where
    cacheDataProducer = const $ const $ return ()

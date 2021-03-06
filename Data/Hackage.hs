module Data.Hackage
    ( loadCabalFiles
    , sourceHackageSdist
    , UploadState (..)
    ) where

import ClassyPrelude.Yesod hiding (get)
import Types
import Data.BlobStore
import Data.Conduit.Lazy (MonadActive (..), lazyConsume)
import qualified Codec.Archive.Tar as Tar
import Control.Monad.Logger (runNoLoggingT)
import qualified Data.Text as T
import Data.Conduit.Zlib (ungzip)
import System.IO.Temp (withSystemTempFile)
import System.IO (IOMode (ReadMode), openBinaryFile)
import Model (Metadata (..))
import Distribution.PackageDescription.Parse (parsePackageDescription, ParseResult (ParseOk))
import qualified Distribution.PackageDescription as PD
import qualified Distribution.Package as PD
import Control.Monad.State.Strict (put, get, execStateT, MonadState)
import Crypto.Hash.Conduit (sinkHash)
import Crypto.Hash (Digest, SHA256)
import Data.Byteable (toBytes)
import Distribution.Text (display)
import Text.Markdown (Markdown (Markdown))
import qualified Data.Traversable as T
import qualified Data.Version
import Text.ParserCombinators.ReadP (readP_to_S)
import Text.Blaze.Html.Renderer.Utf8 (renderHtml)
import Text.Blaze.Html (unsafeByteString)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import qualified Documentation.Haddock.Parser as Haddock
import Documentation.Haddock.Types (DocH (..), Hyperlink (..), Picture (..), Header (..), Example (..))
import qualified Data.HashMap.Lazy as HM

loadCabalFiles :: ( MonadActive m
                  , MonadBaseControl IO m
                  , MonadThrow m
                  , MonadIO m
                  , MonadReader env m
                  , HasHttpManager env
                  , HasBlobStore env StoreKey
                  , HasHackageRoot env
                  , MonadLogger m
                  , MonadMask m
                  )
               => Bool -- ^ do the database updating
               -> Bool -- ^ force updates regardless of hash value?
               -> HashMap PackageName (Version, ByteString)
               -> m (UploadState Metadata)
loadCabalFiles dbUpdates forceUpdate metadata0 = (>>= T.mapM liftIO) $ flip execStateT (UploadState metadata1 mempty) $ do
    HackageRoot root <- liftM getHackageRoot ask
    $logDebug $ "Entering loadCabalFiles, root == " ++ root
    req <- parseUrl $ unpack $ root ++ "/00-index.tar.gz"
    withSystemTempFile "hackage-index" $ \tempIndex handleOut -> do
        $logDebug $ "Requesting: " ++ tshow req
        withResponse req $ \res -> responseBody res $$ sinkHandle handleOut
        liftIO $ hClose handleOut
        withBinaryFile tempIndex ReadMode $ \handleIn -> do
            bss <- lazyConsume $ sourceHandle handleIn $= ungzip
            tarSource (Tar.read $ fromChunks bss)
                $$ parMapMC 32 go
                =$ scanlC (\x _ -> x + 1) (0 :: Int)
                =$ filterC ((== 0) . (`mod` 1000))
                =$ mapM_C (\i -> $logInfo $ "Processing cabal file #" ++ tshow i)
    $logInfo "Finished processing cabal files"
  where
    metadata1 = flip fmap metadata0 $ \(v, h) -> MetaSig
        v
        (fromMaybe (pack [0, 0, 0]) $ readVersion v)
        h
    withBinaryFile fp mode = bracket (liftIO $ openBinaryFile fp mode) (liftIO . hClose)

    go entry = do
        case Tar.entryContent entry of
            Tar.NormalFile lbs _
                | Just (name, version) <- parseFilePath (Tar.entryPath entry) -> do
                    let key = HackageCabal name version
                    -- It's not longer sufficient to simply check if the cabal
                    -- file exists, since Hackage now allows updating in place.
                    -- Instead, we have to check if it matches what we have
                    -- and, if not, update it.
                    store <- liftM getBlobStore ask
                    newDigest :: Digest SHA256 <- sourceLazy lbs $$ sinkHash
                    toStore <- withAcquire (storeRead' store key) $ \mcurr ->
                        case mcurr of
                            Nothing -> return True
                            Just curr -> do
                                -- Check if it matches. This is cheaper than
                                -- always writing, since it can take advantage
                                -- of the local filesystem cache and not go to
                                -- S3 each time.
                                currDigest <- curr $$ sinkHash
                                return $! currDigest /= newDigest
                    when toStore $ withAcquire (storeWrite' store key) $ \sink ->
                        sourceLazy lbs $$ sink
                    when dbUpdates $ do
                        case readVersion version of
                            Nothing -> return ()
                            Just dataVersion -> setMetadata
                                forceUpdate
                                name
                                version
                                dataVersion
                                (toBytes newDigest)
                                (parsePackageDescription $ unpack $ decodeUtf8 lbs)
            _ -> return ()

readVersion :: Version -> Maybe (UVector Int)
readVersion v =
    case filter (null . snd) $ readP_to_S Data.Version.parseVersion . unpack . unVersion $ v of
        (dv, _):_ -> Just $ pack $ Data.Version.versionBranch dv
        [] -> Nothing

tarSource :: (Exception e, MonadThrow m)
          => Tar.Entries e
          -> Producer m Tar.Entry
tarSource Tar.Done = return ()
tarSource (Tar.Fail e) = throwM e
tarSource (Tar.Next e es) = yield e >> tarSource es

data UploadState md = UploadState
    { usMetadata :: !(HashMap PackageName MetaSig)
    , usMetaChanges :: (HashMap PackageName md)
    }
    deriving (Functor, Foldable, Traversable)

data MetaSig = MetaSig
    {-# UNPACK #-} !Version
    {-# UNPACK #-} !(UVector Int) -- versionBranch
    {-# UNPACK #-} !ByteString -- hash

setMetadata :: ( MonadBaseControl IO m
               , MonadThrow m
               , MonadIO m
               , MonadReader env m
               , MonadState (UploadState (IO Metadata)) m
               , HasHttpManager env
               , MonadLogger m
               , MonadActive m
               , HasBlobStore env StoreKey
               , HasHackageRoot env
               )
            => Bool -- ^ force update?
            -> PackageName
            -> Version
            -> UVector Int -- ^ versionBranch
            -> ByteString
            -> ParseResult PD.GenericPackageDescription
            -> m ()
setMetadata forceUpdate name version dataVersion hash' gpdRes = do
    UploadState mdMap mdChanges <- get
    let toUpdate =
            case lookup name mdMap of
                Just (MetaSig _currVersion currDataVersion currHash) ->
                    case compare currDataVersion dataVersion of
                        LT -> True
                        GT -> False
                        EQ -> currHash /= hash' || forceUpdate
                Nothing -> True
    if toUpdate
        then case gpdRes of
                ParseOk _ gpd -> do
                    !md <- getMetadata name version hash' gpd
                    put $! UploadState
                                (insertMap name (MetaSig version dataVersion hash') mdMap)
                                (HM.insert name md mdChanges)
                _ -> return ()
        else return ()

getMetadata :: ( MonadActive m
               , MonadIO m
               , MonadBaseControl IO m
               , MonadThrow m
               , MonadReader env m
               , HasBlobStore env StoreKey
               , HasHackageRoot env
               , HasHttpManager env
               , MonadLogger m
               )
            => PackageName
            -> Version
            -> ByteString
            -> PD.GenericPackageDescription
            -> m (IO Metadata)
getMetadata name version hash' gpd = do
    let pd = PD.packageDescription gpd
    env <- ask
    return $ liftIO $ runNoLoggingT $ flip runReaderT env $ do
        (mreadme, mchangelog, mlicenseContent) <-
            grabExtraFiles name version
#if MIN_VERSION_Cabal(1, 20, 0)
                $ PD.licenseFiles pd
#else
                [PD.licenseFile pd]
#endif
        let collapseHtml = unsafeByteString . toStrict . renderHtml
        return Metadata
            { metadataName = name
            , metadataVersion = version
            , metadataHash = hash'
            , metadataDeps = setToList
                           $ asSet
                           $ concat
                  [ foldMap goTree $ PD.condLibrary gpd
                  , foldMap (goTree . snd) $ PD.condExecutables gpd
                  ]
            , metadataAuthor = pack $ PD.author pd
            , metadataMaintainer = pack $ PD.maintainer pd
            , metadataLicenseName = pack $ display $ PD.license pd
            , metadataHomepage = pack $ PD.homepage pd
            , metadataBugReports = pack $ PD.bugReports pd
            , metadataSynopsis = pack $ PD.synopsis pd
            , metadataSourceRepo = mapMaybe showSourceRepo $ PD.sourceRepos pd
            , metadataCategory = pack $ PD.category pd
            , metadataLibrary = isJust $ PD.library pd
            , metadataExes = length $ PD.executables pd
            , metadataTestSuites = length $ PD.testSuites pd
            , metadataBenchmarks = length $ PD.benchmarks pd
            , metadataReadme = collapseHtml $ fromMaybe
                (hToHtml . Haddock.toRegular . Haddock.parseParas $ PD.description pd)
                mreadme
            , metadataChangelog = collapseHtml <$> mchangelog
            , metadataLicenseContent = collapseHtml <$> mlicenseContent
            }
  where
    goTree (PD.CondNode _ deps comps) = concatMap goDep deps ++ concatMap goComp comps
    goDep (PD.Dependency (PD.PackageName n) _) = singletonSet $ pack n
    goComp (_, tree, mtree) = goTree tree ++ maybe mempty goTree mtree

-- | Convert a Haddock doc to HTML.
hToHtml :: DocH String String -> Html
hToHtml =
    go
  where
    go :: DocH String String -> Html
    go DocEmpty = mempty
    go (DocAppend x y) = go x ++ go y
    go (DocString x) = toHtml x
    go (DocParagraph x) = H.p $ go x
    go (DocIdentifier s) = H.code $ toHtml s
    go (DocIdentifierUnchecked s) = H.code $ toHtml s
    go (DocModule s) = H.code $ toHtml s
    go (DocWarning x) = H.span H.! A.class_ "warning" $ go x
    go (DocEmphasis x) = H.em $ go x
    go (DocMonospaced x) = H.code $ go x
    go (DocBold x) = H.strong $ go x
    go (DocUnorderedList xs) = H.ul $ foldMap (H.li . go) xs
    go (DocOrderedList xs) = H.ol $ foldMap (H.li . go) xs
    go (DocDefList xs) = H.dl $ flip foldMap xs $ \(x, y) ->
        H.dt (go x) ++ H.dd (go y)
    go (DocCodeBlock x) = H.pre $ H.code $ go x
    go (DocHyperlink (Hyperlink url mlabel)) =
        H.a H.! A.href (H.toValue url) $ toHtml label
      where
        label = fromMaybe url mlabel
    go (DocPic (Picture url mtitle)) =
        H.img H.! A.src (H.toValue url) H.! A.title (H.toValue $ fromMaybe mempty mtitle)
    go (DocAName s) = H.div H.! A.id (H.toValue s) $ mempty
    go (DocProperty s) = H.pre $ H.code $ toHtml s
    go (DocExamples es) = flip foldMap es $ \(Example exp' ress) ->
        H.div H.! A.class_ "example" $ do
            H.pre H.! A.class_ "expression" $ H.code $ toHtml exp'
            flip foldMap ress $ \res ->
                H.pre H.! A.class_ "result" $ H.code $ toHtml res
    go (DocHeader (Header level content)) =
        wrapper level $ go content
      where
        wrapper 1 = H.h1
        wrapper 2 = H.h2
        wrapper 3 = H.h3
        wrapper 4 = H.h4
        wrapper 5 = H.h5
        wrapper _ = H.h6

showSourceRepo :: PD.SourceRepo -> Maybe Text
showSourceRepo = fmap pack . PD.repoLocation

grabExtraFiles :: ( MonadActive m
                  , MonadIO m
                  , MonadBaseControl IO m
                  , MonadThrow m
                  , MonadReader env m
                  , HasBlobStore env StoreKey
                  , HasHackageRoot env
                  , HasHttpManager env
                  , MonadLogger m
                  )
               => PackageName
               -> Version
               -> [String] -- ^ license files
               -> m (Maybe Html, Maybe Html, Maybe Html) -- ^ README, changelog, license
grabExtraFiles name version lfiles = runResourceT $ do
    msrc <- sourceHackageSdist name version
    handle (\(_ :: Tar.FormatError) -> return (Nothing,Nothing,Nothing)) $
        case msrc of
            Nothing -> return mempty
            Just src -> do
                bss <- lazyConsume $ src $= ungzip
                tarSource (Tar.read $ fromChunks bss) $$ foldlC go mempty
  where
    go trip@(mreadme, mchangelog, mlicense) entry =
        case Tar.entryContent entry of
            Tar.NormalFile lbs _ ->
                let name' = drop 1 $ dropWhile (/= '/') $ Tar.entryPath entry in
                case toLower name' of
                    "readme.md"     -> (md lbs, mchangelog, mlicense)
                    "readme"        -> (txt lbs, mchangelog, mlicense)
                    "readme.txt"    -> (txt lbs, mchangelog, mlicense)
                    "changelog.md"  -> (mreadme, md lbs, mlicense)
                    "changelog"     -> (mreadme, txt lbs, mlicense)
                    "changelog.txt" -> (mreadme, txt lbs, mlicense)
                    "changes.md"    -> (mreadme, md lbs, mlicense)
                    "changes"       -> (mreadme, txt lbs, mlicense)
                    "changes.txt"   -> (mreadme, txt lbs, mlicense)
                    _ | name' `elem` lfiles -> (mreadme, mchangelog, txt lbs)
                    _ -> trip
            _ -> trip

    md = wrapClass "markdown" . Markdown . decodeUtf8
    txt = wrapClass "plain-text" . Textarea . toStrict . decodeUtf8

    wrapClass clazz inner = Just $ H.div H.! A.class_ clazz $ toHtml inner

parseFilePath :: String -> Maybe (PackageName, Version)
parseFilePath s =
    case filter (not . null) $ T.split (== '/') $ pack s of
        (name:version:_) -> Just (PackageName name, Version version)
        _ -> Nothing

sourceHackageSdist :: ( MonadIO m
                      , MonadThrow m
                      , MonadBaseControl IO m
                      , MonadResource m
                      , MonadReader env m
                      , HasHttpManager env
                      , HasHackageRoot env
                      , HasBlobStore env StoreKey
                      , MonadLogger m
                      )
                   => PackageName
                   -> Version
                   -> m (Maybe (Source m ByteString))
sourceHackageSdist name version = do
    let key = HackageSdist name version
    msrc1 <- storeRead key
    case msrc1 of
        Just src -> return $ Just src
        Nothing -> do
            HackageRoot root <- liftM getHackageRoot ask
            let url = concat
                        [ root
                        , "/package/"
                        , toPathPiece name
                        , "-"
                        , toPathPiece version
                        , ".tar.gz"
                        ]
            req' <- parseUrl $ unpack url
            let req = req' { checkStatus = \_ _ _ -> Nothing }
            $logDebug $ "Requesting: " ++ tshow req
            exists <- withResponse req $ \res ->
                if responseStatus res == status200
                    then do
                        responseBody res $$ storeWrite key
                        return True
                    else return False
            if exists
                then storeRead key
                else return Nothing

-- FIXME put in conduit-combinators
parMapMC :: (MonadIO m, MonadBaseControl IO m)
         => Int
         -> (i -> m o)
         -> Conduit i m o
parMapMC _ = mapMC

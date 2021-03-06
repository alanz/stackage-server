module Handler.StackageSdist where

import Import
import Data.BlobStore
import Data.Hackage
import Data.Slug (SnapSlug)
import Handler.Package (packagePage)

getStackageSdistR :: SnapSlug -> PackageNameVersion -> Handler TypedContent
getStackageSdistR slug (PNVTarball name version) = do
    Entity _ stackage <- runDB $ getBy404 $ UniqueSnapshot slug
    let ident = stackageIdent stackage
    addDownload (Just ident) name version
    msrc1 <- storeRead (CustomSdist ident name version)
    msrc <-
        case msrc1 of
            Just src -> return $ Just src
            Nothing -> sourceHackageSdist name version
    case msrc of
        Nothing -> notFound
        Just src -> do
            addHeader "content-disposition" $ concat
                [ "attachment; filename=\""
                , toPathPiece name
                , "-"
                , toPathPiece version
                , ".tar.gz"
                ]
            respondSource "application/x-gzip" $ mapOutput (Chunk . toBuilder) src
getStackageSdistR slug (PNVName name) = runDB $ do
    Entity sid _ <- getBy404 $ UniqueSnapshot slug
    mp <- selectFirst
        [PackageStackage ==. sid, PackageName' ==. name]
        [Desc PackageVersion]
    case mp of
        Nothing -> notFound
        Just (Entity _ Package {..}) ->
            redirect $ SnapshotR slug
                     $ StackageSdistR
                     $ PNVNameVersion name packageVersion
getStackageSdistR slug (PNVNameVersion name version) = packagePage
  name (Just version)
  (do
    Entity sid _ <- getBy404 $ UniqueSnapshot slug
    let loop [] = return Nothing
        loop (x:xs) = do
            mdocs <- selectFirst x []
            case mdocs of
                Nothing -> loop xs
                Just _ -> return mdocs
    loop
        [ [DocsName ==. name, DocsVersion ==. version, DocsSnapshot ==. Just sid]
        , [DocsName ==. name, DocsVersion ==. version]
        , [DocsName ==. name]
        ]
    ) >>= sendResponse

addDownload :: Maybe PackageSetIdent
            -> PackageName
            -> Version
            -> Handler ()
addDownload downloadIdent downloadPackage downloadVersion = do
    downloadUserAgent <- fmap decodeUtf8 <$> lookupHeader "user-agent"
    downloadTimestamp <- liftIO getCurrentTime
    runDB $ insert_ Download {..}

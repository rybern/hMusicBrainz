{-# LANGUAGE OverloadedStrings, FlexibleContexts #-}

module Network.Protocol.MusicBrainz.XML2.WebService (
    getRecordingById
  , getReleaseById
  , searchReleasesByArtistAndRelease
) where

import Network.Protocol.MusicBrainz.XML2.Types

import Control.Applicative (liftA2, (<|>))
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.Conduit (Source, Sink, ($=), ($$), MonadThrow, runResourceT)
import Data.Conduit.List (sourceList)
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Time.Format (parseTime)
import qualified Data.Vector as V
import Data.XML.Types (Event)
import Network.HTTP.Base (urlEncode)
import Network.HTTP.Conduit (simpleHttp)
import System.Locale (defaultTimeLocale)
import Text.XML.Stream.Parse (parseBytes, def, content, tagNoAttr, tagName, requireAttr, optionalAttr, force, many, AttrParser)
import Text.XML (Name(..))

-- not until conduit 0.5
sourceLbs :: Monad m => BL.ByteString -> Source m ByteString
sourceLbs = sourceList . BL.toChunks

musicBrainzWSLookup :: MonadIO m => Text -> Text -> [Text] -> m BL.ByteString
musicBrainzWSLookup reqtype param incparams = do
    let url = "https://musicbrainz.org/ws/2/" ++ T.unpack reqtype ++ "/" ++ T.unpack param ++ incs incparams
    simpleHttp url
    where
        incs [] = ""
	incs xs = ("?inc="++) . intercalate "+" . map T.unpack $ xs

musicBrainzWSSearch :: MonadIO m => Text -> Text -> Maybe Int -> Maybe Int -> m BL.ByteString
musicBrainzWSSearch reqtype query mlimit moffset = do
    let url = "https://musicbrainz.org/ws/2/" ++ T.unpack reqtype ++ "/?query=" ++ urlEncode (T.unpack query) ++ limit mlimit ++ offset moffset
    simpleHttp url
    where
        limit Nothing = ""
	limit (Just l) = "&limit=" ++ show l
        offset Nothing = ""
	offset (Just o) = "&offset=" ++ show o

getRecordingById :: (MonadBaseControl IO m, MonadIO m, MonadThrow m) => MBID -> m Recording
getRecordingById mbid = do
    lbs <- musicBrainzWSLookup "recording" (unMBID mbid) ["artist-credits"]
    rs <- runResourceT $ sourceLbs lbs $= parseBytes def $$ sinkRecordings
    return $ head rs

getReleaseById :: (MonadBaseControl IO m, MonadIO m, MonadThrow m) => MBID -> m Release
getReleaseById mbid = do
    lbs <- musicBrainzWSLookup "release" (unMBID mbid) ["recordings", "artist-credits"]
    rs <- runResourceT $ sourceLbs lbs $= parseBytes def $$ sinkReleases
    return $ head rs

sinkRecordings :: MonadThrow m => Sink Event m [Recording]
sinkRecordings = force "metadata required" (tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}metadata" $ many parseRecording)

sinkReleases :: MonadThrow m => Sink Event m [Release]
sinkReleases = force "metadata required" (tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}metadata" $ many (fmap (fmap snd) parseRelease))

sinkReleaseList :: MonadThrow m => Sink Event m [(Int, Release)]
sinkReleaseList = force "metadata required" (tagName "{http://musicbrainz.org/ns/mmd-2.0#}metadata" (optionalAttr "created") $ \_ ->
    force "release-list required" (tagName "{http://musicbrainz.org/ns/mmd-2.0#}release-list" (liftA2 (,) (requireAttr "count") (requireAttr "offset")) $ \_ -> many parseRelease))

parseRecording :: MonadThrow m => Sink Event m (Maybe Recording)
parseRecording = tagName "{http://musicbrainz.org/ns/mmd-2.0#}recording" (requireAttr "id") $ \rid -> do
    title <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}title" content
    len <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}length" content
    ncs <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}artist-credit" $ many parseNameCredits
    return Recording { _recordingId = MBID rid, _recordingTitle = title, _recordingLength = fmap forceReadDec len, _recordingArtistCredit = fromMaybe [] ncs }

parseNameCredits :: MonadThrow m => Sink Event m (Maybe NameCredit)
parseNameCredits = tagName "{http://musicbrainz.org/ns/mmd-2.0#}name-credit" (buggyJoinPhrase) $ \mjp -> force "artist required" (tagName "{http://musicbrainz.org/ns/mmd-2.0#}artist" (requireAttr "id") $ \aid -> do
    name <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}name" content
    sortName <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}sort-name" content
    _ <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}disambiguation" content
    return NameCredit { _nameCreditArtistId = MBID aid, _nameCreditJoinPhrase = mjp, _nameCreditArtistName = name, _nameCreditArtistSortName = sortName }
    )

-- what's up with this
buggyJoinPhrase :: AttrParser (Maybe Text)
buggyJoinPhrase = fmap Just (requireAttr "{http://musicbrainz.org/ns/mmd-2.0#}joinphrase")
    <|> optionalAttr "{http://musicbrainz.org/ns/mmd-2.0#}joinphrase" { nameNamespace = Nothing }

forceReadDec :: Integral a => Text -> a
forceReadDec = (\(Right (d, _)) -> d) . TR.decimal

parseRelease :: MonadThrow m => Sink Event m (Maybe (Int, Release))
parseRelease = tagName "{http://musicbrainz.org/ns/mmd-2.0#}release" (liftA2 (,) (requireAttr "id") (optionalAttr "{http://musicbrainz.org/ns/ext#-2.0}score")) $ \(rid,score) -> do
    title <- force "title required" (tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}title" content)
    status <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}status" content
    quality <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}quality" content
    packaging <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}packaging" content
    tr <- parseTextRepresentation
    ncs <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}artist-credit" $ many parseNameCredits
    _ <- parseReleaseGroup
    date <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}date" content
    country <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}country" content
    barcode <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}barcode" content
    amazonASIN <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}asin" content
    _ <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}label-info-list" $ parseLabelInfo
    media <- tagName "{http://musicbrainz.org/ns/mmd-2.0#}medium-list" (requireAttr "count") $ \_ -> (tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}track-count" content >> many parseMedium)
    return (maybe 0 forceReadDec score, Release {
        _releaseId = MBID rid
      , _releaseTitle = title
      , _releaseStatus = status
      , _releaseQuality = quality
      , _releasePackaging = packaging
      , _releaseTextRepresentation = tr
      , _releaseArtistCredit = fromMaybe [] ncs
      , _releaseDate = parseTime defaultTimeLocale "%Y-%m-%d" . T.unpack =<< date
      , _releaseCountry = country
      , _releaseBarcode = barcode
      , _releaseASIN = amazonASIN
      , _releaseMedia = V.fromList (fromMaybe [] media)
    })

parseTextRepresentation :: MonadThrow m => Sink Event m (Maybe TextRepresentation)
parseTextRepresentation = tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}text-representation" $ do
    lang <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}language" content
    script <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}script" content
    return TextRepresentation {
      _textRepLanguage = lang
    , _textRepScript = script
    }

parseMedium :: MonadThrow m => Sink Event m (Maybe Medium)
parseMedium = tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}medium" $ do
    title <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}title" content
    position <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}position" content
    format <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}format" content
    disclist <- tagName "{http://musicbrainz.org/ns/mmd-2.0#}disc-list" (requireAttr "count") $ \c -> return (DiscList . forceReadDec $ c)
    tracklist <- tagName "{http://musicbrainz.org/ns/mmd-2.0#}track-list" (requireAttr "count" >>= \c -> optionalAttr "offset" >>= \o -> return (c, o)) $ \(_,o') -> do
        tracks <- many parseTrack
        return TrackList { _trackListOffset = fmap forceReadDec o', _trackListTracks = V.fromList tracks }
    return Medium {
	_mediumTitle = title
      , _mediumPosition = fmap forceReadDec position
      , _mediumFormat = format
      , _mediumDiscList = disclist
      , _mediumTrackList = tracklist
      }

parseTrack :: MonadThrow m => Sink Event m (Maybe Track)
parseTrack = tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}track" $ do
    position <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}position" content
    number <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}number" content
    len <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}length" content
    recording <- force "recording required" parseRecording
    return Track {
      _trackPosition = fmap forceReadDec position
    , _trackNumber = fmap forceReadDec number
    , _trackLength = fmap forceReadDec len
    , _trackRecording = recording
    }

parseReleaseGroup :: MonadThrow m => Sink Event m (Maybe ReleaseGroup)
parseReleaseGroup = tagName "{http://musicbrainz.org/ns/mmd-2.0#}release-group" (liftA2 (,) (requireAttr "type") (requireAttr "id")) $ \(t,i) -> do
    title <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}title" content
    frd <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}first-release-date" content
    pt <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}primary-type" content
    ncs <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}artist-credit" $ many parseNameCredits
    return ReleaseGroup {
      _releaseGroupId = MBID i
    , _releaseGroupType = t
    , _releaseGroupTitle = title
    , _releaseGroupFirstReleaseDate = frd
    , _releaseGroupPrimaryType = pt
    , _releaseGroupArtistCredit = fromMaybe [] ncs
    }

parseLabelInfo :: MonadThrow m => Sink Event m (Maybe LabelInfo)
parseLabelInfo = tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}label-info" $ do
    catno <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}catalog-number" content
    label <- force "label required" parseLabel
    return LabelInfo {
      _labelInfoCatalogNumber = catno
    , _labelInfoLabel = label
    }

parseLabel :: MonadThrow m => Sink Event m (Maybe Label)
parseLabel = tagName "{http://musicbrainz.org/ns/mmd-2.0#}label" (requireAttr "id") $ \i -> do
    name <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}name" content
    sortname <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}sort-name" content
    labelcode <- tagNoAttr "{http://musicbrainz.org/ns/mmd-2.0#}label-code" content
    return Label {
      _labelId = MBID i
    , _labelName = name
    , _labelSortName = sortname
    , _labelLabelCode = labelcode
    }

searchReleasesByArtistAndRelease :: (MonadIO m, MonadBaseControl IO m, MonadThrow m) => Text -> Text -> Maybe Int -> Maybe Int -> m [(Int, Release)]
searchReleasesByArtistAndRelease artist release mlimit moffset = do
    lbs <- musicBrainzWSSearch "release" (T.concat ["artist:\"", artist, "\" AND release:\"", release, "\""]) mlimit moffset
    rs <- runResourceT $ sourceLbs lbs $= parseBytes def $$ sinkReleaseList
    return rs
